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
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.quaternary)
            .frame(width: 40, height: 40)
            .overlay {
                if let artworkURL {
                    AsyncImage(url: artworkURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        placeholderGlyph
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    placeholderGlyph
                }
            }
    }

    private var placeholderGlyph: some View {
        Image(systemName: "music.note")
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
    }
}

#Preview {
    NowPlayingCard(track: Fixtures.nowPlaying, artworkURL: nil)
        .frame(width: Metrics.popoverWidth)
        .padding()
}
