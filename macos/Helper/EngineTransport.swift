import Foundation

/// Keeps the engine's transport in step with Spotify's, from the one place
/// that hears every change: the event bridge librespot runs.
///
/// Left alone, the engine learns of a pause by running dry. librespot stops
/// writing, the engine streams silence through its read deficit, then
/// suspends and flushes the speakers: about two seconds after the pause,
/// wherever it came from. And when playback resumes, librespot carries on
/// from its own position, which is ahead of the last sound the speakers
/// made by everything that was buffered between them, so those seconds are
/// never heard.
///
/// So on `paused` this pauses the engine at once, which flushes the
/// speakers, and seeks Spotify back to where the sound actually stopped.
/// On `playing` it starts the engine again, and librespot is already
/// writing from that position. The phone's slider shows the same place.
/// The app's own pause and play only ever tell Spotify, and come through
/// here like the phone's, so there is exactly one path. A `stopped` (the
/// end of a playlist) is a pause too: the phone still names this device,
/// so the speakers stay taken. Only a lost session stops the engine,
/// which is what lets the AirPlay sessions go: a pause keeps them (our
/// owntone patch), so that a HomePod's tap still reaches us, and a stop
/// is the one thing that ends them.
///
/// The order on a pause matters: librespot closes its end of the pipe
/// before it reports `paused`, and the engine's pause closes and reopens
/// its end. With both ends closed for a moment the pipe's leftover bytes
/// go with it, and there is no writer for the close to break.
struct EngineTransport {
    /// The engine's JSON API. Localhost is in its trusted networks.
    let engine: URL
    /// librespot's control socket, for the seek.
    let socket: URL

    private static let timeout: TimeInterval = 1.5

    /// How far past the engine's position a resume starts, in milliseconds.
    ///
    /// The position is read before the engine is told to pause, and its
    /// FLUSH reaches the speakers an RTSP round trip after that, so they
    /// play a few tens of milliseconds past it. Resuming exactly there
    /// plays those again, which is heard as a short stutter. A gap of the
    /// same size is not heard, so err on that side.
    private static let flushLagMs = 80

    /// The engine's player state and position, from `GET /api/player`.
    private struct PlayerState: Decodable {
        let state: String
        let itemProgressMs: Int

        private enum CodingKeys: String, CodingKey {
            case state
            case itemProgressMs = "item_progress_ms"
        }
    }

    /// Spotify paused. Pause the engine, then put Spotify where the sound is.
    func paused() {
        guard let before = player() else { return }
        guard before.state == "play" else {
            log("engine is \(before.state), nothing to pause")
            return
        }
        guard put("api/player/pause") else { return }

        // The engine's position is what the speakers have played: it counts
        // only once the AirPlay buffer ahead of it is full (player.c,
        // play_start). Read before the pause, which restarts the input.
        let heard = before.itemProgressMs
        let resume = heard + Self.flushLagMs
        do {
            let control = SpotifyControl(socket: socket)
            _ = try control.exchangeBlocking("seek \(resume)")
            log("paused the engine at \(heard) ms, Spotify back to \(resume) ms")
        } catch {
            log("paused the engine at \(heard) ms, but could not seek Spotify: \(error.localizedDescription)")
        }
    }

    /// Spotify stopped: the end of a playlist, or nothing left to play. The
    /// phone still shows this device as its speaker, so the speakers stay
    /// ours: a pause silences them and keeps the sessions, and the next
    /// play, on whatever comes next, is a resume rather than a reconnect.
    func stopped() {
        guard let state = player() else { return }
        guard state.state == "play" else {
            log("engine is \(state.state), nothing to stop")
            return
        }
        if put("api/player/pause") {
            log("paused the engine for Spotify's stop")
        }
    }

    /// Spotify's session went: the phone picked another device, or Spotify
    /// disconnected. Stop the engine; the speakers are released after its
    /// own timeout, for whoever wants them next.
    func sessionEnded() {
        guard let state = player() else { return }
        guard state.state != "stop" else { return }
        if put("api/player/stop") {
            log("stopped the engine")
        }
    }

    /// Spotify plays. Start the engine if it was waiting.
    func playing() {
        guard let state = player() else { return }
        guard state.state == "pause" else { return }
        if put("api/player/play") {
            log("resumed the engine")
        }
    }

    // MARK: - Engine API

    private func player() -> PlayerState? {
        var request = URLRequest(url: engine.appending(path: "api/player"))
        request.httpMethod = "GET"
        guard let data = perform(request) else { return nil }
        do {
            return try JSONDecoder().decode(PlayerState.self, from: data)
        } catch {
            log("could not read the engine's player state: \(error.localizedDescription)")
            return nil
        }
    }

    private func put(_ path: String) -> Bool {
        var request = URLRequest(url: engine.appending(path: path))
        request.httpMethod = "PUT"
        return perform(request) != nil
    }

    /// Synchronous on purpose: this program handles one event and exits,
    /// and the next event waits for it. See `MetadataBridge.fetchCover`.
    private func perform(_ request: URLRequest) -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let result = Box<Data?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                log("\(request.httpMethod ?? "") \(request.url?.path ?? ""): \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                result.value = data ?? Data()
            } else if let http = response as? HTTPURLResponse {
                log("\(request.httpMethod ?? "") \(request.url?.path ?? ""): HTTP \(http.statusCode)")
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + Self.timeout + 0.5) == .timedOut {
            task.cancel()
            log("\(request.httpMethod ?? "") \(request.url?.path ?? ""): no answer")
        }
        return result.value
    }

    /// Stamped like librespot's own lines, so the gap between its event
    /// and the seek this ends with can be read off the log.
    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(stamp)] transport: \(message)\n".utf8))
    }
}
