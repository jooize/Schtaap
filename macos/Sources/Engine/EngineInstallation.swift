import CryptoKit
import Foundation
import Security

/// The engine's on-disk state, and the code that writes it.
///
/// Everything lives under one directory named for the app rather than for
/// owntone, because from the user's side there is no owntone: there is a
/// menu bar app that plays to speakers. `macos/Helper/main.swift` computes
/// these same paths from the bundle it is running inside, so neither side
/// may hardcode the app name or they will drift apart.
struct EngineInstallation {
    let root: URL

    init(root: URL = Branding.supportDirectory) {
        self.root = root
    }

    /// Parsed by owntone at launch, named by the helper's `-c`.
    var configFile: URL { root.appending(path: "owntone.conf") }

    /// Read by the helper to build librespot's argv. Kept separate from
    /// owntone.conf so editing the Spotify name never risks a malformed
    /// engine config.
    var settingsFile: URL { root.appending(path: "engine.json") }

    /// owntone's media library. Its only member is the named pipe librespot
    /// writes into; `pipe_autostart` is what turns bytes arriving there into
    /// playback.
    var libraryDirectory: URL { root.appending(path: "Library", directoryHint: .isDirectory) }

    var cacheDirectory: URL { root.appending(path: "Cache", directoryHint: .isDirectory) }
    var logDirectory: URL { root.appending(path: "Logs", directoryHint: .isDirectory) }

    var databaseFile: URL { root.appending(path: "songs3.db") }
    var audioPipe: URL { libraryDirectory.appending(path: "spotify.fifo") }

    /// The companion pipe OwnTone watches for the current track's title,
    /// artist, album and cover art, in the format shairport-sync writes. The
    /// name is not ours to choose: OwnTone looks for the audio pipe's path
    /// with `.metadata` appended and nowhere else.
    ///
    /// It sits inside the scanned library directory, which is safe because
    /// `.metadata` is in OwnTone's default `filetypes_ignore`. A config that
    /// overrode that key without it would index this as a bogus PCM16 track.
    var metadataPipe: URL { audioPipe.appendingPathExtension("metadata") }

    /// owntone's own log. The helper separately captures the process's
    /// stdout and stderr to Logs/owntone.log, which is where a failure too
    /// early to have read this config shows up.
    var serverLogFile: URL { logDirectory.appending(path: "owntone-server.log") }

    // MARK: - Writing

    /// Creates the directory tree, the named pipe and both config files.
    ///
    /// Returns true when something the engine reads at launch actually
    /// changed, which is the caller's signal to restart the agents. Writing
    /// identical bytes returns false, so an app launch that changes nothing
    /// does not interrupt playback.
    @discardableResult
    func prepare(connectName: String, showsInSpotify: Bool) throws -> Bool {
        let manager = FileManager.default
        for directory in [root, libraryDirectory, cacheDirectory, logDirectory] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try createFIFOIfNeeded(at: audioPipe)
        try createFIFOIfNeeded(at: metadataPipe)

        let configChanged = try write(owntoneConfig(), to: configFile)
        let settingsChanged = try write(
            settingsJSON(connectName: connectName, showsInSpotify: showsInSpotify),
            to: settingsFile
        )
        return configChanged || settingsChanged
    }

    /// A named pipe, not a regular file. owntone identifies the audio pipe by
    /// its file type, so an ordinary empty file there would be scanned as a
    /// broken track instead.
    private func createFIFOIfNeeded(at url: URL) throws {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            if status.st_mode & S_IFMT == S_IFIFO { return }
            // Something else is squatting on the path. Move it aside rather
            // than delete it: if this is the user's file, losing it silently
            // would be worse than an extra file on disk.
            let aside = url.appendingPathExtension("displaced")
            try? FileManager.default.removeItem(at: aside)
            try FileManager.default.moveItem(at: url, to: aside)
        }

