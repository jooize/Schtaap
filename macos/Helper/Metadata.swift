import Foundation

// Turns librespot's playback events into the metadata OwnTone reads beside a
// pipe input.
//
// librespot runs a program on every player event (--onevent) and hands it the
// event in the environment. OwnTone, reading PCM out of a named pipe, also
// watches <pipe>.metadata for metadata in the format shairport-sync writes.
// This turns the first into the second, which is the only way a pipe input
// ever gets a title, an artist or cover art.
//
// This used to be bridge/librespot-metadata, a Python 3 script. It moved in
// here because /usr/bin/python3 on a clean Mac is a stub that prompts to
// install the Command Line Tools: shipping the script would have worked on
// the machine it was written on and failed for a user. The helper already
// runs at every boundary this needs, so it costs no new dependency.
//
// Nothing here talks to Spotify. Every field comes out of the environment,
// except the cover image, which is fetched from the URL librespot supplies.
//
// Constraints this encodes, all read out of OwnTone's src/inputs/pipe.c:
//
// - Items are Shairport XML: type and code are the 8 hex digits of a DMAP
//   four-char code, payload is base64. OwnTone acts on minm, asar, asal,
//   asgn, prgr, pvol, PICT and pfls, and ignores everything else.
// - prgr is measured in FRAMES, not milliseconds: OwnTone computes
//   pos_ms = (pos - start) * 1000 / pipe_sample_rate. The rate here must match
//   OwnTone's library.pipe_sample_rate.
// - prgr is rejected outright if any of start/pos/end is zero, so the frame
//   numbers here are 1-based.
// - PICT carries raw image bytes, JPEG or PNG only, 2 bytes to 1 MiB.
//   librespot gives cover URLs, so the image has to be fetched first.
// - OwnTone only starts watching the metadata pipe once playback begins, so
//   writing when nothing is reading is the normal case and not an error.
//
// Volume is forwarded as a pvol item, which OwnTone applies to its master
// volume, the same control the app's top slider moves. librespot runs with
// `--volume-ctrl fixed` so the phone's slider no longer attenuates the
// samples: before this it did, on a 60 dB log curve, and 45% on the phone
// arrived as -33 dBFS on top of whatever the AirPlay volume was, which the
// user heard as silence. There is no loop: nothing tells librespot what the
// engine's volume became, so the phone only ever pushes.

enum MetadataBridge {
    /// OwnTone's PIPE_PICTURE_SIZE_MAX.
    private static let pictureSizeMax = 1_048_576

    /// Must match OwnTone's `library.pipe_sample_rate`, which the generated
    /// owntone.conf leaves at its default.
    private static let sampleRate = 44_100

    private static let artworkTimeout: TimeInterval = 5
    private static let writeTimeout: TimeInterval = 2

    /// How long a track description waits for the engine to start reading.
    ///
    /// OwnTone opens the metadata pipe only once audio arrives on the audio
    /// pipe and playback has started, which is a moment after librespot
    /// reports `playing`. Without this wait the description written on that
    /// event misses, and the next chance is the next seek or pause, which
    /// can be a whole track away. librespot runs these handlers one after
    /// another on a thread of its own, so the wait delays the next event's
    /// handling by at most this, and never the audio.
    private static let readerPatience: TimeInterval = 1.5
    private static let readerPollMicroseconds: UInt32 = 50_000

    /// Position events all carry POSITION_MS and no track description.
    private static let positionEvents: Set<String> = [
        "playing", "paused", "seeked", "position_correction",
    ]

