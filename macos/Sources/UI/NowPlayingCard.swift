import SwiftUI

/// What is currently coming out of the speakers, and the controls for it.
///
/// Transport and the scrubber go to Spotify itself over librespot's control
/// socket (`EngineStore.pausePlayback` and friends), so the phone shows the
/// same state. Progress is ticked locally from the engine's last reading,
/// because the engine pushes state changes and not seconds.
struct NowPlayingCard: View {
    let track: NowPlaying
    let artworkURL: URL?
    var lengthMs: Int?
    var isPlaying = false
    /// The engine's position at a given moment, for the timeline to tick.
    var progressMs: (Date) -> Int = { _ in 0 }
    var onPlayPause: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onNext: () -> Void = {}
    var onSeek: (Int) -> Void = { _ in }

    /// Set while the knob is held: the slider then shows the hand, not the
    /// clock, and the seek goes out on release.
    @State private var scrubMs: Double?

    /// The right-hand time is what is left by default; a click on it shows
    /// the track's length instead, and the choice is kept.
    @AppStorage("ShowsTrackLength") private var showsLength = false

    var body: some View {
        VStack(spacing: 6) {
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

            if let lengthMs, lengthMs > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    scrubber(lengthMs: lengthMs, now: context.date)
                }
            }

            transport
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

    /// Elapsed on the left, what is left on the right, the knob between. A
    /// native `Slider` for the same reason the volume ones are: keyboard,
    /// VoiceOver and the system's knob come with it.
    private func scrubber(lengthMs: Int, now: Date) -> some View {
        let shown = scrubMs ?? Double(min(max(progressMs(now), 0), lengthMs))
        let position = Binding<Double>(
            get: { shown },
            set: { scrubMs = $0 }
        )
        return HStack(spacing: 8) {
            Text(Self.clock(ms: Int(shown)))
                .frame(width: 34, alignment: .trailing)
            Slider(value: position, in: 0...Double(lengthMs)) { editing in
                if editing {
                    scrubMs = shown
                } else if let target = scrubMs {
                    onSeek(Int(target))
                    scrubMs = nil
                }
            }
            .controlSize(.mini)
            Button {
                showsLength.toggle()
            } label: {
                Text(showsLength ? Self.clock(ms: lengthMs) : "-" + Self.clock(ms: lengthMs - Int(shown)))
                    .frame(width: 34, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showsLength ? "Show time remaining" : "Show track length")
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var transport: some View {
        HStack(spacing: 26) {
            transportButton("backward.fill", size: 13, action: onPrevious)
            transportButton(isPlaying ? "pause.fill" : "play.fill", size: 19, action: onPlayPause)
                .frame(width: 22)
            transportButton("forward.fill", size: 13, action: onNext)
        }
        .frame(maxWidth: .infinity)
    }

    private func transportButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(minWidth: 22, minHeight: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "m:ss", or "h:mm:ss" past the hour, as every player writes it.
    static func clock(ms: Int) -> String {
        let total = max(ms, 0) / 1000
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

/// The same slot as the now-playing card, shown when nothing is. It fills
/// the same height, so nothing moves when a track starts, and it is drawn
/// dimmed the way an empty well is: a state, not a headline. The artwork
/// row keeps its place with a dashed well and a title, and the rows where
/// the scrubber and transport will be spend themselves on the two steps a
/// person takes on the phone. The name is read live, so the steps can never
/// go stale.
struct IdleCard: View {
    let connectName: String
    let showsInSpotify: Bool
    /// The glyph Spotify draws for this receiver, so step two shows what to
    /// look for in the list.
    let symbolName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ArtworkWell(isDashed: true) { ArtworkPlaceholder() }
                Text(showsInSpotify ? "Ready for Spotify" : "Hidden from Spotify")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(height: 40)

            if showsInSpotify {
                VStack(alignment: .leading, spacing: 5) {
                    step(1, symbol: SymbolCatalog.name("airplayaudio", fallback: "speaker.wave.2"),
                         text: "Open Spotify\u{2019}s device list")
                    step(2, symbol: symbolName,
                         text: "Pick \u{201C}\(connectName)\u{201D}")
                }
            } else {
                Text("Turn on the switch above to play here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Metrics.cardHeight, alignment: .topLeading)
        .opacity(0.62)
    }

    private func step(_ number: Int, symbol: String, text: String) -> some View {
        HStack(spacing: 8) {
            Text(String(number))
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(Circle().fill(.quaternary))
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// The slot while a phone has this receiver but no track has reached the
/// engine: the engine streaming the pipe before Spotify has said what is in
/// it, or a phone that has picked the receiver and not played yet. A spinner
/// where the cover goes, since something is in motion, and never the pipe
/// item's own title, which is the plumbing showing through.
struct ConnectingCard: View {
    let title: String
    let hint: String

    var body: some View {
        HStack(spacing: 10) {
            ArtworkWell {
                ProgressView()
                    .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: Metrics.cardHeight, alignment: .topLeading)
    }
}

/// The 40-point rounded square every card starts with. Dashed, it is the
/// outline of where artwork will go rather than an empty one.
struct ArtworkWell<Content: View>: View {
    var isDashed = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Group {
            if isDashed {
                shape.strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            } else {
                shape.fill(.quaternary)
            }
        }
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
    NowPlayingCard(
        track: Fixtures.nowPlaying, artworkURL: nil,
        lengthMs: Fixtures.nowPlaying.lengthMs ?? 214_000, isPlaying: true,
        progressMs: { _ in 62_000 }
    )
    .frame(width: Metrics.popoverWidth)
    .padding()
}

#Preview("Idle") {
    IdleCard(connectName: "HomePods", showsInSpotify: true, symbolName: "hifispeaker.fill")
        .frame(width: Metrics.popoverWidth)
        .padding()
}

#Preview("Idle, hidden from Spotify") {
    IdleCard(connectName: "HomePods", showsInSpotify: false, symbolName: "hifispeaker.fill")
        .frame(width: Metrics.popoverWidth)
        .padding()
}
