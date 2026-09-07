import Foundation

/// Whether a Spotify client is using this receiver, and which one.
///
/// librespot reports it as events: `session_connected` when a phone picks
/// the device, `session_client_changed` with what that client is, and
/// `session_disconnected` when it lets go. The event bridge (the helper's
/// `metadata` mode) records them here, the helper's `librespot` mode
/// resets the file when it starts librespot, so a crash never leaves a
/// phantom connection, and the app watches the file. It is the only
/// channel between the two, and it is one small JSON file on purpose.
struct SpotifySession: Codable, Equatable, Sendable {
    var active = false
    var userName: String?
    var clientName: String?
    var clientBrand: String?
    var clientModel: String?
    /// Spotify's own transport state, `playing`, `paused` or `stopped`,
    /// from the last event that said. `stopped` is the end of a playlist:
    /// the engine is merely paused then, holding the last track, and the
    /// card should not pretend that track is paused near its end.
    var playback: String?
    var changedAt = Date()

    var isStopped: Bool { active && playback == "stopped" }

    /// The client as a person would name it. librespot passes what Spotify
    /// tells it about the controlling app, which is a model ("iPhone"), an
    /// app name and a brand in the good case, and nothing in the bad one.
    var clientDescription: String? {
        for candidate in [clientModel, clientName, clientBrand] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }
}

enum SpotifySessionFile {
    static let name = "spotify-session.json"

    static func read(at url: URL) -> SpotifySession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SpotifySession.self, from: data)
    }

    /// Replaces the file atomically, so a reader never sees half of it, and
    /// so a watcher on the directory sees exactly one change.
    static func write(_ session: SpotifySession, to url: URL) {
        guard let data = try? encoder.encode(session) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    static func update(at url: URL, _ change: (inout SpotifySession) -> Void) {
        var session = read(at: url) ?? SpotifySession()
        change(&session)
        session.changedAt = Date()
        write(session, to: url)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