        guard mkfifo(url.path, 0o600) == 0 else {
            throw EngineInstallationError.pipeCreationFailed(
                url.path, String(cString: strerror(errno))
            )
        }
    }

    /// Writes only when the bytes differ, and via a temporary file so a
    /// crash mid-write cannot leave the engine a truncated config.
    private func write(_ contents: String, to url: URL) throws -> Bool {
        let data = Data(contents.utf8)
        if let existing = try? Data(contentsOf: url), existing == data { return false }

        let temporary = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).new")
        try data.write(to: temporary, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        return true
    }

    // MARK: - Contents

    private func owntoneConfig() -> String {
        // ipv6 is on because this Mac's name resolves to IPv6 addresses on
        // the LAN before its IPv4 one, and a HomePod reporting its volume
        // buttons over DACP connects to whichever it picks: with the engine
        // bound to IPv4 only, some presses vanished into a refused connect
        // (2026-09-07). trusted_networks maps "localhost" to ::1 as well.
        //
        // trusted_networks is localhost only, deliberately. owntone's HTTP
        // interface is an unauthenticated control API for every speaker in
        // the house; the spike widened it to the LAN to reach the web UI
        // from a phone, and nothing here needs that. This app talks to
        // 127.0.0.1 and the phone talks to librespot.
        """
        # Generated by \(Branding.appName). Edits are overwritten on launch.

        general {
        \tuid = "\(escaped(NSUserName()))"
        \tdb_path = "\(escaped(databaseFile.path))"
        \tlogfile = "\(escaped(serverLogFile.path))"
        \tloglevel = \(Preferences.engineLogLevel)
        \tcache_dir = "\(escaped(cacheDirectory.path))"
        \ttrusted_networks = { "localhost" }
        \tipv6 = yes
        }

        library {
        \tname = "\(escaped(Branding.appName))"
        \tdirectories = { "\(escaped(libraryDirectory.path))" }
        \tpipe_autostart = true
        }

        """
    }

    private func settingsJSON(connectName: String, showsInSpotify: Bool) -> String {
        // Hand-rolled rather than JSONEncoder so the file stays readable
        // and stably ordered: it is diffed against what is already on disk
        // to decide whether the agents need restarting.
        //
        // The engine fingerprint is in here for that diff and nothing else.
        // The agents run the helper out of the bundle, and launchd keeps a
        // running job on the old binary until something stops it -- so an
        // update that changed only the helper would otherwise never take
        // effect. It used to be the app's build number, which restarts the
        // engine, and drops the Spotify session, on every UI-only rebuild.
        """
        {
          "engine": \(quotedJSON(engineFingerprint())),
          "connectName": \(quotedJSON(connectName)),
          "deviceType": \(quotedJSON(SpotifyDeviceType.advertised.rawValue)),
          "showsInSpotify": \(showsInSpotify),
          "audioPipe": \(quotedJSON(audioPipe.path)),
          "bitrate": 320
        }

        """
    }

    // MARK: - Fingerprint

    /// Identifies the code the agents would run if restarted now: the helper
    /// binary and the engine payload it spawns. Same string, nothing to
    /// restart for.
    ///
    /// The helper is identified by its code directory hash rather than a
    /// hash of the file. The cdhash covers the executable's pages and its
    /// embedded Info.plist but not the CMS signature blob, which carries a
    /// signing time and so differs on every re-sign of identical code. For
    /// this to hold, the helper's Info.plist must not carry the build
    /// number; see the EngineHelper target in project.yml.
    ///
    /// The payload is identified by the Nix store paths build-engine wrote
    /// into manifest.json: a store path hashes the whole build closure, so
    /// a rebuilt ffmpeg changes it even when the owntone version does not.
    /// A manifest from before that field existed falls back to the versions
    /// it does have, which under-restarts rather than over-restarts.
    func engineFingerprint() -> String {
        let contents = Bundle.main.bundleURL.appending(path: "Contents")
        let helper = contents.appending(path: "MacOS/EngineHelper")
        let manifest = contents.appending(path: "Resources/manifest.json")

        let helperID = Self.codeDirectoryHash(of: helper)
            ?? Self.contentHash(of: helper)
            ?? "no-helper"
        let payloadID = Self.payloadIdentity(from: manifest) ?? "no-payload"
        return "\(helperID)+\(payloadID)"
    }

    private static func codeDirectoryHash(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code
        else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let unique = dictionary[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    private static func contentHash(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func payloadIdentity(from manifest: URL) -> String? {
        guard
            let data = try? Data(contentsOf: manifest),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let owntone = object["owntonePath"] as? String,
           let librespot = object["librespotPath"] as? String {
            return [owntone, librespot]
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                .joined(separator: "+")
        }
        let versions = object.compactMap { key, value -> String? in
            guard let value = value as? String else { return nil }
            return "\(key)=\(value)"
        }
        return versions.isEmpty ? nil : versions.sorted().joined(separator: "+")
    }

    /// libconfuse strings are double-quoted with backslash escapes.
    private func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func quotedJSON(_ value: String) -> String {
        // Without .withoutEscapingSlashes every path in the file comes out as
        // \/Users\/... -- valid JSON, unreadable to a human opening it.
        let data = try? JSONSerialization.data(
            withJSONObject: [value], options: [.withoutEscapingSlashes]
        )
        guard
            let data,
            let array = String(data: data, encoding: .utf8),
            array.count > 2
        else {
            return "\"\""
        }
        return String(array.dropFirst().dropLast())
    }
}

enum EngineInstallationError: LocalizedError {
    case pipeCreationFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .pipeCreationFailed(let path, let reason):
            return "Could not create the audio pipe at \(path): \(reason)"
        }
    }
}
