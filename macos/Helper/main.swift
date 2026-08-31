import Foundation
import MachO

// The program launchd actually runs for both engine agents.
//
// A LaunchAgent plist is a static file, but every path it would need is
// known only at runtime: the app can sit anywhere, and the engine's config,
// database and named pipe live under the user's Application Support. So the
// plist names this executable and one argument, and everything else is
// resolved here, from the bundle this binary is standing in.
//
// It spawns the engine and waits on it rather than exec'ing into it, which
// costs one extra process in the tree and buys the app its own name.
//
// macOS attributes local network access to the responsible process, not to
// whichever binary opened the socket. exec() replaced this process's image
// with librespot's, leaving no responsible ancestor, so the permission
// prompt read "Allow librespot to find devices on local networks?" -- a name
// the user has never seen and no reason to trust. Staying alive as the
// parent makes this helper the responsible process, and its embedded
// Info.plist carries the app's name.
//
// Waiting also means launchd's KeepAlive still works: this process exits
// with the engine's own status, so a crashed engine looks like a crashed
// job and gets restarted.

/// What the app writes for the helper to read. Regenerated whenever a
/// setting changes; the agent is then restarted to pick it up.
private struct EngineSettings: Decodable {
    var connectName: String
    var audioPipe: String
    var bitrate: Int
}

private enum HelperError: Error, CustomStringConvertible {
    case usage
    case noExecutablePath
    case notInBundle(String)
    case unreadableBundleName(String)
    case unreadableSettings(String, Error)

    var description: String {
        switch self {
        case .usage:
            return "usage: \(ProcessInfo.processInfo.processName) owntone|librespot"
        case .noExecutablePath:
            return "could not determine own executable path"
        case .notInBundle(let path):
            return "not running from inside an app bundle: \(path)"
        case .unreadableBundleName(let path):
            return "no CFBundleName in \(path)"
        case .unreadableSettings(let path, let error):
            return "could not read \(path): \(error.localizedDescription)"
        }
    }
}

/// This binary's own path, which `CommandLine.arguments[0]` does not reliably
/// give: launchd passes whatever the plist's first ProgramArguments entry says.
private func executablePath() throws -> URL {
    var size = UInt32(PATH_MAX)
    var buffer = [CChar](repeating: 0, count: Int(size) + 1)
    guard _NSGetExecutablePath(&buffer, &size) == 0 else {
        throw HelperError.noExecutablePath
    }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).resolvingSymlinksInPath()
}

/// Everything the helper needs to locate, derived from where it is installed.
private struct Layout {
    /// Contents/ inside the app bundle.
    let contents: URL
    /// The relocated engine executables, with their dylib closure beside
    /// them in ../lib -- which is where their install names point.
    let engineBin: URL
    /// OwnTone's web root, which is data rather than code and so lives in
    /// Resources. Keeping it out of Contents/Helpers is not tidiness:
    /// codesign walks that directory for nested code and fails on anything
    /// there it cannot sign.
    let webRoot: URL
    /// ~/Library/Application Support/<app name>, named for the app rather
    /// than for owntone, and matching what Branding.swift computes.
    let support: URL

