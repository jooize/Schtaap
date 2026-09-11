import Foundation
import OSLog
import Observation

/// Live view of the engine, shared by every window.
///
/// Reads are pushed: `NotifyClient` tells us which category changed and we
/// refetch just that. Writes are optimistic, so a slider never lags the
/// pointer; the authoritative value arrives moments later on the websocket.
@MainActor
@Observable
final class EngineStore {
    enum Connection: Equatable {
        case connecting
        case online
        case offline(String)

        var isOnline: Bool { self == .online }
    }

    private(set) var connection: Connection = .connecting {
        didSet { if connection.isOnline { isAwaitingFirstContact = false } }
    }

    /// True from `start()` until the engine answers for the first time, or
    /// the grace period runs out. The engine takes a moment to come up -- it
    /// scans its library before it serves anything -- and the notify client
    /// retries throughout, so the honest thing to show meanwhile is
    /// "starting", not "not running". The grace is generous because a wrong
    /// "failed" costs more than a slow spinner.
    private(set) var isAwaitingFirstContact = false
    private var firstContactGrace: Task<Void, Never>?
    private static let firstContactGracePeriod = Duration.seconds(60)
    private(set) var outputs: [Output] = []
    private(set) var player: PlayerStatus?
    private(set) var nowPlaying: NowPlaying?

    /// The engine's position when last read, and when. The engine pushes
    /// state changes, never seconds, so the card ticks from here while
    /// playing. A seek moves it at once, ahead of the engine's confirmation.
    private(set) var progressAnchor: (ms: Int, at: Date)?

    /// Set by a seek: until then the engine is still playing out what came
    /// before it, and its readings are not yet about the new position.
    private var seekSettlingUntil: Date?

    /// How far a reading may be from a seek's target, plus what has played
    /// since, and still count as the engine having caught up with it: the
    /// pipe and the engine's read-ahead between them, with margin.
    private static let seekSettleTolerance = 2_500

    /// The engine reports what the speakers have played. Spotify shows what
    /// it has written, which is ahead by everything in between: the pipe
    /// (64 KB, 371 ms of 44.1 kHz stereo), the engine's read-ahead (250 ms,
    /// our patch) and the AirPlay buffer (2250 ms, owntone's default,
    /// which some receivers insist on). The card shows Spotify's clock,
    /// because that is the other clock a person compares it with; the
    /// speakers are this much behind both. Only while playing: a paused
    /// engine has played everything it was fed, and Spotify is seeked to
    /// that same place by the bridge.
    private static let pipelineLeadMs = 2250 + 371 + 250

    /// What the user just asked Spotify to do, shown until the engine agrees
    /// or a few seconds pass. A pause takes a second or two to reach the
    /// engine (librespot stops writing, the engine runs dry), and the
    /// refresh in between would otherwise flip the button back.
    private(set) var pendingTransport: PlayerStatus.State?
    private var pendingTransportExpiry: Task<Void, Never>?

    /// One more read of the player a few seconds after it starts playing.
    /// The engine reports `play` and then fills the AirPlay buffer in a
    /// burst, so the position read on that event is behind by the buffer
    /// for the rest of the track. The engine pushes nothing later to
    /// correct it; this does.
    private var settleRead: Task<Void, Never>?
    private static let settleReadDelay = Duration.seconds(4)

    var isPlaying: Bool { (pendingTransport ?? player?.state) == .play }

    /// Master volume in 0...100. Written straight through by the slider.
    private(set) var masterVolume: Double = 50

    /// The master as the engine last reported it, which the slider above
    /// does not show while it is held. What Spotify is compared with.
    private var reportedVolume: Int?

    /// True when the user has muted via the popover. The pre-mute level is
    /// kept so unmuting restores it.
    private(set) var isMasterMuted = false
    var preMuteLevel: Double = 50

    private var mutedGroups: Set<String> = []
    private var preMuteGroupVolumes: [String: Int] = [:]

    /// Set when a device answers a selection attempt by displaying a code on
    /// its screen instead of accepting the stream. Apple TVs and some
    /// receivers do this. The popover swaps in a PIN field while it is set.
    private(set) var verifying: Output?
    private(set) var verificationError: String?

    /// Outputs the engine refused to start, by id, with what to tell the user.
    ///
    /// A refusal is answered by a refetch that puts the row back to off, so
    /// without this the click looks like it did nothing at all.
    private(set) var startFailures: [String: String] = [:]

