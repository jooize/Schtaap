import SwiftUI

/// The menu bar popover, laid out after the system Sound menu: a title line,
/// a master volume slider, an "Output" list of icon-well rows, and a footer.
struct PopoverView: View {
    @Environment(EngineStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title

            if let track = store.nowPlaying, track.hasMetadata {
                NowPlayingCard(track: track, artworkURL: artworkURL(for: track))
                    .padding(.horizontal, Metrics.horizontalInset)
                    .padding(.bottom, 10)
            }

            VolumeSlider(
                value: masterVolume,
                onEditingChanged: { editing in
                    editing ? store.beginAdjustingMaster() : store.endAdjustingMaster()
                }
            )
            .padding(.horizontal, Metrics.horizontalInset)
            .padding(.bottom, 12)

            if let verifying = store.verifying {
                VerificationCard(
                    output: verifying,
                    errorMessage: store.verificationError,
                    onSubmit: { store.submitVerification(pin: $0) },
                    onCancel: { store.cancelVerification() }
                )
                .padding(.horizontal, Metrics.horizontalInset)
                .padding(.bottom, 10)
            }

            if store.outputs.isEmpty {
                emptyState
            } else {
                outputList
            }

            Divider()
                .padding(.horizontal, Metrics.horizontalInset)
                .padding(.top, 6)

            footer
        }
        .padding(.vertical, 12)
        .frame(width: Metrics.popoverWidth)
    }

    // MARK: - Sections

    private var title: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Branding.appName)
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 8)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, Metrics.horizontalInset)
        .padding(.bottom, 10)
    }

    private var outputList: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(title: "Output")
                .padding(.horizontal, Metrics.horizontalInset)
                .padding(.bottom, 2)

            ForEach(store.outputs) { output in
                OutputRow(
                    output: output,
                    volume: volume(for: output),
                    onToggle: { store.toggle(output) },
                    onVolumeEditingChanged: { editing in
                        editing ? store.beginAdjusting(output) : store.endAdjusting(output)
                    }
                )
                .padding(.horizontal, Metrics.horizontalInset - 6)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.connection.isOnline ? "No speakers found" : "Engine not running")
                .font(.system(size: 13, weight: .medium))
            Text(engineHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") {
                Task { await store.refreshAll() }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.horizontal, Metrics.horizontalInset)
        .padding(.bottom, 4)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(title: "\(Branding.appName) Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }

            MenuRow(title: "Quit \(Branding.appName)") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, Metrics.horizontalInset - 6)
        .padding(.top, 6)
    }

    // MARK: - Derived values

    private var statusText: String {
        switch store.connection {
        case .connecting: "Connecting…"
        case .offline: "Engine offline"
        case .online:
            if store.player?.isPlaying == true {
                "\(selectedCount) speaker\(selectedCount == 1 ? "" : "s")"
            } else {
                "Not playing"
            }
        }
    }

    private var selectedCount: Int {
        store.outputs.filter(\.selected).count
    }

    private var engineHint: String {
        switch store.connection {
        case .offline(let reason): reason
        case .connecting: "Waiting for the audio engine to answer."
        case .online: "The engine is running but has not discovered any AirPlay speakers yet."
        }
    }

    private var masterVolume: Binding<Double> {
        Binding(
            get: { store.masterVolume },
            set: { store.setMasterVolume($0) }
        )
    }

    private func volume(for output: Output) -> Binding<Double> {
        Binding(
            get: {
                let current = store.outputs.first { $0.id == output.id } ?? output
                return Double(current.volume)
            },
            set: { store.setVolume($0, for: output) }
        )
    }

    private func artworkURL(for track: NowPlaying) -> URL? {
        guard let path = track.artworkUrl, !path.isEmpty else { return nil }
        return store.client.artworkURL(for: path, maxPixels: 128)
    }
}

#Preview {
    PopoverView()
        .environment(EngineStore.preview())
}