    /// Handles the event in the environment, and returns whether anything was
    /// written. Never throws: a metadata failure is not a reason to disturb
    /// playback, so everything here degrades to a line on stderr.
    static func handleEvent(
        metadataPipe: URL, stateDirectory: URL, sessionFile: URL, transport: EngineTransport
    ) {
        let environment = ProcessInfo.processInfo.environment
        let event = environment["PLAYER_EVENT"] ?? ""

        ensurePipe(metadataPipe)

        // Transport first, before any metadata: a pause should silence the
        // speakers now, not after a pipe write. The seek it ends with makes
        // librespot report the corrected position in its own event, so the
        // progress item written below for this event is the stale one and
        // is skipped. See EngineTransport for the whole arrangement.
        switch event {
        case "paused":
            transport.paused()
            saveState(loadState(in: stateDirectory), in: stateDirectory)
            return
        case "playing":
            transport.playing()
        case "stopped":
            transport.stopped()
        case "session_disconnected":
            transport.sessionEnded()
        default:
            break
        }

        // Who is using the receiver, for the app to show. Nothing below
        // concerns these events.
        switch event {
        case "session_connected":
            SpotifySessionFile.update(at: sessionFile) { session in
                session = SpotifySession(active: true, userName: environment["USER_NAME"])
            }
            return
        case "session_client_changed":
            SpotifySessionFile.update(at: sessionFile) { session in
                session.clientName = environment["CLIENT_NAME"]
                session.clientBrand = environment["CLIENT_BRAND_NAME"]
                session.clientModel = environment["CLIENT_MODEL_NAME"]
            }
            return
        case "session_disconnected":
            SpotifySessionFile.update(at: sessionFile) { session in
                session = SpotifySession(active: false)
            }
        default:
            break
        }

        var state = loadState(in: stateDirectory)
        let blob: Data
        var carriesTrack = false

        switch event {
        case "track_changed":
            state = remember(environment, in: stateDirectory)
            blob = trackItems(state, positionMs: 0)
            carriesTrack = true

        case let name where positionEvents.contains(name):
            let position = Int(environment["POSITION_MS"] ?? "") ?? 0
            if !state.trackID.isEmpty && !state.delivered {
                // OwnTone only opens the metadata pipe once playback starts,
                // so the track_changed that announced this track usually had
                // nobody to read it. Every later event is another chance.
                log("earlier metadata never reached the engine; sending it again")
                blob = trackItems(state, positionMs: position)
                carriesTrack = true
            } else {
                blob = progressItem(positionMs: position, durationMs: state.durationMs)
            }

        case "stopped":
            // The pause above already flushed the speakers, and a flush item
            // is a no-op on a paused engine anyway. Only the track is over.
            pruneCovers(in: stateDirectory, keeping: nil)
            saveState(TrackState(), in: stateDirectory)
            return

        case "end_of_track":
            pruneCovers(in: stateDirectory, keeping: nil)
            state = TrackState()
            blob = item(.ssnc, "pfls")

        case "volume_changed":
            // librespot only emits this while a client is actively
            // controlling the device, so the initial volume at startup
            // never reaches here and never overrides the engine's own.
            guard let volume = Int(environment["VOLUME"] ?? "") else {
                saveState(state, in: stateDirectory)
                return
            }
            blob = volumeItem(spotifyVolume: volume)

        default:
            saveState(state, in: stateDirectory)
            return
        }

        guard !blob.isEmpty else {
            saveState(state, in: stateDirectory)
            return
        }

        // Only a confirmed write retires the track description; otherwise the
        // next event picks it up again. A track_changed never waits: with
        // the engine stopped or paused there is no reader until playback
        // starts, and it is the resend on that event that meets one.
        let patience = carriesTrack && event != "track_changed" ? readerPatience : 0
        if write(blob, to: metadataPipe, waitingForReader: patience), carriesTrack {
            state.delivered = true
        }
        saveState(state, in: stateDirectory)
    }

    // MARK: - Items

    /// The two DMAP type codes shairport-sync uses: "core" carries the track
    /// text, "ssnc" the shairport extras.
    private enum ItemType: String {
        case core, ssnc
    }

    /// A DMAP four-char code as the 8 hex digits OwnTone parses with %8x.
    private static func fourCC(_ code: String) -> String {
        code.unicodeScalars.map { String(format: "%02x", $0.value) }.joined()
    }

