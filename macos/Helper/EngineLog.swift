import Foundation

/// The engine's log, owned by this helper rather than by the engine.
///
/// The engine's stdout and stderr are a pipe into this process, and a thread
/// here appends whatever arrives to `Logs/<name>.log`, starting the file
/// anew when it reaches `maxBytes` and keeping `generations` older ones
/// beside it (`<name>.1.log` is the most recent). The engine could write the
/// file itself, and owntone did until 2026-09-10, but a file the engine holds
/// open can only be rotated by asking the engine to reopen it, and librespot
/// cannot be asked. A pipe puts both files under one owner and one rule.
///
/// It also ends a duplicate: owntone in the foreground logs to the console as
/// well as to its logfile, so `owntone.log` (the console, captured here) and
/// `owntone-server.log` (its logfile) were the same 20 MB twice. The config
/// now leaves owntone's logfile empty (our patch makes that mean none) and
/// the console stream is the log.
///
/// This process's own stdout and stderr go through the same pipe, so its
/// lines and the engine's interleave in one file, and so do those of the
/// metadata bridge librespot runs, which inherits librespot's.
final class EngineLog: @unchecked Sendable {
    /// A file is started anew once it holds this much.
    static let maxBytes: UInt64 = 10 * 1024 * 1024
    /// How many earlier files stay beside the current one.
    static let generations = 2

    private let file: URL
    private let maxBytes: UInt64
    private let generations: Int
    private let readEnd: Int32
    /// The file, or -1 between a failed open and the next attempt.
    private var descriptor: Int32 = -1
    private var size: UInt64 = 0
    /// True when the last byte written was not a newline, so a rotation
    /// waits for the line to finish.
    private var midLine = false
    private let drained = DispatchSemaphore(value: 0)

    /// Starts capturing this process's stdout and stderr, and so those of
    /// every child it spawns from now on, into `file`.
    ///
    /// Returns nil, with the reason on the stderr that still exists, when
    /// the file cannot be opened. That is deliberately not fatal: losing the
    /// log is not a reason to refuse to play music, and output then stays
    /// wherever launchd pointed it.
    static func capture(
        _ file: URL, maxBytes: UInt64 = EngineLog.maxBytes, generations: Int = EngineLog.generations
    ) -> EngineLog? {
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else {
            FileHandle.standardError.write(Data(
                "could not create a log pipe: \(String(cString: strerror(errno)))\n".utf8
            ))
            return nil
        }
        let log = EngineLog(file: file, maxBytes: maxBytes, generations: generations, readEnd: ends[0])
        guard log.open(reporting: true) else {
            close(ends[0])
            close(ends[1])
            return nil
        }
        // A file already over the cap, left by a build that never rotated,
        // starts a new one right away.
        if log.size >= maxBytes { log.rotate() }

        dup2(ends[1], STDOUT_FILENO)
        dup2(ends[1], STDERR_FILENO)
        close(ends[1])

        let thread = Thread { log.drain() }
        thread.name = "engine-log"
        thread.qualityOfService = .utility
        thread.start()
        return log
    }

    private init(file: URL, maxBytes: UInt64, generations: Int, readEnd: Int32) {
        self.file = file
        self.maxBytes = maxBytes
        self.generations = generations
        self.readEnd = readEnd
    }

    /// Lets go of this process's end of the pipe and waits, briefly, for
    /// everything written so far to reach the file. Call before exiting: an
    /// exit with bytes still in the pipe loses them.
    ///
    /// The wait is bounded because the reader only sees the end when every
    /// writer has closed, and a grandchild that outlives the engine (a
    /// metadata bridge mid-event) would hold it open a little longer.
    func finish() {
        let null = Darwin.open("/dev/null", O_WRONLY)
        if null >= 0 {
            dup2(null, STDOUT_FILENO)
            dup2(null, STDERR_FILENO)
            close(null)
        }
        _ = drained.wait(timeout: .now() + 2)
    }

    // MARK: - The reader

    private func drain() {
        let capacity = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer {
            buffer.deallocate()
            if descriptor >= 0 { close(descriptor) }
            drained.signal()
        }
        while true {
            let count = read(readEnd, buffer, capacity)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            append(UnsafeRawBufferPointer(start: buffer, count: count))
        }
    }

    private func append(_ bytes: UnsafeRawBufferPointer) {
        if descriptor < 0, !open(reporting: false) { return }
        var offset = 0
        while offset < bytes.count {
            let written = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                // Nowhere to say so: stderr is this pipe. Try afresh with
                // the next chunk.
                close(descriptor)
                descriptor = -1
                return
            }
            offset += written
        }
        size += UInt64(bytes.count)
        midLine = bytes[bytes.count - 1] != UInt8(ascii: "\n")
        if size >= maxBytes, !midLine { rotate() }
    }

    // MARK: - The file

    /// Opens the file for appending and reads its size.
    private func open(reporting: Bool) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch {
            if reporting {
                FileHandle.standardError.write(Data("could not create log directory: \(error)\n".utf8))
            }
            return false
        }
        let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else {
            if reporting {
                FileHandle.standardError.write(Data(
                    "could not open \(file.path): \(String(cString: strerror(errno)))\n".utf8
                ))
            }
            return false
        }
        var info = stat()
        size = fstat(fd, &info) == 0 ? UInt64(max(info.st_size, 0)) : 0
        descriptor = fd
        return true
    }

    /// Moves every generation down one and starts an empty file.
    /// `<name>.log` becomes `<name>.1.log`, the oldest falls off the end.
    private func rotate() {
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        for generation in stride(from: generations, through: 1, by: -1) {
            let from = generation == 1 ? file : Self.generation(generation - 1, of: file)
            let to = Self.generation(generation, of: file)
            // rename replaces the destination, which is how the oldest goes.
            // A missing source (fewer generations yet) is nothing to report.
            rename(from.path, to.path)
        }
        if generations == 0 { unlink(file.path) }
        _ = open(reporting: false)
        midLine = false
    }

    /// `owntone.log` -> `owntone.2.log`. The extension stays last so the
    /// files open in the same application.
    static func generation(_ number: Int, of file: URL) -> URL {
        let stem = file.deletingPathExtension().lastPathComponent
        return file.deletingLastPathComponent()
            .appending(path: "\(stem).\(number).\(file.pathExtension)")
    }
}
