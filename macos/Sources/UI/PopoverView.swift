import SwiftUI

/// The whole app. A persistent header -- who this Mac is in Spotify, what is
/// playing, the master volume -- sits above a section that swaps between pages,
/// and a footer that only the root page shows.
///
/// The header stays put on purpose: whatever you are doing in here, the music is
/// still playing and its volume is still the thing you are most likely to want.
struct PopoverView: View {
    @Environment(EngineStore.self) private var store
    @State private var showsAllOutputs = false
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var isEditingName = false
    /// Pages the user opened. Engine-driven pages win over this, so it only
    /// ever holds something that was asked for from the root.
    @State private var requestedPage: PopoverPage?
    @AppStorage(PreferenceKey.connectName) private var connectName: String = Branding.defaultConnectName
    @FocusState private var isNameFocused: Bool

    private static let collapsedRowTarget = 6

    /// A device asking for its code interrupts whatever else is open: it is
    /// waiting on the user and times out on its own.
    private var page: PopoverPage {
        if let verifying = store.verifying { return .verification(verifying) }
        return requestedPage ?? .speakers
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VolumeSlider(
                value: masterVolume,
                isMuted: store.isMasterMuted,
                onEditingChanged: { editing in
                    editing ? store.beginAdjustingMaster() : store.endAdjustingMaster()
                },
                onMuteToggle: { store.toggleMasterMute() }
            )
            .padding(.horizontal, Metrics.horizontalInset)
            .padding(.bottom, 12)

            content

            if page == .speakers {
                Divider()
                    .padding(.horizontal, Metrics.horizontalInset)
                    .padding(.top, 6)

                footer
            }
        }
        .padding(.vertical, 12)
        .frame(width: Metrics.popoverWidth)
        .contentShape(Rectangle())
        .onTapGesture { commitName() }
        .onExitCommand { leavePage() }
        .onAppear { store.startDirectoryIfEnabled() }
        .onDisappear { commitName() }
        .onChange(of: isNameFocused) { _, focused in
            if !focused { commitName() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = page.title {
                PageBar(title: title) { leavePage() }
            } else {
                connectNameLine
            }

            if let track = store.nowPlaying, track.hasMetadata {
                nowPlayingCard(track)
            }
        }
        .padding(.horizontal, Metrics.horizontalInset)
        .padding(.bottom, 10)
    }

    private var connectNameLine: some View {
        HStack(spacing: 0) {
            Text("Spotify \u{2192} ")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if isEditingName {
                TextField("HomePods", text: $connectName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($isNameFocused)
                    .onSubmit { commitName() }
                    .onExitCommand { commitName() }
                Spacer(minLength: 4)
            } else {
                Button { isEditingName = true; isNameFocused = true } label: {
                    Text(connectName)
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .speakers:
            if store.outputs.isEmpty {
                emptyState
            } else {
                outputList
            }
        case .verification(let output):
            VerificationPage(
                output: output,
                symbolName: store.symbolName(for: output),
                errorMessage: store.verificationError,
                onSubmit: { store.submitVerification(pin: $0) }
            )
            .padding(.horizontal, Metrics.horizontalInset)
            .padding(.bottom, 4)
        }
    }

    private func nowPlayingCard(_ track: NowPlaying) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.quaternary)
                .frame(width: 36, height: 36)
                .overlay {
                    if let url = artworkURL(for: track) {
                        AsyncImage(url: url) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Image(systemName: "music.note")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title ?? "Unknown track")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = nowPlayingSubtitle(track) {
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

    private func nowPlayingSubtitle(_ track: NowPlaying) -> String? {
        let parts = [track.artist, track.album].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    private var outputList: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(title: "Output")
                .padding(.horizontal, Metrics.horizontalInset)
                .padding(.bottom, 2)

            ForEach(visibleGroups) { group in
                OutputRow(
                    group: group,
                    isMuted: store.isGroupMuted(group),
                    volume: groupVolume(for: group),
                    onToggle: { store.toggle(group) },
                    onVolumeEditingChanged: { editing in
                        editing ? store.beginAdjusting(group) : store.endAdjusting(group)
                    },
                    onMuteToggle: { store.toggleGroupMute(group) }
                )
                .padding(.horizontal, Metrics.horizontalInset - 6)
            }

            if hiddenGroupCount > 0 || showsAllOutputs {
                MenuRow(title: showsAllOutputs ? "Show Less" : "Show More") {
                    withAnimation(.snappy(duration: 0.18)) { showsAllOutputs.toggle() }
                } trailing: {
                    Image(systemName: showsAllOutputs ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, Metrics.horizontalInset - 6)
                .padding(.top, 2)
            }
        }
    }

    /// Collapsed, the list keeps every speaker that is playing -- those carry
    /// sliders and are in use -- and fills the remainder with the rest in the
    /// engine's own order, so nothing reorders when the list expands.
    private var visibleGroups: [SpeakerGroup] {
        let allGroups = store.speakerGroups
        guard !showsAllOutputs else { return allGroups }

        let playingCount = allGroups.count(where: \.anySelected)
        var budget = max(0, Self.collapsedRowTarget - playingCount)

        return allGroups.filter { group in
            if group.anySelected { return true }
            guard budget > 0 else { return false }
            budget -= 1
            return true
        }
    }

    private var hiddenGroupCount: Int {
        store.speakerGroups.count - visibleGroups.count
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
            MenuRow(title: "Start at Login") {
                launchAtLogin.toggle()
            } trailing: {
                Image(systemName: launchAtLogin ? "checkmark" : "")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
            }
            .onChange(of: launchAtLogin) { _, enabled in
                do {
                    try LoginItem.setEnabled(enabled)
                } catch {
                    launchAtLogin = LoginItem.isEnabled
                }
            }

            MenuRow(title: "Quit \(Branding.appName)") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, Metrics.horizontalInset - 6)
        .padding(.top, 6)
    }

    // MARK: - Navigation

    /// Back out of whatever page is open. Cancelling the verification is what
    /// closes it, since the store is what put it on screen.
    private func leavePage() {
        if store.verifying != nil { store.cancelVerification() }
        requestedPage = nil
    }

    private func commitName() {
        isNameFocused = false
        isEditingName = false
    }

    // MARK: - Derived values

    private var engineHint: String {
        switch store.connection {
        case .offline(let reason): reason
        case .connecting: "Waiting for the audio engine to answer."
        case .online: "The engine is running but has not discovered any AirPlay speakers yet."
        }
    }

    private var masterVolume: Binding<Double> {
        Binding(
            get: { store.isMasterMuted ? store.preMuteLevel : store.masterVolume },
            set: {
                if store.isMasterMuted {
                    store.preMuteLevel = $0
                } else {
                    store.setMasterVolume($0)
                }
            }
        )
    }

    private func groupVolume(for group: SpeakerGroup) -> Binding<Double> {
        Binding(
            get: {
                if store.isGroupMuted(group) {
                    return Double(store.preMuteGroupLevel(for: group))
                }
                let current = store.speakerGroups.first { $0.id == group.id } ?? group
                return Double(current.volume)
            },
            set: {
                if store.isGroupMuted(group) {
                    store.setPreMuteGroupLevel($0, for: group)
                } else {
                    store.setGroupVolume($0, for: group)
                }
            }
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