    /// One Shairport metadata item.
    ///
    /// The newline before the base64 payload is part of the format shairport
    /// emits; OwnTone's extractor splits on `</item>` either way.
    private static func item(_ type: ItemType, _ code: String, payload: Data? = nil) -> Data {
        let head = "<item><type>\(fourCC(type.rawValue))</type><code>\(fourCC(code))</code>"
        guard let payload else {
            return Data("\(head)<length>0</length></item>".utf8)
        }
        let encoded = payload.base64EncodedString()
        return Data("""
        \(head)<length>\(payload.count)</length>
        <data encoding="base64">
        \(encoded)</data></item>
        """.utf8)
    }

    /// A text item, or nothing at all when the value is empty.
    ///
    /// OwnTone ignores an item with an empty payload, so sending one is noise
    /// -- and it would not clear a stale value either. Skipping keeps the
    /// intent honest: nothing is being said about this field.
    private static func textItem(_ code: String, _ value: String) -> Data {
        value.isEmpty ? Data() : item(.core, code, payload: Data(value.utf8))
    }

    /// A prgr item in frames, 1-based so no component is ever zero.
    private static func progressItem(positionMs: Int, durationMs: Int) -> Data {
        guard durationMs > 0 else { return Data() }
        let start = 1
        let position = start + frames(max(0, positionMs))
        let end = start + frames(durationMs)
        guard end > start else { return Data() }
        return item(.ssnc, "prgr", payload: Data("\(start)/\(position)/\(end)".utf8))
    }

    /// A pvol item for a Spotify volume (0...65535).
    ///
    /// shairport-sync writes "airplay_volume,volume,lowest,highest"; OwnTone
    /// reads only the first, an AirPlay level in -30...0 dB, and maps it
    /// linearly onto its 0...100 master volume (pipe.c, parse_volume). The
    /// rest must be exactly ",0.00,0.00,0.00": anything else is read as
    /// shairport-sync doing its own software volume, and the item is ignored.
    ///
    /// OwnTone truncates the level to a whole percent, so the level sent is
    /// the middle of the rounded percent's band rather than the exact
    /// fraction: the engine then lands on `round(volume / 655.35)` every
    /// time, which is the mapping the app inverts when it pushes its own
    /// level back to Spotify. Off by a float's width, a truncation would
    /// otherwise turn 45 into 44 and start the two sides chasing each other.
    private static func volumeItem(spotifyVolume: Int) -> Data {
        let fraction = Double(min(max(spotifyVolume, 0), 65_535)) / 65_535
        let percent = Int((fraction * 100).rounded())
        let airplayLevel = -30.0 + 30.0 * (Double(percent) + 0.5) / 100
        let payload = String(format: "%.2f,0.00,0.00,0.00", airplayLevel)
        log("forwarding volume \(percent)%")
        return item(.ssnc, "pvol", payload: Data(payload.utf8))
    }

    private static func frames(_ milliseconds: Int) -> Int {
        Int((Double(milliseconds) * Double(sampleRate) / 1000).rounded())
    }

    /// A PICT item, if the bytes are something OwnTone will accept. It sniffs
    /// the format itself and rejects anything that is not JPEG or PNG.
    private static func pictureItem(_ data: Data?) -> Data {
        guard let data, data.count >= 2, data.count <= pictureSizeMax else { return Data() }
        let magic = [data[data.startIndex], data[data.index(after: data.startIndex)]]
        guard magic == [0xFF, 0xD8] || magic == [0x89, 0x50] else { return Data() }
        return item(.ssnc, "PICT", payload: data)
    }

    /// Everything OwnTone needs in order to describe the current track.
    private static func trackItems(_ state: TrackState, positionMs: Int) -> Data {
        var blob = item(.ssnc, "pfls")
        blob += textItem("minm", state.title)
        blob += textItem("asar", state.artist)
        blob += textItem("asal", state.album)
        blob += pictureItem(loadCover(state.coverPath))
        blob += progressItem(positionMs: positionMs, durationMs: state.durationMs)
        return blob
    }

    // MARK: - Track state
    //
    // Only track_changed carries DURATION_MS, but every position event needs
    // it to build a prgr item. This program runs once per event and keeps
    // nothing in memory, so the duration is remembered on disk.

