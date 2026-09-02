import AppKit
import MediaPlayer

/// Publishes what the speakers are playing to the system's Now Playing slot:
/// Control Center, the menu bar's Now Playing item, and the keyboard's media
/// keys' idea of what is on.
///
/// Display only, for now. The remote commands are left disabled on purpose:
/// librespot streams into a fifo the engine drains, so pausing the engine
/// stalls librespot's writes and resumes into stale audio, and there is no
/// track to skip to inside a pipe. Until pause semantics are settled (the
/// candidate is pause == deselect every output, so the engine keeps draining
/// but sends nowhere) a media key that did any of that would be lying about
/// what it did. The slot is still worth holding for what it shows.
///
/// The slot is single and last-writer-wins across every app on the Mac, which
/// is why holding it is a preference and not a given.
@MainActor
final class NowPlayingCenter {
    private let center = MPNowPlayingInfoCenter.default()

    /// The artwork last fetched, and the engine path it came from, so a
    /// progress update does not refetch the same cover.
    private var artwork: MPMediaItemArtwork?
    private var artworkPath: String?
    private var artworkTask: Task<Void, Never>?

    private var isHolding = false

    init() {
        let commands = MPRemoteCommandCenter.shared()
        for command in [
            commands.playCommand, commands.pauseCommand, commands.stopCommand,
            commands.togglePlayPauseCommand, commands.nextTrackCommand,
            commands.previousTrackCommand, commands.changePlaybackPositionCommand,
            commands.seekForwardCommand, commands.seekBackwardCommand,
        ] {
            command.isEnabled = false
        }
    }

    /// Reflects the engine's current track and transport state. `artworkURL`
    /// is where the engine serves the cover, or nil when it has none.
    func publish(track: NowPlaying?, player: PlayerStatus?, artworkURL: URL?) {
        guard let track, track.hasMetadata, let player, player.state != .stop else {
            clear()
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title ?? "",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(player.itemProgressMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
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
        center.playbackState = player.isPlaying ? .playing : .paused
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
        isHolding = false
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
            let piece = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            guard let self, self.artworkPath == track.artworkUrl else { return }
            self.artwork = piece
            if self.isHolding, var info = self.center.nowPlayingInfo {
                info[MPMediaItemPropertyArtwork] = piece
                self.center.nowPlayingInfo = info
            }
        }
    }
}
