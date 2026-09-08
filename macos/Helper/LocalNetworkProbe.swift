import Foundation

/// Whether this process may use the local network, asked of the system the
/// only way it answers: by trying.
///
/// macOS keeps multicast and local unicast behind the Local Network
/// permission, keyed to the responsible process, which for the engine is
/// this helper. There is no API that reads the setting, and no notice when
/// the user changes it. But a denied send fails at once with EHOSTUNREACH
/// and a permitted one goes out, so one tiny datagram to a multicast group
/// nobody listens on is a reading.
///
/// A reading is per process, and it is not symmetric: a grant reaches a
/// running process (seen 2026-09-08, denied then granted three seconds
/// later in the same helper), a revocation does not, it is only seen by
/// processes started after it (the same day, the switch turned off and
/// the running helper kept reading granted). So every reading is taken by
/// a child process, this same executable in `probe` mode, which is new
/// each time and inherits this helper's identity for the permission.
///
/// The reading matters twice. librespot advertises itself over mDNS on a
/// socket of its own, and a grant given after that socket was opened does
/// not reach it: the device stays invisible in Spotify until librespot is
/// started again. So a change from denied to granted ends librespot, and
/// launchd starts it again with the grant in place. And the app shows the
/// state, so a receiver that vanished from Spotify says why. The app can
/// also ask for a reading now, by touching the request file, which it does
/// when the popover opens.
final class LocalNetworkProbe: @unchecked Sendable {
    enum Verdict: String {
        case granted, denied
        /// No usable interface, or an error that is not the permission:
        /// Wi-Fi off, for one. Says nothing about the grant.
        case unknown

        /// How the `probe` mode reports to its parent.
        var exitCode: Int32 {
            switch self {
            case .granted: 0
            case .denied: 1
            case .unknown: 2
            }
        }

        init(exitCode: Int32) {
            switch exitCode {
            case 0: self = .granted
            case 1: self = .denied
            default: self = .unknown
            }
        }
    }

    /// The file the app touches to ask for a reading now.
    static let requestFileName = "local-network-probe-request"

    /// This executable, run again in `probe` mode for each reading.
    private let executable: URL
    /// Where the reading goes for the app: the session file it watches.
    private let sessionFile: URL
    private let requestFile: URL
    /// Called on a change from denied to granted, off the main thread.
    private let onGranted: () -> Void

    /// While denied nothing leaves the machine, so asking often is free and
    /// the grant is noticed within seconds of the user giving it. While
    /// granted each reading is one datagram on the LAN and one short-lived
    /// process, so less often; the popover opening asks in between.
    private static let deniedInterval: TimeInterval = 3
    private static let grantedInterval: TimeInterval = 20
    /// How often the loop looks for a request while it waits.
    private static let requestPoll: TimeInterval = 1

    /// RFC 4727's experimental link-local group, and a port nothing uses.
    /// Sending to it needs the permission like any multicast does, and
    /// unlike a real mDNS query it makes nobody answer.
    private static let group = "224.0.0.254"
    private static let port: UInt16 = 27_754
    private static let payload = Data("local-network-probe\n".utf8)

    init(executable: URL, sessionFile: URL, requestFile: URL, onGranted: @escaping () -> Void) {
        self.executable = executable
        self.sessionFile = sessionFile
        self.requestFile = requestFile
        self.onGranted = onGranted
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "local-network-probe"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func run() {
        var last: Verdict?
        var handledRequest = requestStamp()
        while true {
            let verdict = readInChild()
            if verdict != last {
                log("local network: \(verdict.rawValue)")
                SpotifySessionFile.update(at: sessionFile) { $0.localNetwork = verdict.rawValue }
                if last == .denied, verdict == .granted {
                    onGranted()
                }
                last = verdict
            }

            // Wait out the interval, or until the app asks.
            let interval = verdict == .granted ? Self.grantedInterval : Self.deniedInterval
            let until = Date().addingTimeInterval(interval)
            while Date() < until {
                Thread.sleep(forTimeInterval: Self.requestPoll)
                let stamp = requestStamp()
                if stamp != handledRequest {
                    handledRequest = stamp
                    break
                }
            }
        }
    }

    private func requestStamp() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: requestFile.path)[.modificationDate] as? Date
    }

    /// One reading by a fresh process, which is what makes a revocation
    /// visible at all. A child that cannot be run reads as unknown.
    private func readInChild() -> Verdict {
        let child = Process()
        child.executableURL = executable
        child.arguments = ["probe"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.standardError
        do {
            try child.run()
        } catch {
            log("could not run the probe: \(error.localizedDescription)")
            return .unknown
        }
        child.waitUntilExit()
        guard child.terminationReason == .exit else { return .unknown }
        return Verdict(exitCode: child.terminationStatus)
    }

    /// One datagram, one answer. What the `probe` mode does, once.
    static func probe() -> Verdict {
        guard let interface = multicastInterface() else { return .unknown }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return .unknown }
        defer { close(fd) }

        var outgoing = interface
        guard setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &outgoing, socklen_t(MemoryLayout<in_addr>.size)) == 0 else {
            return .unknown
        }
        var ttl: UInt8 = 1
        _ = setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        destination.sin_addr.s_addr = inet_addr(group)

        let sent = payload.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) { address in
                address.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    sendto(fd, bytes.baseAddress, bytes.count, 0, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent >= 0 { return .granted }
        // What macOS answers a process it has not allowed. Anything else is
        // the network itself.
        return errno == EHOSTUNREACH ? .denied : .unknown
    }

    /// The address of the interface a multicast should leave by: the first
    /// one that is up, does multicast, and is not the loopback, with an
    /// `en` name (Wi-Fi, Ethernet) preferred over tunnels and the like.
    private static func multicastInterface() -> in_addr? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        var fallback: in_addr?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard
                flags & IFF_UP != 0, flags & IFF_MULTICAST != 0, flags & IFF_LOOPBACK == 0,
                let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            if String(cString: entry.pointee.ifa_name).hasPrefix("en") {
                return ipv4
            }
            if fallback == nil { fallback = ipv4 }
        }
        return fallback
    }

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(stamp)] helper: \(message)\n".utf8))
    }
}