    /// This Mac's name, which is also the name of its own AirPlay receiver.
    /// Read once: `Host.current().localizedName` goes to SystemConfiguration.
    private let localDeviceName = Host.current().localizedName

    /// Speakers the user asked for and the engine has not got right now, by
    /// output id. Each is being retried until it comes back. See
    /// `IntendedOutputs` for why this exists.
    private(set) var rejoining: Set<String> = []

    /// What the user asked for, persisted so it outlives the app. Nil under
    /// fixtures, where it must not be read or written.
    private var intended: IntendedOutputs?
    private var rejoinTasks: [String: Task<Void, Never>] = [:]

    /// Seconds between attempts to win a speaker back. Capped at the last
    /// entry: a speaker taken for a film should not be hammered all evening,
    /// but it should still come back within the minute of being freed.
    private static let rejoinBackoff: [Duration] = [
        .seconds(5), .seconds(10), .seconds(20), .seconds(30), .seconds(60),
    ]

    /// Whether to hold the system's Now Playing slot. Off, the slot is left to
    /// whatever else on this Mac wants it.
    var publishesNowPlaying = true {
        didSet { publishNowPlaying() }
    }
    private let nowPlayingCenter = NowPlayingCenter()

    let client: EngineClient

    /// The other direction: what the app tells Spotify. Nil under fixtures,
    /// which must never reach a socket.
    private let spotify: SpotifyControl?
    private var spotifyVolumeSync: Task<Void, Never>?

    /// Who is using the receiver, from the file the event bridge keeps.
    private(set) var spotifySession: SpotifySession?
    private var spotifySessionWatch: DispatchSourceFileSystemObject?

    /// Whether librespot can reach Spotify's servers: what `status` says,
    /// asked every so often. Idle is the honest state before anyone has
    /// ever picked the device, when there is no session to be alive.
    enum SpotifyUplink: Equatable {
        case idle, live, lost, down
    }

    private(set) var spotifyUplink: SpotifyUplink = .idle
    private var spotifyUplinkPoll: Task<Void, Never>?
    private var spotifyUplinkFailures = 0
    private static let spotifyUplinkInterval = Duration.seconds(20)

    /// Bonjour lookup for device hardware, which the engine's API omits.
    let directory = AirPlayDirectory()

    private let notify: NotifyClient
    private let usesFixtures: Bool

    /// Outputs whose slider the user is currently dragging. Refreshes leave
    /// their volume alone so the knob does not fight the pointer.
    private var adjusting: Set<String> = []
    private static let log = Logger(subsystem: "bar.esko.Schtaap", category: "store")
    private var isAdjustingMaster = false

    /// One in-flight debounce per output, plus one for master.
    private var volumeWrites: [String: Task<Void, Never>] = [:]
    private var lifecycle: Task<Void, Never>?

    private static let volumeDebounce = Duration.milliseconds(120)
    private static let masterKey = "__master__"

    init(endpoint: EngineEndpoint = .default, usesFixtures: Bool = false) {
        self.client = EngineClient(endpoint: endpoint)
        self.notify = NotifyClient(endpoint: endpoint)
        self.usesFixtures = usesFixtures
        // Left nil until the first live refresh when there is no file yet, so
        // the speakers already playing become the intent rather than an
        // empty set that would treat them as nobody's.
        self.intended = usesFixtures ? nil : IntendedOutputs.load(from: Self.intendedFile)
        self.spotify = usesFixtures ? nil : SpotifyControl(socket: EngineInstallation().controlSocket)

        // A media key pauses and plays Spotify itself, through librespot's
        // control socket, so the phone shows the same state.
        nowPlayingCenter.onPause = { [weak self] in self?.pausePlayback() }
        nowPlayingCenter.onPlay = { [weak self] in self?.resumePlayback() }
        nowPlayingCenter.onNext = { [weak self] in self?.skipToNext() }
        nowPlayingCenter.onPrevious = { [weak self] in self?.skipToPrevious() }
        nowPlayingCenter.onSeek = { [weak self] in self?.seek(toMs: $0) }
    }

    private static var intendedFile: URL {
        Branding.supportDirectory.appending(path: "intended-outputs.json")
    }

    // MARK: - Lifecycle

