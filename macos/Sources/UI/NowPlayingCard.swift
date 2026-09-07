import SwiftUI

/// What is currently coming out of the speakers.
///
/// Read-only on purpose. In this architecture librespot streams into a fifo
/// that the engine drains, so pausing the engine does not pause Spotify -- it
/// just stalls librespot's writes and resumes into stale audio. Until the
/// pause-semantics spike settles that (candidate: pause == deselect every
/// output, so the engine keeps draining but sends nowhere), there is no
/// transport control here. You drive playback from the phone.
struct NowPlayingCard: View {
    let track: NowPlaying
    let artworkURL: URL?

    var body: some View {
        HStack(spacing: 10) {
            artwork
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title ?? "Unknown track")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String? {
        let parts = [track.artist, track.album].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    private var artwork: some View {
        ArtworkWell {
            if let artworkURL {
                AsyncImage(url: artworkURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ArtworkPlaceholder()
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                ArtworkPlaceholder()
            }
        }
    }
}

/// The same slot as the now-playing card, shown when nothing is. It keeps
/// the header the same height either way, and spends the line on the one
/// thing a person opening the popover to silence needs: what to tap on the
/// phone. The name is read live, so the sentence can never go stale.
struct IdleCard: View {
    let connectName: String
    let showsInSpotify: Bool

    var body: some View {
        HStack(spacing: 10) {
            ArtworkWell { ArtworkPlaceholder() }
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing playing")
                    .font(.system(size: 13, weight: .medium))
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var hint: String {
        guard showsInSpotify else {
            return "Not appearing in Spotify. Switch it on above to play here."
        }
        return "In Spotify, choose \u{201C}\(connectName)\u{201D} from the device list."
    }
}

/// The slot while the engine is already streaming the pipe but Spotify has
/// not yet said what is in it. Without this the header shows the pipe's file
/// name as a title, which is the plumbing showing through.
struct ConnectingCard: View {
    var body: some View {
        HStack(spacing: 10) {
            ArtworkWell { ArtworkPlaceholder() }
            VStack(alignment: .leading, spacing: 2) {
                Text("Connecting to Spotify\u{2026}")
                    .font(.system(size: 13, weight: .medium))
                Text("Sound and track details are on their way.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The 40-point rounded square both cards start with.
struct ArtworkWell<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.quaternary)
            .frame(width: 40, height: 40)
            .overlay { content() }
    }
}

struct ArtworkPlaceholder: View {
    var body: some View {
        Image(systemName: "music.note")
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
    }
}

#Preview("Playing") {
    NowPlayingCard(track: Fixtures.nowPlaying, artworkURL: nil)
        .frame(width: Metrics.popoverWidth)
        .padding()
}

#Preview("Idle") {
    IdleCard(connectName: "HomePods", showsInSpotify: true)
        .frame(width: Metrics.popoverWidth)
        .padding()
}

#Preview("Idle, hidden from Spotify") {
    IdleCard(connectName: "HomePods", showsInSpotify: false)
        .frame(width: Metrics.popoverWidth)
        .padding()
}
