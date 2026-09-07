import AppKit
import MediaPlayer

/// Publishes what the speakers are playing to the system's Now Playing slot:
/// Control Center, the menu bar's Now Playing item, and the keyboard's media
/// keys' idea of what is on.
///
/// Play and pause are the only commands, and they pause and resume Spotify
/// itself through librespot's control socket (`SpotifyControl`), so the
/// phone shows the same state. Pausing the engine instead would stall
/// librespot's writes and resume into stale audio, which is why the store
/// never does that. Skipping is not offered yet; the socket could do it.
///
/// macOS only lists an app in Now Playing once it handles at least one
/// remote command. Display alone, as this first shipped, never appeared.
///
/// The slot is single and last-writer-wins across every app on the Mac, which
/// is why holding it is a preference and not a given.
@MainActor
final class NowPlayingCenter {
    private let center = MPNowPlayingInfoCenter.default()

    /// What a play or pause from the system does. Set by the store; a command
    /// arriving before then is accepted and does nothing.
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?

    /// The transport state last published, which is what the toggle command
    /// decides on.
    private var isPublishedAsPlaying = false

    /// The artwork last fetched, and the engine path it came from, so a
    /// progress update does not refetch the same cover.
    private var artwork: MPMediaItemArtwork?
    private var artworkPath: String?
    private var artworkTask: Task<Void, Never>?

    private var isHolding = false

    init() {
        let commands = MPRemoteCommandCenter.shared()
        for command in [
            commands.stopCommand, commands.nextTrackCommand,
            commands.previousTrackCommand, commands.changePlaybackPositionCommand,
            commands.seekForwardCommand, commands.seekBackwardCommand,
        ] {
            command.isEnabled = false
        }

        // The handlers are not guaranteed the main thread, and everything
        // they touch is main-actor state, so each hops there and answers
        // success for having taken the request.
        commands.playCommand.isEnabled = true
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPlay?() }
            return .success
        }
        commands.pauseCommand.isEnabled = true
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPause?() }
            return .success
        }
        commands.togglePlayPauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPublishedAsPlaying ? self.onPause?() : self.onPlay?()
            }
            return .success
        }
    }

    /// Reflects the engine's current track and transport state. `artworkURL`
    /// is where the engine serves the cover, or nil when it has none. A
    /// muted master still counts as playing: the track is advancing, and
    /// the toggle command should pause it, not unmute it.
    func publish(track: NowPlaying?, player: PlayerStatus?, artworkURL: URL?) {
        guard let track, track.hasMetadata, let player, player.state != .stop else {
            clear()
            return
        }

        let isPlaying = player.isPlaying
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title ?? "",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(player.itemProgressMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artist = track.artist, !artist.isEmpty {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let album = track.album, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let length = track.lengthMs, length > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(length) / 1000
        }
        if let artwork, artworkPath == track.artworkUrl {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
        isPublishedAsPlaying = isPlaying
        isHolding = true

        if artworkPath != track.artworkUrl {
            fetchArtwork(at: artworkURL, for: track)
        }
    }

    /// Lets go of the slot. Safe to call when it was never held.
    func clear() {
        artworkTask?.cancel()
        artworkTask = nil
        guard isHolding else { return }
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        isPublishedAsPlaying = false
        isHolding = false
    }

    /// MediaPlayer calls the artwork request handler on its own queue, so the
    /// closure must not be main-actor isolated: formed inside a main-actor
    /// method it would be, and the runtime traps on the first call (seen as
    /// EXC_BREAKPOINT in `-[MPMediaItemArtwork jpegDataWithSize:]`). Built
    /// here, outside the actor, from the bytes rather than an `NSImage`, so
    /// nothing captured needs to be thread-confined.
    nonisolated private static func artworkPiece(from data: Data, size: CGSize) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: size) { _ in NSImage(data: data) ?? NSImage() }
    }

    /// Fetches the cover once per track and folds it into the published info
    /// when it arrives. Artwork is never worth an error: a failed fetch leaves
    /// the text up and the picture blank.
    private func fetchArtwork(at url: URL?, for track: NowPlaying) {
        artworkTask?.cancel()
        artworkPath = track.artworkUrl
        artwork = nil

        guard let url else { return }
        artworkTask = Task { [weak self] in
            guard
                let (data, _) = try? await URLSession.shared.data(from: url),
                !Task.isCancelled,
                let image = NSImage(data: data)
            else { return }
            let piece = Self.artworkPiece(from: data, size: image.size)
            guard let self, self.artworkPath == track.artworkUrl else { return }
            self.artwork = piece
            if self.isHolding, var info = self.center.nowPlayingInfo {
                info[MPMediaItemPropertyArtwork] = piece
                self.center.nowPlayingInfo = info
            }
        }
    }
}