    init() throws {
        // .../Tutti.app/Contents/MacOS/EngineHelper
        let executable = try executablePath()
        let contents = executable
            .deletingLastPathComponent()   // MacOS
            .deletingLastPathComponent()   // Contents
        guard contents.lastPathComponent == "Contents" else {
            throw HelperError.notInBundle(executable.path)
        }
        self.contents = contents
        self.engineBin = contents.appending(path: "Helpers/bin", directoryHint: .isDirectory)
        self.webRoot = contents.appending(path: "Resources/htdocs", directoryHint: .isDirectory)

        let infoPath = contents.appending(path: "Info.plist")
        guard
            let info = NSDictionary(contentsOf: infoPath),
            let name = info["CFBundleName"] as? String,
            !name.isEmpty
        else {
            throw HelperError.unreadableBundleName(infoPath.path)
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.support = base.appending(path: name, directoryHint: .isDirectory)
    }

    var settingsFile: URL { support.appending(path: "engine.json") }
    var owntoneConfig: URL { support.appending(path: "owntone.conf") }

    func logFile(_ name: String) -> URL {
        support.appending(path: "Logs/\(name).log")
    }

    func settings() throws -> EngineSettings {
        let url = settingsFile
        do {
            return try JSONDecoder().decode(EngineSettings.self, from: Data(contentsOf: url))
        } catch {
            throw HelperError.unreadableSettings(url.path, error)
        }
    }
}

/// Sends this process's stdout and stderr to `file`, so the engine inherits
/// them and its output ends up somewhere a user can be pointed at.
///
/// The plist cannot do this with StandardErrorPath: that key takes an
/// absolute path, and the destination is only known once the app bundle has
/// been located. A failure here is deliberately not fatal -- losing the log
/// is not a reason to refuse to play music -- so it is reported on whatever
/// stderr still exists and the launch continues.
private func redirectOutput(to file: URL) {
    do {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
    } catch {
        FileHandle.standardError.write(Data("could not create log directory: \(error)\n".utf8))
        return
    }

    let descriptor = open(file.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard descriptor >= 0 else {
        FileHandle.standardError.write(Data(
            "could not open \(file.path): \(String(cString: strerror(errno)))\n".utf8
        ))
        return
    }
    dup2(descriptor, STDOUT_FILENO)
    dup2(descriptor, STDERR_FILENO)
    close(descriptor)
}

/// The spawned engine, for the signal handlers below. A global because a C
/// signal handler takes no context.
private nonisolated(unsafe) var enginePID: pid_t = 0

/// Passes a termination signal on to the engine so it can shut down, rather
/// than leaving it orphaned when launchd stops this job.
private func forwardToEngine(_ signal: Int32) {
    if enginePID > 0 { kill(enginePID, signal) }
}

/// Starts `executable`, waits for it, and exits with its fate.
private func supervise(_ executable: URL, _ arguments: [String]) -> Never {
    // posix_spawn wants a NULL-terminated array of mutable C strings. The
    // strdup'd copies are never freed, which is correct: this process is
    // either about to spend its life in waitpid or about to exit.
    var argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) }
    argv.append(nil)

    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, executable.path, nil, nil, argv, environ)
    guard spawned == 0 else {
        FileHandle.standardError.write(Data(
            "could not start \(executable.path): \(String(cString: strerror(spawned)))\n".utf8
        ))
        exit(EXIT_FAILURE)
    }
    enginePID = pid

    signal(SIGTERM, forwardToEngine)
    signal(SIGINT, forwardToEngine)

    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 {
        // waitpid is interrupted every time a signal is forwarded; only a
        // real error ends the wait.
        guard errno == EINTR else {
            FileHandle.standardError.write(Data(
                "lost track of the engine: \(String(cString: strerror(errno)))\n".utf8
            ))
            exit(EXIT_FAILURE)
        }
    }

    // Report the engine's outcome as this process's own, so launchd's
    // KeepAlive and its throttling see what actually happened. Swift does
    // not surface the wait macros, so the low seven bits are the signal that
    // killed it and the next eight are the exit status.
    let terminatingSignal = status & 0x7F
    exit(terminatingSignal == 0 ? (status >> 8) & 0xFF : EXIT_FAILURE)
}

private func run() throws -> Never {
    let arguments = CommandLine.arguments.dropFirst()
    guard let which = arguments.first, arguments.count == 1 else {
        throw HelperError.usage
    }

    let layout = try Layout()

    switch which {
    case "owntone":
        // OwnTone also writes its own logfile, named in owntone.conf. This
        // one catches what it says before the config is parsed, which is
        // where startup failures appear.
        redirectOutput(to: layout.logFile("owntone"))
        // -s and -w override the two paths compiled into owntone at
        // /usr/local. Without them it dies on a missing SQLite extension and
        // an unstat-able web root.
        supervise(layout.engineBin.appending(path: "owntone"), [
            "-f",
            "-c", layout.owntoneConfig.path,
            "-s", layout.engineBin.appending(path: "owntone-sqlext.so").path,
            "-w", layout.webRoot.path,
        ])

    case "librespot":
        let settings = try layout.settings()
        // librespot has no logfile option: stderr is the only channel.
        redirectOutput(to: layout.logFile("librespot"))
        // The pipe backend writes raw PCM into the named pipe OwnTone reads
        // as a library item. No audio device is opened here.
        supervise(layout.engineBin.appending(path: "librespot"), [
            "--name", settings.connectName,
            "--backend", "pipe",
            "--device", settings.audioPipe,
            "--bitrate", String(settings.bitrate),
            "--disable-audio-cache",
        ])

    default:
        throw HelperError.usage
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(EXIT_FAILURE)
}
