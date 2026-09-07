import Foundation
import OSLog

/// The app's way of telling Spotify something, as opposed to hearing it.
///
/// librespot is a Connect receiver: the phone drives it and it reports back.
/// Our patch adds `--control-socket`, a Unix socket that takes play, pause,
/// next, prev and volume and routes them through Spirc, so a change made
/// here shows on the phone within a second. That is what makes a pause from
/// a media key or a HomePod's top an actual pause, and what lets a HomePod's
/// volume buttons move the phone's slider.
///
/// Wire format: one ASCII command per line, one reply line each, `ok`,
/// `ok <detail>` or `error <reason>`. Every call here opens its own
/// connection, which is cheap for the handful of commands a session sends
/// and leaves nothing to reconnect.
struct SpotifyControl: Sendable {
    /// Spotify's volume scale, which is also what the `VOLUME` event carries.
    static let maxVolume = 65_535

    enum Failure: Error, LocalizedError, Equatable {
        /// The socket is not there or nobody answers. librespot is down, or
        /// running without the patch.
        case unavailable(String)
        /// librespot answered `error`.
        case refused(String)
        case noReply

        var errorDescription: String? {
            switch self {
            case .unavailable(let why): return "Spotify control socket: \(why)"
            case .refused(let why): return "Spotify refused: \(why)"
            case .noReply: return "Spotify did not answer"
            }
        }
    }

    let socket: URL
    private static let log = Logger(subsystem: "bar.esko.Tutti", category: "spotify")

    func play() async throws { _ = try await send("play") }
    func pause() async throws { _ = try await send("pause") }
    func next() async throws { _ = try await send("next") }
    func previous() async throws { _ = try await send("prev") }
    func seek(toMs position: Int) async throws { _ = try await send("seek \(max(position, 0))") }

    /// Spotify's own level, 0...65535, whether or not a session is up.
    func volume() async throws -> Int {
        let detail = try await send("status")
        let words = detail.split(separator: " ")
        guard words.count == 2, words[0] == "volume", let level = Int(words[1]) else {
            throw Failure.refused("unexpected status '\(detail)'")
        }
        return level
    }

    /// Sets Spotify's level, 0...65535. Ignored by librespot while no phone
    /// is connected, which is fine: there is nobody to show it to.
    func setVolume(_ level: Int) async throws {
        _ = try await send("volume \(min(max(level, 0), Self.maxVolume))")
    }

    /// The engine's 0...100 master and Spotify's 0...65535 level, mapped so
    /// that a round trip is the identity: the metadata bridge lands the
    /// engine on `round(level / 655.35)`, and this is its inverse.
    static func spotifyLevel(percent: Int) -> Int {
        Int((Double(min(max(percent, 0), 100)) * Double(maxVolume) / 100).rounded())
    }

    static func percent(spotifyLevel level: Int) -> Int {
        Int((Double(min(max(level, 0), maxVolume)) * 100 / Double(maxVolume)).rounded())
    }

    /// One command, one reply. Returns whatever followed `ok`.
    private func send(_ command: String) async throws -> String {
        let path = socket.path
        let reply = try await Task.detached(priority: .userInitiated) {
            try Self.exchange(command, at: path)
        }.value
        // Info, not debug: a handful of lines per session, and the only
        // record of what Spotify was told when the phone disagrees.
        Self.log.info("\(command, privacy: .public) -> \(reply, privacy: .public)")

        if reply == "ok" { return "" }
        if reply.hasPrefix("ok ") { return String(reply.dropFirst(3)) }
        if reply.hasPrefix("error ") { throw Failure.refused(String(reply.dropFirst(6))) }
        throw Failure.refused("unexpected reply '\(reply)'")
    }

    /// Blocking: connects, writes one line, reads one line. Runs off the main
    /// actor. A reply is expected within a couple of seconds; librespot
    /// answers from its main task, which is never busy for long.
    private static func exchange(_ command: String, at path: String) throws -> String {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.unavailable(errnoText()) }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let fitted = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { field in
                field.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                    strlcpy(buffer, source, capacity) < capacity
                }
            }
        }
        guard fitted else { throw Failure.unavailable("path too long: \(path)") }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize)

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Failure.unavailable(errnoText()) }

        let line = Array((command + "\n").utf8)
        var sent = 0
        while sent < line.count {
            let wrote = line.withUnsafeBytes { bytes in
                write(descriptor, bytes.baseAddress! + sent, bytes.count - sent)
            }
            guard wrote > 0 else { throw Failure.unavailable(errnoText()) }
            sent += wrote
        }

        var reply: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 256)
        while !reply.contains(UInt8(ascii: "\n")) {
            let got = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress!, $0.count) }
            if got < 0 { throw Failure.unavailable(errnoText()) }
            if got == 0 { throw Failure.noReply }
            reply += chunk[0..<got]
            if reply.count > 4096 { throw Failure.refused("reply too long") }
        }
        let end = reply.firstIndex(of: UInt8(ascii: "\n"))!
        return String(decoding: reply[0..<end], as: UTF8.self)
    }

    private static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}