    private struct TrackState: Codable {
        var trackID = ""
        var durationMs = 0
        var title = ""
        var artist = ""
        var album = ""
        var coverPath: String?
        /// Set once the items have actually reached OwnTone. Until then every
        /// later event is a chance to try again.
        var delivered = false

        init() {}

        /// Written by hand so a file from an older build, or a half-written
        /// one, degrades to defaults rather than failing the event.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            trackID = try container.decodeIfPresent(String.self, forKey: .trackID) ?? ""
            durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? ""
            album = try container.decodeIfPresent(String.self, forKey: .album) ?? ""
            coverPath = try container.decodeIfPresent(String.self, forKey: .coverPath)
            delivered = try container.decodeIfPresent(Bool.self, forKey: .delivered) ?? false
        }
    }

    private static func stateFile(in directory: URL) -> URL {
        directory.appending(path: "current-track.json")
    }

    private static func loadState(in directory: URL) -> TrackState {
        guard
            let data = try? Data(contentsOf: stateFile(in: directory)),
            let state = try? JSONDecoder().decode(TrackState.self, from: data)
        else { return TrackState() }
        return state
    }

    /// Written via a temporary file so a concurrent reader never sees half of
    /// one. Losing this costs a progress bar, so a failure is not reported.
    private static func saveState(_ state: TrackState, in directory: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = stateFile(in: directory)
        let temporary = directory.appending(path: ".current-track.\(getpid()).json")
        guard (try? data.write(to: temporary, options: .atomic)) != nil else { return }
        if (try? FileManager.default.replaceItemAt(file, withItemAt: temporary)) == nil {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    private static func remember(
        _ environment: [String: String], in directory: URL
    ) -> TrackState {
        var state = TrackState()
        state.trackID = environment["TRACK_ID"] ?? ""
        state.durationMs = Int(environment["DURATION_MS"] ?? "") ?? 0
        state.title = environment["NAME"] ?? ""
        state.album = environment["ALBUM"] ?? ""
        state.artist = joined(environment["ARTISTS"])

        // Podcasts carry no artists and no album; the show is the useful
        // stand-in for both.
        if environment["ITEM_TYPE"] == "Episode" {
            let show = environment["SHOW_NAME"] ?? ""
            if state.artist.isEmpty { state.artist = show }
            if state.album.isEmpty { state.album = show }
        }

        let cover = fetchCover(environment["COVERS"] ?? "")
        state.coverPath = cacheCover(cover, trackID: state.trackID, in: directory)
        pruneCovers(in: directory, keeping: state.coverPath)
        return state
    }

    /// librespot passes lists as newline-separated values.
    private static func joined(_ value: String?) -> String {
        (value ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    // MARK: - Cover art

    /// The first cover librespot offered, fetched as bytes.
    ///
    /// COVERS is newline-separated and ordered largest first, which is what we
    /// want: OwnTone scales for its clients, and a 640px JPEG is far below the
    /// 1 MiB ceiling.
    private static func fetchCover(_ covers: String) -> Data? {
        let urls = covers
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { URL(string: $0) }
            .filter { $0.scheme == "https" || $0.scheme == "http" }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = artworkTimeout
        configuration.timeoutIntervalForResource = artworkTimeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        for url in urls {
            // This program is run once per event and exits, so there is no
            // run loop to await on. The semaphore is what turns one request
            // back into the straight line the rest of this file is written in.
            let result = Box<Data?>(nil)
            let semaphore = DispatchSemaphore(value: 0)
            let task = session.dataTask(with: url) { data, response, error in
                if let error {
                    log("could not fetch cover \(url.absoluteString): \(error.localizedDescription)")
                } else if let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) {
                    result.value = data
                }
                semaphore.signal()
            }
            task.resume()
            if semaphore.wait(timeout: .now() + artworkTimeout + 1) == .timedOut {
                task.cancel()
                log("gave up fetching cover \(url.absoluteString)")
                continue
            }
            if let data = result.value, data.count >= 2, data.count <= pictureSizeMax {
                return data
            }
        }
        return nil
    }

    /// Keeps the fetched cover on disk. A track's items may have to be sent
    /// more than once, and re-fetching the same image each time would be
    /// wasteful and could fail the second time round.
    private static func cacheCover(_ data: Data?, trackID: String, in directory: URL) -> String? {
        guard let data, !data.isEmpty else { return nil }
        let file = coverFile(trackID: trackID, in: directory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return file.path
        } catch {
            log("could not cache cover: \(error.localizedDescription)")
            return nil
        }
    }

    private static func coverFile(trackID: String, in directory: URL) -> URL {
        let safe = trackID.filter(\.isLetterOrDigit)
        return directory.appending(path: "cover-\(safe.isEmpty ? "current" : safe).img")
    }

    private static func loadCover(_ path: String?) -> Data? {
        guard let path else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Drops every cached cover but the current one.
    private static func pruneCovers(in directory: URL, keeping keep: String?) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix("cover-") {
            let file = directory.appending(path: name)
            guard file.path != keep else { continue }
            try? manager.removeItem(at: file)
        }
    }

    // MARK: - The pipe

    /// The app creates this alongside the audio pipe, but launchd starts the
    /// agents at login too and nothing orders those two, so an event can
    /// arrive before the app has run. Making it here costs one lstat.
    private static func ensurePipe(_ pipe: URL) {
        var status = stat()
        if lstat(pipe.path, &status) == 0 { return }
        try? FileManager.default.createDirectory(
            at: pipe.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if mkfifo(pipe.path, 0o600) != 0 {
            log("could not create \(pipe.path): \(String(cString: strerror(errno)))")
        }
    }

    /// Writes to the metadata pipe without ever blocking indefinitely.
    ///
    /// Opened O_NONBLOCK so a pipe with no reader fails immediately with ENXIO
    /// rather than hanging. That is the normal state before playback starts,
    /// and librespot waits on this program, so a blocking open here would
    /// stall the events behind it. `patience` is how long to keep trying for
    /// a reader before giving up, for the writes worth it.
    private static func write(_ blob: Data, to pipe: URL, waitingForReader patience: TimeInterval) -> Bool {
        guard let descriptor = openForWriting(pipe, patience: patience) else { return false }
        defer { close(descriptor) }

        let bytes = [UInt8](blob)
        let deadline = Date(timeIntervalSinceNow: writeTimeout)
        var offset = 0

        while offset < bytes.count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                log("timed out writing to \(pipe.path)")
                return false
            }

            var descriptors = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptors, 1, Int32(remaining * 1000))
            if ready < 0 {
                guard errno == EINTR else {
                    log("could not wait on \(pipe.path): \(String(cString: strerror(errno)))")
                    return false
                }
                continue
            }
            guard ready > 0 else { continue }

            let written = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.write(descriptor, base + offset, bytes.count - offset)
            }
            if written < 0 {
                guard errno == EAGAIN || errno == EINTR else {
                    log("the engine closed \(pipe.path) mid-write")
                    return false
                }
                continue
            }
            offset += written
        }
        return true
    }

    /// Opens the pipe for writing without blocking on it. ENXIO means no
    /// reader, which is retried until `patience` runs out; anything else is
    /// an error and reported at once.
    private static func openForWriting(_ pipe: URL, patience: TimeInterval) -> Int32? {
        let deadline = Date(timeIntervalSinceNow: patience)
        while true {
            let descriptor = open(pipe.path, O_WRONLY | O_NONBLOCK)
            if descriptor >= 0 { return descriptor }
            guard errno == ENXIO else {
                log("could not open \(pipe.path): \(String(cString: strerror(errno)))")
                return nil
            }
            guard deadline.timeIntervalSinceNow > 0 else {
                let waited = patience > 0 ? " after \(patience) s" : ""
                log("nothing reading \(pipe.path)\(waited); the engine watches it once playback starts")
                return nil
            }
            usleep(readerPollMicroseconds)
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("metadata: \(message)\n".utf8))
    }
}

/// One value behind a lock, so a completion handler can hand a result back to
/// the thread waiting on it under strict concurrency.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private extension Character {
    var isLetterOrDigit: Bool { isLetter || isNumber }
}
