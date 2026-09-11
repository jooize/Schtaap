import SwiftUI

/// The whole app. A persistent header -- who this Mac is in Spotify, what is
/// playing, the master volume -- sits above a section that swaps between pages,
/// and a footer that only the root page shows.
///
/// The header stays put on purpose: whatever you are doing in here, the music is
/// still playing and its volume is still the thing you are most likely to want.
struct PopoverView: View {
    @Environment(EngineStore.self) private var store
    @Environment(EngineService.self) private var engine
    @State private var showsAllOutputs = false
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var isEditingName = false
    /// Pages the user opened. Engine-driven pages win over this, so it only
    /// ever holds something that was asked for from the root.
    @State private var requestedPage: PopoverPage?
    @AppStorage(PreferenceKey.connectName) private var connectName: String = Branding.defaultConnectName
    @AppStorage(PreferenceKey.showsInSpotify) private var showsInSpotify: Bool = true
    @AppStorage(PreferenceKey.showsInNowPlaying) private var showsInNowPlaying: Bool = true

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
                controlSize: .regular,
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
        .onAppear {
            store.startDirectoryIfEnabled()
            // The engine can have stopped since the popover was last
            // open: a half that failed stays down and says so.
            engine.refreshStatus()
            store.requestLocalNetworkProbe()
        }
        .onDisappear { commitName() }
        // Switching the receiver off has to reach the engine to mean
        // anything: it is what stops librespot advertising.
        .onChange(of: showsInSpotify) { _, _ in applySettings() }
        .onChange(of: showsInNowPlaying) { _, enabled in store.publishesNowPlaying = enabled }
    }

    // MARK: - Sections

    @ViewBuilder
    private var header: some View {
        if page.title != nil {
            VStack(alignment: .leading, spacing: 8) {
                PageBar(backTitle: "Speakers") { leavePage() }
                nowPlayingSection
            }
            .padding(.horizontal, Metrics.horizontalInset)
            .padding(.bottom, 10)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                SectionHeader(title: "Appears in Spotify as")
                    .padding(.horizontal, Metrics.horizontalInset)

                ReceiverRow(
                    name: $connectName,
                    isEditing: $isEditingName,
                    showsInSpotify: $showsInSpotify,
                    subtitle: receiverSubtitle.text,
                    subtitleIsWarning: receiverSubtitle.isWarning,
                    symbolName: SymbolCatalog.name(SpotifyDeviceType.advertised.symbolName),
                    onCommit: { commitName() },
                    isRenamePending: engine.pendingConnectName != nil,
                    onRename: { engine.applyPendingRename() },
                    onCancelRename: {
                        // The field goes back to the name that is actually
                        // being advertised, which is what the row claims once
                        // the note is gone.
                        connectName = engine.appliedConnectName ?? Branding.defaultConnectName
                        engine.cancelPendingRename()
                    }
                )
                .padding(.horizontal, Metrics.horizontalInset - 6)

                nowPlayingSection
                    .padding(.horizontal, Metrics.horizontalInset)
                    .padding(.top, 6)
            }
            .padding(.bottom, 10)
        }
    }

    /// Always present, so the header does not change height when a track
    /// starts or stops.
    @ViewBuilder
    private var nowPlayingSection: some View {
        if let track = store.nowPlaying, track.hasMetadata {
            NowPlayingCard(
                track: track,
                artworkURL: artworkURL(for: track),
                lengthMs: track.lengthMs ?? store.player?.itemLengthMs,
                isPlaying: store.isPlaying,
                progressMs: { store.progressMs(at: $0) },
                onPlayPause: { store.isPlaying ? store.pausePlayback() : store.resumePlayback() },
                onPrevious: { store.skipToPrevious() },
                onNext: { store.skipToNext() },
                onSeek: { store.seek(toMs: $0) }
            )
        } else if store.nowPlaying?.isPlaceholder == true, store.player?.state == .play {
            ConnectingCard(
                title: "Connecting to Spotify\u{2026}",
                hint: "Sound and track details are on their way."
            )
        } else if store.spotifySession?.active == true {
            // A Spotify client has picked this receiver but nothing has
            // reached the engine yet: the seconds between a pick and the
            // first track, or a client that is connected and idle. Spotify
            // runs on phones, computers, speakers and consoles, so the hint
            // names none of them; and the speakers can stand in any room,
            // so it does not say where the sound comes out either.
            ConnectingCard(
                title: "Waiting for Spotify\u{2026}",
                hint: "Press play in Spotify to play on your speakers."
            )
        } else {
            IdleCard(
                connectName: connectName, showsInSpotify: showsInSpotify,
                symbolName: SymbolCatalog.name(SpotifyDeviceType.advertised.symbolName)
            )
        }
    }

    /// Names the machine the receiver actually is, which is the fact the old
    /// "Spotify -> name" arrow was hiding.
    ///
    /// Switched off, the section heading above is briefly a lie -- the name is
    /// still there but nothing is advertising it -- so the subtitle is where
    /// that gets said, in the line already spent on this.
    ///
    /// While a phone uses the receiver the line says so, and names the
    /// client when Spotify said what it is. A receiver that cannot reach
    /// Spotify's servers, or is not running at all, says that instead, as a
    /// warning: everything on the LAN can be fine while that is the fault.
    private var receiverSubtitle: (text: String, isWarning: Bool) {
        guard showsInSpotify else { return ("Not appearing in Spotify", false) }
        switch store.spotifyUplink {
        case .down where store.connection.isOnline:
            return ("Spotify receiver is not running", true)
        case .lost:
            return ("Reconnecting to Spotify\u{2026}", true)
        default:
            break
        }
        // The one fault neither the uplink nor the session shows: the engine
        // is running and reaching Spotify, and no phone can see it. Named as
        // System Settings names it: the engine runs as this app's children, so
        // the grant that is missing is the app's own row.
        if store.spotifySession?.isLocalNetworkDenied == true {
            return ("Local Network access is off for \(Branding.appName)", true)
        }
        if let session = store.spotifySession, session.active {
            if let client = session.clientDescription {
                return ("Connected from \(client)", false)
            }
            return ("Connected", false)
        }
        guard let device = Host.current().localizedName, !device.isEmpty else {
            return ("on this Mac", false)
        }
        return ("on \(device)", false)
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
                errorMessage: store.verificationError,
                onSubmit: { store.submitVerification(pin: $0) },
                onCancel: { leavePage() }
            )
            .padding(.horizontal, Metrics.horizontalInset)
            .padding(.bottom, 4)
        }
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
                    failure: store.startFailure(for: group),
                    volume: groupVolume(for: group),
                    masterLevel: masterLevel,
                    // Animated because selecting a speaker lifts its row to the
                    // top of the list; without it the row appears to teleport.
                    onToggle: { withAnimation(.snappy(duration: 0.2)) { store.toggle(group) } },
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

    /// Collapsed, the list keeps every speaker that is playing or on its way
    /// back -- those are in use -- and fills the remainder with the rest in
    /// the engine's own order, so nothing reorders when the list expands.
    private var visibleGroups: [SpeakerGroup] {
        let allGroups = store.speakerGroups
        guard !showsAllOutputs else { return allGroups }

        let engagedCount = allGroups.count(where: \.isEngaged)
        var budget = max(0, Self.collapsedRowTarget - engagedCount)

        return allGroups.filter { group in
            if group.isEngaged { return true }
            guard budget > 0 else { return false }
            budget -= 1
            return true
        }
    }

    private var hiddenGroupCount: Int {
        store.speakerGroups.count - visibleGroups.count
    }

    /// Shown when there is no speaker list to show. What is wrong is usually
    /// the engine rather than the network, so this asks the engine first and
    /// only falls back to the connection when the engine is up.
    @ViewBuilder
    private var emptyState: some View {
        if isStartingUp {
            startingState
        } else {
            failedState
        }
    }

    /// The engine is up, or on its way, but nothing has answered yet. Not a
    /// failure until the grace runs out.
    private var isStartingUp: Bool {
        guard store.isAwaitingFirstContact, !store.connection.isOnline else { return false }
        switch engine.status {
        case .running, .idle: return true
        case .missingPayload, .failed: return false
        }
    }

    private var startingState: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Starting the audio engine")
                    .font(.system(size: 13, weight: .medium))
                Text("Your speakers appear once it answers.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Metrics.horizontalInset)
        .padding(.bottom, 4)
    }

    private var failedState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(emptyStateTitle)
                .font(.system(size: 13, weight: .medium))
            Text(emptyStateDetail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if case .missingPayload = engine.status {
                // Nothing the user can do from here: this build has no engine
                // in it, which is a thing that happened at compile time.
                EmptyView()
            } else {
                Button("Try Again") {
                    applySettings()
                    Task { await store.refreshAll() }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
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

            // The system's Now Playing slot is one per Mac and last-writer-
            // wins, so holding it is offered rather than assumed.
            MenuRow(title: "Show in Now Playing") {
                showsInNowPlaying.toggle()
            } trailing: {
                Image(systemName: showsInNowPlaying ? "checkmark" : "")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
            }

            MenuRow(title: "Quit \(Branding.appName)") {
                // The engine goes with the app: AppDelegate stops it.
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

    /// Leaves the name field and hands the result to the engine.
    ///
    /// The name is librespot's `--name`, so a changed one has to reach the
    /// agent to mean anything. `apply` writes it and restarts the Spotify
    /// receiver only if the file actually changed, which is why this can be
    /// called on every dismissal, focus loss and tap outside the field. While
    /// a Spotify client is connected it holds the new name back instead, and
    /// the row grows a Rename button.
    private func commitName() {
        isEditingName = false

        let trimmed = connectName.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty name would leave librespot advertising nothing at all, so
        // clearing the field falls back rather than committing the blank.
        connectName = trimmed.isEmpty ? Branding.defaultConnectName : trimmed
        applySettings()
    }

    /// Hands everything the engine reads at launch to it at once. `apply`
    /// restarts a half only when the file that half reads actually changed --
    /// a rename is librespot's alone -- and starts what is down, so this is
    /// safe to call on every edit, dismissal and tap outside.
    private func applySettings() {
        engine.apply(connectName: connectName, showsInSpotify: showsInSpotify)
    }

    // MARK: - Derived values

    private var emptyStateTitle: String {
        switch engine.status {
        case .missingPayload: "No audio engine"
        case .failed: "The engine could not start"
        case .idle, .running:
            store.connection.isOnline ? "No speakers found" : "Engine not running"
        }
    }

    private var emptyStateDetail: String {
        switch engine.status {
        case .missingPayload:
            "This build of \(Branding.appName) was made without the audio engine."
        case .failed(let reason):
            reason
        case .idle, .running:
            switch store.connection {
            case .offline(let reason): reason
            case .connecting: "Waiting for the audio engine to answer."
            case .online: "The engine is running but has not discovered any AirPlay speakers yet."
            }
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

    /// The master's level for the marks on the speaker rows, nil while fewer
    /// than two rows play: a lone speaker is the master, and marking it would
    /// say so twice.
    ///
    /// Derived from the outputs rather than read back from the engine, which
    /// defines master as the loudest selected output: a row being dragged past
    /// the master moves the marks on the other rows at once, where the engine's
    /// own number only arrives after the write.
    private var masterLevel: Double? {
        let playing = store.speakerGroups.filter(\.anySelected)
        guard playing.count > 1 else { return nil }
        let loudest = playing
            .flatMap(\.members)
            .filter(\.selected)
            .map(\.volume)
            .max()
        return loudest.map(Double.init)
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
        .environment(EngineService(usesFixtures: true))
}
