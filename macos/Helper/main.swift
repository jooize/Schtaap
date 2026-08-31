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
// It ends in exec(), not a child process, so launchd supervises the engine
// itself and nothing extra shows up in the process tree.

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

/// Sends this process's stdout and stderr to `file`, so they survive the
/// exec below and end up somewhere a user can be pointed at.
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

/// Replaces this process with `executable`. Only returns on failure.
private func exec(_ executable: URL, _ arguments: [String]) -> Never {
    let argv: [String] = [executable.path] + arguments
    // execv wants a NULL-terminated array of mutable C strings that outlive
    // the call. strdup'd copies are never freed, which is correct: either
    // execv succeeds and the whole address space is replaced, or the process
    // is about to exit.
    var pointers: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    pointers.append(nil)
    execv(executable.path, &pointers)

    FileHandle.standardError.write(Data(
        "exec \(executable.path) failed: \(String(cString: strerror(errno)))\n".utf8
    ))
    exit(EXIT_FAILURE)
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
        exec(layout.engineBin.appending(path: "owntone"), [
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
        exec(layout.engineBin.appending(path: "librespot"), [
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