    func start() {
        guard lifecycle == nil else { return }

        if usesFixtures {
            applyFixtures()
            return
        }

        isAwaitingFirstContact = true
        firstContactGrace = Task { [weak self] in
            try? await Task.sleep(for: Self.firstContactGracePeriod)
            guard !Task.isCancelled else { return }
            self?.isAwaitingFirstContact = false
        }

        lifecycle = Task { [weak self] in
            guard let self else { return }
            await self.refreshAll()
            for await message in self.notify.stream() {
                await self.handle(message)
            }
        }

        watchSpotifySession()
        spotifyUplinkPoll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkSpotifyUplink()
                try? await Task.sleep(for: Self.spotifyUplinkInterval)
            }
        }
    }

    // MARK: - Spotify's side

    private static var spotifySessionFile: URL {
        Branding.supportDirectory.appending(path: SpotifySessionFile.name)
    }

    /// The bridge replaces the file atomically, which is a write to the
    /// directory, so the directory is what is watched: a watch on the file
    /// itself would follow the old inode into the bin.
    private func watchSpotifySession() {
        reloadSpotifySession()
        let directory = Self.spotifySessionFile.deletingLastPathComponent()
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Self.log.error("cannot watch \(directory.path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.reloadSpotifySession() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        spotifySessionWatch = source
    }

    /// Asks the helper for a fresh Local Network reading now, rather than at
    /// its next interval: the popover opening is when a stale one shows.
    /// A touch of the file the helper's probe loop watches; the reading
    /// comes back through the session file like any other.
    func requestLocalNetworkProbe() {
        guard !usesFixtures else { return }
        let file = Branding.supportDirectory.appending(path: "local-network-probe-request")
        try? Data(Date().description.utf8).write(to: file)
    }

    private func reloadSpotifySession() {
        let session = SpotifySessionFile.read(at: Self.spotifySessionFile)
        if session != spotifySession {
            spotifySession = session
        }
    }

    /// One `status` round trip. Two failures in a row mean librespot is not
    /// answering, not a restart in progress.
    private func checkSpotifyUplink() async {
        guard let spotify else { return }
        do {
            let status = try await spotify.status()
            spotifyUplinkFailures = 0
            let uplink: SpotifyUplink = switch status.session {
            case "live": .live
            case "lost": .lost
            default: .idle
            }
            if uplink != spotifyUplink { spotifyUplink = uplink }
        } catch {
            spotifyUplinkFailures += 1
            if spotifyUplinkFailures >= 2, spotifyUplink != .down {
                Self.log.info("Spotify uplink: \(error.localizedDescription, privacy: .public)")
                spotifyUplink = .down
            }
        }
    }

    func stop() {
        directory.stop()
        lifecycle?.cancel()
        lifecycle = nil
        firstContactGrace?.cancel()
        firstContactGrace = nil
        isAwaitingFirstContact = false
        for task in volumeWrites.values { task.cancel() }
        volumeWrites.removeAll()
        spotifyUplinkPoll?.cancel()
        spotifyUplinkPoll = nil
        spotifySessionWatch?.cancel()
        spotifySessionWatch = nil
        spotifyVolumeSync?.cancel()
        spotifyVolumeSync = nil
        reportedVolume = nil
        pendingTransportExpiry?.cancel()
        pendingTransport = nil
        settleRead?.cancel()
        settleRead = nil
        for task in rejoinTasks.values { task.cancel() }
        rejoinTasks.removeAll()
        rejoining.removeAll()
        nowPlayingCenter.clear()
    }

    private func handle(_ message: NotifyMessage) async {
        switch message {
        case .connected:
            connection = .online
            await refreshAll()
        case .disconnected(let reason):
            connection = .offline(reason)
        case .events(let events):
            // A tap on a speaker's top means the same as a media key here:
            // Spotify pauses and plays, and the phone shows it. The speaker
            // says which way it believes it is toggling, and it is wrong
            // after a pause it was never told about: the engine pauses it
            // with a flush, which leaves it thinking it is playing, so its
            // next tap says "pause" to a paused player and the user has to
            // tap twice. Either message means "the other one" from here.
            if events.contains(.remotePause) || events.contains(.remotePlay) {
                if isPlaying {
                    pausePlayback()
                } else {
                    resumePlayback()
                }
            }
            if events.contains(.outputs) || events.contains(.volume) {
                await refreshOutputs()
            }
            if events.contains(.player) || events.contains(.volume) {
                await refreshPlayer()
            }
            if events.contains(.player) || events.contains(.queue) {
                await refreshNowPlaying()
            }
        }
    }

    // MARK: - Reads

    func refreshAll() async {
        await refreshOutputs()
        await refreshPlayer()
        await refreshNowPlaying()
    }

    func refreshOutputs() async {
        guard !usesFixtures else { return }
        do {
            let fetched = try await client.outputs()
            outputs = fetched.map { output in
                // Preserve the value under an active pointer.
                guard adjusting.contains(output.id),
                      let local = outputs.first(where: { $0.id == output.id })
                else { return output }
                var merged = output
                merged.volume = local.volume
                return merged
            }
            for output in outputs where output.selected {
                let held = adjusting.contains(output.id)
                Self.log.notice("refreshOutputs: \(output.name, privacy: .public) volume \(output.volume) adjusting \(held)")
            }
            connection = .online
            adoptSelectionIfUnset()
            reconcileRejoins()
        } catch {
            connection = .offline(error.localizedDescription)
        }
    }

    func refreshPlayer() async {
        guard !usesFixtures else { return }
        do {
            let status = try await client.player()
            adoptProgress(from: status, previousItem: player?.itemId)
            let startedPlaying = status.state == .play && player?.state != .play
            player = status
            if startedPlaying {
                settleRead?.cancel()
                settleRead = Task { [weak self] in
                    try? await Task.sleep(for: Self.settleReadDelay)
                    guard !Task.isCancelled else { return }
                    await self?.refreshPlayer()
                }
            }
            if status.state == pendingTransport {
                pendingTransportExpiry?.cancel()
                pendingTransport = nil
            }
            if !isAdjustingMaster {
                masterVolume = Double(status.volume)
            }
            let previousVolume = reportedVolume
            reportedVolume = status.volume
            if let previousVolume, previousVolume != status.volume {
                syncSpotifyVolume(from: previousVolume, to: status.volume)
            }
            publishNowPlaying()
        } catch {
            connection = .offline(error.localizedDescription)
        }
    }

    func refreshNowPlaying() async {
        guard !usesFixtures else { return }
        nowPlaying = try? await client.nowPlaying()
        publishNowPlaying()
    }

    /// Hands the current track to the system's Now Playing slot, or lets go
    /// of it. Fixtures never touch the slot: it is shared with every other
    /// app on the Mac, which makes it as far from offline as the network.
    private func publishNowPlaying() {
        guard !usesFixtures else { return }
        guard publishesNowPlaying, connection.isOnline else {
            nowPlayingCenter.clear()
            return
        }
        let artwork = nowPlaying?.artworkUrl.flatMap { path -> URL? in
            guard !path.isEmpty else { return nil }
            return client.artworkURL(for: path, maxPixels: 600)
        }
        nowPlayingCenter.publish(track: nowPlaying, player: player, artworkURL: artwork)
    }

    // MARK: - Spotify

    /// Where the track is at `date`: the last reading plus what has played
    /// since, held while paused and while a pause is pending.
    func progressMs(at date: Date) -> Int {
        // Spotify stopped at the end of its playlist. The engine holds the
        // last track paused a few seconds short of its end (the heard
        // position); Spotify shows it at the start, and a play begins there.
        if spotifySession?.isStopped == true { return 0 }
        guard let progressAnchor else { return 0 }
        guard isPlaying else { return progressAnchor.ms }
        let elapsed = Int(date.timeIntervalSince(progressAnchor.at) * 1000)
        let length = player?.itemLengthMs ?? nowPlaying?.lengthMs ?? .max
        return min(progressAnchor.ms + max(elapsed, 0), length)
    }

    /// The engine's reading is the card's clock, with one exception: for a
    /// few seconds after a seek the engine is still playing out the audio
    /// from before it, and its readings describe that, not the target. Those
    /// are skipped until one lands near the target; a track change ends the
    /// wait at once.
    private func adoptProgress(from status: PlayerStatus, previousItem: Int?) {
        let now = Date.now
        let sameItem = progressAnchor != nil && status.itemId == previousItem
        // Between a play and the engine reporting it, the engine is filling
        // the AirPlay buffer and reports "pause" at the position it resumed
        // from. Spotify is already running; so is the card's own clock.
        if sameItem, pendingTransport == .play, status.state != .play {
            return
        }
        let reading = status.itemProgressMs + (status.state == .play ? Self.pipelineLeadMs : 0)
        if sameItem, let until = seekSettlingUntil, now < until,
           abs(reading - progressMs(at: now)) > Self.seekSettleTolerance {
            return
        }
        progressAnchor = (reading, now)
        seekSettlingUntil = nil
    }

    /// Pauses Spotify itself. The event bridge then pauses the engine, which
    /// flushes the speakers, and seeks Spotify back to where the sound
    /// stopped (`EngineTransport` in the helper), so the phone, the engine
    /// and the speakers agree. Not a mute: the track stops advancing. The
    /// popover's speaker icon stays a mute.
    func pausePlayback() {
        // Freeze the clock where it stands. Once a pause is expected the
        // card stops ticking, and would show the anchor, which is the
        // engine's last reading: the start of the track, or wherever the
        // last event was. That was the 0:00 that flashed before the
        // engine's paused position arrived.
        if progressAnchor != nil {
            progressAnchor = (progressMs(at: .now), .now)
        }
        expect(.pause)
        tellSpotify("pause") { try await $0.pause() }
    }

    /// Resumes, and starts the card's clock from the paused position at
    /// once, as Spotify does: the engine's own position stands still for
    /// the seconds it takes to refill the AirPlay buffer, and readings from
    /// that stretch are held off like the ones after a seek.
    func resumePlayback() {
        expect(.play)
        if let progressAnchor {
            self.progressAnchor = (progressAnchor.ms, .now)
            seekSettlingUntil = .now.addingTimeInterval(8)
        }
        tellSpotify("play") { try await $0.play() }
    }

    func skipToNext() {
        showTrackStart()
        tellSpotify("next") { try await $0.next() }
    }

    func skipToPrevious() {
        showTrackStart()
        tellSpotify("previous") { try await $0.previous() }
    }

    /// A skip lands at the start of a track, a previous included: past the
    /// first seconds Spotify restarts the current one instead. The card
    /// goes to 0:00 at once, as the phone does, and holds off the engine's
    /// readings the way a seek does: for a few seconds after the skip the
    /// speakers are still playing out the old track, and the engine says
    /// so.
    private func showTrackStart() {
        progressAnchor = (0, .now)
        seekSettlingUntil = .now.addingTimeInterval(8)
    }

    /// Moves within the track. The card shows the new position at once; the
    /// engine's own reading follows through the metadata bridge.
    func seek(toMs position: Int) {
        progressAnchor = (position, .now)
        seekSettlingUntil = .now.addingTimeInterval(8)
        tellSpotify("seek") { try await $0.seek(toMs: position) }
    }

    private func expect(_ state: PlayerStatus.State) {
        pendingTransport = state
        pendingTransportExpiry?.cancel()
        pendingTransportExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.pendingTransport = nil
        }
    }

    private func tellSpotify(_ what: String, _ command: @escaping @Sendable (SpotifyControl) async throws -> Void) {
        guard let spotify else { return }
        Task {
            do {
                try await command(spotify)
            } catch {
                Self.log.error("\(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Makes the phone's slider follow the engine's master when the master
    /// moved for a reason of its own: this slider, a HomePod's buttons, a
    /// mute.
    ///
    /// Only when Spotify was where the engine was before the change. A
    /// change that came from Spotify finds Spotify already past the old
    /// level: at the new one, or, while the phone's slider is still moving,
    /// at a later one the event bridge has yet to bring the engine to.
    /// Sending the engine's level then would pull the phone back to where
    /// it just was, which is what it did. The order decides this, not a
    /// clock. What is sent raises no volume event (our librespot patch), so
    /// nothing here comes back to the engine. Sequential on purpose, so a
    /// burst of changes reaches Spotify in order and each finds the level
    /// the one before it left.
    private func syncSpotifyVolume(from previous: Int, to percent: Int) {
        guard let spotify else { return }
        let earlier = spotifyVolumeSync
        spotifyVolumeSync = Task {
            await earlier?.value
            guard !Task.isCancelled else { return }
            do {
                let current = try await spotify.volume()
                guard SpotifyControl.percent(spotifyLevel: current) == previous else { return }
                try await spotify.setVolume(SpotifyControl.spotifyLevel(percent: percent))
            } catch {
                // librespot down or unpatched: the phone keeps its own level,
                // which is what it did before there was a socket.
                Self.log.info("volume sync: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Writes

    /// Fixtures exist to run the UI with no engine, so every write below stops
    /// at the optimistic local update and never reaches the network.
    ///
    /// This is not belt and braces. The default endpoint is localhost:3689, and
    /// a Lima VM forwards that port to a real owntone, so an unguarded refresh
    /// answers 200 and swaps the fixture speakers for the household's -- whose
    /// names the fixture directory knows nothing about, so every icon goes
    /// generic and every pair comes apart the first time anything is clicked.
    private var isOffline: Bool { usesFixtures }

    func toggle(_ output: Output) {
        // A device that has already asked for a code goes straight back to the
        // prompt rather than through another attempt that can only fail.
        if !output.selected, output.needsVerification {
            beginVerification(for: output)
            return
        }
        setSelected(!output.selected, for: output)
    }

    func setSelected(_ selected: Bool, for output: Output) {
        apply(to: output.id) { $0.selected = selected }
        // Trying again clears the last complaint, whatever comes of this one.
        startFailures[output.id] = nil
        // This is the user speaking, which is the only thing that rewrites
        // what they asked for. Switching a speaker off also calls off any
        // attempt to win it back.
        setIntended(selected, output)
        guard !isOffline else { return }

        Task { [client] in
            do {
                try await client.setSelected(selected, forOutput: output.id)
            } catch {
                self.startFailures[output.id] = Self.startFailureText(error, selecting: selected)
            }
            await self.refreshOutputs()
            if selected { self.promptForVerificationIfNeeded(output.id) }
        }
    }

    /// What the engine's refusal is worth saying in a 300pt row.
    ///
    /// The engine answers a failed activation with a bare 400 -- the reason is
    /// in its log and not in the response -- so the status code is all we have
    /// to go on. Anything that is not an HTTP status is the network.
    private static func startFailureText(_ error: Error, selecting: Bool) -> String {
        guard case EngineError.http = error else { return error.localizedDescription }
        return selecting ? "This speaker would not start" : "This speaker would not stop"
    }

    /// The complaint to show on a row, if any member of it has one.
    func startFailure(for group: SpeakerGroup) -> String? {
        group.members.lazy.compactMap { self.startFailures[$0.id] }.first
    }

    // MARK: - Device verification

    func beginVerification(for output: Output) {
        verifying = output
        verificationError = nil
    }

    func cancelVerification() {
        verifying = nil
        verificationError = nil
    }

    func submitVerification(pin: String) {
        guard let output = verifying else { return }

        // No engine to accept a code, so any code passes and the flow can still
        // be walked through offline.
        guard !isOffline else {
            apply(to: output.id) { $0.selected = true }
            cancelVerification()
            return
        }

        Task { [client] in
            do {
                try await client.verify(pin: pin, forOutput: output.id)
                await self.refreshOutputs()
                if self.outputs.first(where: { $0.id == output.id })?.selected == true {
                    self.setIntended(true, output)
                    self.cancelVerification()
                } else {
                    self.verificationError = "That code was not accepted."
                }
            } catch {
                self.verificationError = error.localizedDescription
            }
        }
    }

    /// A selection that left the output unselected and asking for a key means
    /// the device is now showing a code.
    private func promptForVerificationIfNeeded(_ id: String) {
        guard let current = outputs.first(where: { $0.id == id }) else { return }
        guard current.needsVerification, !current.selected else { return }
        beginVerification(for: current)
    }

    func setVolume(_ value: Double, for output: Output) {
        let level = Int(value.rounded())
        apply(to: output.id) { $0.volume = level }
        guard !isOffline else { return }
        debounce(key: output.id) { [client] in
            try? await client.setVolume(level, forOutput: output.id)
        }
    }

    func beginAdjusting(_ output: Output) {
        adjusting.insert(output.id)
    }

    func endAdjusting(_ output: Output) {
        adjusting.remove(output.id)
        volumeWrites[output.id]?.cancel()
        guard !isOffline else { return }
        let level = outputs.first(where: { $0.id == output.id })?.volume ?? output.volume
        Task { [client] in
            try? await client.setVolume(level, forOutput: output.id)
            await self.refreshOutputs()
        }
    }

    func setMasterVolume(_ value: Double) {
        masterVolume = value
        guard !isOffline else { return }
        let level = Int(value.rounded())
        debounce(key: Self.masterKey) { [client] in
            try? await client.setMasterVolume(level)
        }
    }

    func beginAdjustingMaster() {
        isAdjustingMaster = true
    }

    func endAdjustingMaster() {
        isAdjustingMaster = false
        volumeWrites[Self.masterKey]?.cancel()
        guard !isOffline else { return }
        let level = Int(masterVolume.rounded())
        Task { [client] in
            try? await client.setMasterVolume(level)
            await self.refreshPlayer()
        }
    }

    func toggleMasterMute() {
        if isMasterMuted {
            isMasterMuted = false
            setMasterVolume(preMuteLevel)
        } else {
            preMuteLevel = masterVolume
            isMasterMuted = true
            setMasterVolume(0)
        }
    }

    func toggleGroupMute(_ group: SpeakerGroup) {
        if mutedGroups.contains(group.id) {
            mutedGroups.remove(group.id)
            let restore = preMuteGroupVolumes[group.id] ?? group.volume
            setGroupVolume(Double(restore), for: group)
        } else {
            preMuteGroupVolumes[group.id] = group.volume
            mutedGroups.insert(group.id)
            setGroupVolume(0, for: group)
        }
    }

    func isGroupMuted(_ group: SpeakerGroup) -> Bool {
        mutedGroups.contains(group.id)
    }

    func preMuteGroupLevel(for group: SpeakerGroup) -> Int {
        preMuteGroupVolumes[group.id] ?? group.volume
    }

    func setPreMuteGroupLevel(_ value: Double, for group: SpeakerGroup) {
        preMuteGroupVolumes[group.id] = Int(value.rounded())
    }

    // MARK: - Rejoining speakers

    private func setIntended(_ wanted: Bool, _ output: Output) {
        guard var set = intended else { return }
        if wanted { set.insert(output) } else { set.remove(output) }
        guard set != intended else { return }
        intended = set
        set.save(to: Self.intendedFile)
        if !wanted { endRejoin(output.id) }
    }

    /// The first live refresh on a Mac with no record yet takes whatever is
    /// playing as what was asked for. Until then every speaker is nobody's.
    private func adoptSelectionIfUnset() {
        guard intended == nil, !usesFixtures else { return }
        var set = IntendedOutputs()
        for output in outputs where output.selected && output.isAirPlay {
            set.insert(output)
        }
        intended = set
        set.save(to: Self.intendedFile)
    }

    /// Lines the engine's selection up against the intent after every
    /// refresh. An intended speaker that is not playing starts being won
    /// back; one that is playing again, or was given up on, stops.
    private func reconcileRejoins() {
        guard let intended, !isOffline else { return }
        var live: Set<String> = []
        for output in outputs where output.isAirPlay {
            let wanted = intended.contains(output)
            // A device asking for its code is not busy, it is waiting on the
            // user, and retrying would only make it show the code again.
            if wanted, !output.selected, !output.needsVerification {
                live.insert(output.id)
                beginRejoin(output.id)
            } else {
                endRejoin(output.id)
            }
        }
        for id in rejoining.subtracting(live) { endRejoin(id) }
    }

    private func beginRejoin(_ id: String) {
        guard rejoinTasks[id] == nil else { return }
        rejoining.insert(id)
        rejoinTasks[id] = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                let delay = Self.rejoinBackoff[min(attempt, Self.rejoinBackoff.count - 1)]
                attempt += 1
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                // The engine answers a speaker that is still taken with a
                // refusal, and that refusal is the probe: nothing else on the
                // network says whether it is free.
                let joined = (try? await self.client.setSelected(true, forOutput: id)) != nil
                guard !Task.isCancelled else { return }
                if joined { self.startFailures[id] = nil }
                // Refreshing runs the reconcile, which ends this task once the
                // speaker reports itself playing.
                await self.refreshOutputs()
            }
        }
    }

    private func endRejoin(_ id: String) {
        rejoinTasks[id]?.cancel()
        rejoinTasks[id] = nil
        rejoining.remove(id)
    }

    /// Whether any member of a row is being won back.
    func isRejoining(_ group: SpeakerGroup) -> Bool {
        group.members.contains { rejoining.contains($0.id) }
    }

    // MARK: - Speaker groups

    /// Outputs merged into rows: stereo pairs become one entry with a shared
    /// volume slider and toggle.
    ///
    /// Whatever is playing sorts to the top -- those rows carry sliders and are
    /// the ones being adjusted -- and everything else follows alphabetically, so
    /// a pair and the Apple TV it belongs to still sit together within each
    /// half. Collapsing the list drops rows off the bottom and never reorders
    /// what stays.
    var speakerGroups: [SpeakerGroup] {
        let visible = outputs.filter { $0.isAirPlay }
        var pairBuckets: [String: [Output]] = [:]
        var singles: [Output] = []

        for output in visible {
            if let identity = directory.identity(forOutputNamed: output.name),
               identity.isStereoPairMember,
               let pairID = identity.pairID {
                pairBuckets[pairID, default: []].append(output)
            } else {
                singles.append(output)
            }
        }

        var groups: [SpeakerGroup] = []

        for (pairID, members) in pairBuckets {
            let sorted = members.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let displayName = SpeakerGroup.derivePairName(from: sorted)
            let identity = directory.identity(forOutputNamed: sorted[0].name)
            let symbol = SymbolCatalog.name(identity?.symbolName ?? sorted[0].symbolName)

            groups.append(SpeakerGroup(
                id: pairID,
                displayName: displayName,
                members: sorted,
                symbolName: symbol,
                memberSymbolName: unitSymbolName(for: sorted[0]),
                groupName: identity?.groupName,
                isPair: true,
                isRejoining: sorted.contains { rejoining.contains($0.id) }
            ))
        }

        for output in singles {
            groups.append(SpeakerGroup(
                id: output.id,
                displayName: output.name,
                members: [output],
                symbolName: symbolName(for: output),
                memberSymbolName: unitSymbolName(for: output),
                groupName: groupName(for: output),
                isPair: false,
                isThisMac: isThisMac(output),
                isRejoining: rejoining.contains(output.id)
            ))
        }

        // Playing first, then the ones on their way back, then the rest. A
        // speaker being won back is still one of the user's, so it stays up
        // with them rather than dropping into the silent alphabet below.
        groups.sort { left, right in
            if left.anySelected != right.anySelected { return left.anySelected }
            if left.isRejoining != right.isRejoining { return left.isRejoining }
            return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
        return groups
    }

    func toggle(_ group: SpeakerGroup) {
        let target = !group.selected
        for member in group.members where member.selected != target {
            if !target || !member.needsVerification {
                setSelected(target, for: member)
            } else {
                beginVerification(for: member)
            }
        }
    }

    func setGroupVolume(_ value: Double, for group: SpeakerGroup) {
        for member in group.members {
            setVolume(value, for: member)
        }
    }

    func beginAdjusting(_ group: SpeakerGroup) {
        for member in group.members { adjusting.insert(member.id) }
    }

    func endAdjusting(_ group: SpeakerGroup) {
        for member in group.members { endAdjusting(member) }
    }

    // MARK: - Presentation

    /// The icon for an output: its real hardware when Bonjour has told us,
    /// the coarse guess from the engine's output type otherwise.
    func symbolName(for output: Output) -> String {
        let name = directory.identity(forOutputNamed: output.name)?.symbolName ?? output.symbolName
        return SymbolCatalog.name(name)
    }

    /// The icon for one physical unit of an output, never the joined two-unit
    /// variant. A merged pair row draws one per member so each can be tinted by
    /// its own selection.
    func unitSymbolName(for output: Output) -> String {
        let name = directory.identity(forOutputNamed: output.name)?.unitSymbolName ?? output.symbolName
        return SymbolCatalog.name(name)
    }

    /// The group a speaker was adopted into, when that is not simply itself --
    /// a HomePod pair belonging to an Apple TV's home theatre, say.
    func groupName(for output: Output) -> String? {
        directory.identity(forOutputNamed: output.name)?.groupName
    }

    /// Whether an output is this Mac's own AirPlay receiver.
    ///
    /// macOS names that receiver after the computer, and the engine reports it
    /// like any other speaker on the network, so the name is the whole test.
    /// Renaming the receiver away from the computer name is possible and costs
    /// only the badge.
    func isThisMac(_ output: Output) -> Bool {
        guard let localDeviceName else { return false }
        return output.name.compare(localDeviceName, options: .caseInsensitive) == .orderedSame
    }

    /// Starts the Bonjour browse.
    ///
    /// Called when the popover first appears rather than at launch, so the
    /// local network prompt arrives with the speaker list on screen instead of
    /// unexplained at login.
    func startDirectoryIfEnabled() {
        guard !usesFixtures else { return }
        directory.start()
    }

    // MARK: - Helpers

    /// Seeds state directly, bypassing the network. Used by fixtures.
    func load(outputs: [Output], player: PlayerStatus?, nowPlaying: NowPlaying?) {
        self.outputs = outputs
        self.player = player
        self.nowPlaying = nowPlaying
        self.masterVolume = Double(player?.volume ?? 50)
        self.connection = .online
    }

    private func apply(to id: String, _ mutate: (inout Output) -> Void) {
        guard let index = outputs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&outputs[index])
    }

    private func debounce(key: String, _ work: @escaping @Sendable () async -> Void) {
        volumeWrites[key]?.cancel()
        volumeWrites[key] = Task {
            try? await Task.sleep(for: Self.volumeDebounce)
            guard !Task.isCancelled else { return }
            await work()
        }
    }
}
