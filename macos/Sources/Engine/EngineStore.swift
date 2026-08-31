import Foundation
import Observation

/// Live view of the engine, shared by every window.
///
/// Reads are pushed: `NotifyClient` tells us which category changed and we
/// refetch just that. Writes are optimistic, so a slider never lags the
/// pointer; the authoritative value arrives moments later on the websocket.
@MainActor
@Observable
final class EngineStore {
    enum Connection: Equatable {
        case connecting
        case online
        case offline(String)

        var isOnline: Bool { self == .online }
    }

    private(set) var connection: Connection = .connecting
    private(set) var outputs: [Output] = []
    private(set) var player: PlayerStatus?
    private(set) var nowPlaying: NowPlaying?

    /// Master volume in 0...100. Written straight through by the slider.
    private(set) var masterVolume: Double = 50

    /// True when the user has muted via the popover. The pre-mute level is
    /// kept so unmuting restores it.
    private(set) var isMasterMuted = false
    var preMuteLevel: Double = 50

    private var mutedGroups: Set<String> = []
    private var preMuteGroupVolumes: [String: Int] = [:]

    /// Set when a device answers a selection attempt by displaying a code on
    /// its screen instead of accepting the stream. Apple TVs and some
    /// receivers do this. The popover swaps in a PIN field while it is set.
    private(set) var verifying: Output?
    private(set) var verificationError: String?

    let client: EngineClient

    /// Bonjour lookup for device hardware, which the engine's API omits.
    let directory = AirPlayDirectory()

    private let notify: NotifyClient
    private let usesFixtures: Bool

    /// Outputs whose slider the user is currently dragging. Refreshes leave
    /// their volume alone so the knob does not fight the pointer.
    private var adjusting: Set<String> = []
    private var isAdjustingMaster = false

    /// One in-flight debounce per output, plus one for master.
    private var volumeWrites: [String: Task<Void, Never>] = [:]
    private var lifecycle: Task<Void, Never>?

    private static let volumeDebounce = Duration.milliseconds(120)
    private static let masterKey = "__master__"

    init(endpoint: EngineEndpoint = .default, usesFixtures: Bool = false) {
        self.client = EngineClient(endpoint: endpoint)
        self.notify = NotifyClient(endpoint: endpoint)
        self.usesFixtures = usesFixtures
    }

    // MARK: - Lifecycle

    func start() {
        guard lifecycle == nil else { return }

        if usesFixtures {
            applyFixtures()
            return
        }

        lifecycle = Task { [weak self] in
            guard let self else { return }
            await self.refreshAll()
            for await message in self.notify.stream() {
                await self.handle(message)
            }
        }
    }

    func stop() {
        directory.stop()
        lifecycle?.cancel()
        lifecycle = nil
        for task in volumeWrites.values { task.cancel() }
        volumeWrites.removeAll()
    }

    private func handle(_ message: NotifyMessage) async {
        switch message {
        case .connected:
            connection = .online
            await refreshAll()
        case .disconnected(let reason):
            connection = .offline(reason)
        case .events(let events):
            if events.contains(.outputs) || events.contains(.volume) {
                await refreshOutputs()
            }
            if events.contains(.player) || events.contains(.volume) {
                await refreshPlayer()
            }
            if events.contains(.player) || events.contains(.queue) {
                await refreshNowPlaying()
            }
        }
    }

    // MARK: - Reads

    func refreshAll() async {
        await refreshOutputs()
        await refreshPlayer()
        await refreshNowPlaying()
    }

    func refreshOutputs() async {
        guard !usesFixtures else { return }
        do {
            let fetched = try await client.outputs()
            outputs = fetched.map { output in
                // Preserve the value under an active pointer.
                guard adjusting.contains(output.id),
                      let local = outputs.first(where: { $0.id == output.id })
                else { return output }
                var merged = output
                merged.volume = local.volume
                return merged
            }
            connection = .online
        } catch {
            connection = .offline(error.localizedDescription)
        }
    }

    func refreshPlayer() async {
        guard !usesFixtures else { return }
        do {
            let status = try await client.player()
            player = status
            if !isAdjustingMaster {
                masterVolume = Double(status.volume)
            }
        } catch {
            connection = .offline(error.localizedDescription)
        }
    }

    func refreshNowPlaying() async {
        guard !usesFixtures else { return }
        nowPlaying = try? await client.nowPlaying()
    }

    // MARK: - Writes

    /// Fixtures exist to run the UI with no engine, so every write below stops
    /// at the optimistic local update and never reaches the network.
    ///
    /// This is not belt and braces. The default endpoint is localhost:3689, and
    /// a Lima VM forwards that port to a real owntone, so an unguarded refresh
    /// answers 200 and swaps the fixture speakers for the household's -- whose
    /// names the fixture directory knows nothing about, so every icon goes
    /// generic and every pair comes apart the first time anything is clicked.
    private var isOffline: Bool { usesFixtures }

    func toggle(_ output: Output) {
        // A device that has already asked for a code goes straight back to the
        // prompt rather than through another attempt that can only fail.
        if !output.selected, output.needsVerification {
            beginVerification(for: output)
            return
        }
        setSelected(!output.selected, for: output)
    }

    func setSelected(_ selected: Bool, for output: Output) {
        apply(to: output.id) { $0.selected = selected }
        guard !isOffline else { return }

        Task { [client] in
            try? await client.setSelected(selected, forOutput: output.id)
            await self.refreshOutputs()
            if selected { self.promptForVerificationIfNeeded(output.id) }
        }
    }

    // MARK: - Device verification

    func beginVerification(for output: Output) {
        verifying = output
        verificationError = nil
    }

    func cancelVerification() {
        verifying = nil
        verificationError = nil
    }

    func submitVerification(pin: String) {
        guard let output = verifying else { return }

        // No engine to accept a code, so any code passes and the flow can still
        // be walked through offline.
        guard !isOffline else {
            apply(to: output.id) { $0.selected = true }
            cancelVerification()
            return
        }

        Task { [client] in
            do {
                try await client.verify(pin: pin, forOutput: output.id)
                await self.refreshOutputs()
                if self.outputs.first(where: { $0.id == output.id })?.selected == true {
                    self.cancelVerification()
                } else {
                    self.verificationError = "That code was not accepted."
                }
            } catch {
                self.verificationError = error.localizedDescription
            }
        }
    }

    /// A selection that left the output unselected and asking for a key means
    /// the device is now showing a code.
    private func promptForVerificationIfNeeded(_ id: String) {
        guard let current = outputs.first(where: { $0.id == id }) else { return }
        guard current.needsVerification, !current.selected else { return }
        beginVerification(for: current)
    }

    func setVolume(_ value: Double, for output: Output) {
        let level = Int(value.rounded())
        apply(to: output.id) { $0.volume = level }
        guard !isOffline else { return }
        debounce(key: output.id) { [client] in
            try? await client.setVolume(level, forOutput: output.id)
        }
    }

    func beginAdjusting(_ output: Output) {
        adjusting.insert(output.id)
    }

    func endAdjusting(_ output: Output) {
        adjusting.remove(output.id)
        volumeWrites[output.id]?.cancel()
        guard !isOffline else { return }
        let level = outputs.first(where: { $0.id == output.id })?.volume ?? output.volume
        Task { [client] in
            try? await client.setVolume(level, forOutput: output.id)
            await self.refreshOutputs()
        }
    }

    func setMasterVolume(_ value: Double) {
        masterVolume = value
        guard !isOffline else { return }
        let level = Int(value.rounded())
        debounce(key: Self.masterKey) { [client] in
            try? await client.setMasterVolume(level)
        }
    }

    func beginAdjustingMaster() {
        isAdjustingMaster = true
    }

    func endAdjustingMaster() {
        isAdjustingMaster = false
        volumeWrites[Self.masterKey]?.cancel()
        guard !isOffline else { return }
        let level = Int(masterVolume.rounded())
        Task { [client] in
            try? await client.setMasterVolume(level)
            await self.refreshPlayer()
        }
    }

    func toggleMasterMute() {
        if isMasterMuted {
            isMasterMuted = false
            setMasterVolume(preMuteLevel)
        } else {
            preMuteLevel = masterVolume
            isMasterMuted = true
            setMasterVolume(0)
        }
    }

    func toggleGroupMute(_ group: SpeakerGroup) {
        if mutedGroups.contains(group.id) {
            mutedGroups.remove(group.id)
            let restore = preMuteGroupVolumes[group.id] ?? group.volume
            setGroupVolume(Double(restore), for: group)
        } else {
            preMuteGroupVolumes[group.id] = group.volume
            mutedGroups.insert(group.id)
            setGroupVolume(0, for: group)
        }
    }

    func isGroupMuted(_ group: SpeakerGroup) -> Bool {
        mutedGroups.contains(group.id)
    }

    func preMuteGroupLevel(for group: SpeakerGroup) -> Int {
        preMuteGroupVolumes[group.id] ?? group.volume
    }

    func setPreMuteGroupLevel(_ value: Double, for group: SpeakerGroup) {
        preMuteGroupVolumes[group.id] = Int(value.rounded())
    }

    // MARK: - Speaker groups

    /// Outputs merged into rows: stereo pairs become one entry with a shared
    /// volume slider and toggle.
    ///
    /// Whatever is playing sorts to the top -- those rows carry sliders and are
    /// the ones being adjusted -- and everything else follows alphabetically, so
    /// a pair and the Apple TV it belongs to still sit together within each
    /// half. Collapsing the list drops rows off the bottom and never reorders
    /// what stays.
    var speakerGroups: [SpeakerGroup] {
        let visible = outputs.filter { $0.isAirPlay }
        var pairBuckets: [String: [Output]] = [:]
        var singles: [Output] = []

        for output in visible {
            if let identity = directory.identity(forOutputNamed: output.name),
               identity.isStereoPairMember,
               let pairID = identity.pairID {
                pairBuckets[pairID, default: []].append(output)
            } else {
                singles.append(output)
            }
        }

        var groups: [SpeakerGroup] = []

        for (pairID, members) in pairBuckets {
            let sorted = members.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let displayName = SpeakerGroup.derivePairName(from: sorted)
            let identity = directory.identity(forOutputNamed: sorted[0].name)
            let symbol = SymbolCatalog.name(identity?.symbolName ?? sorted[0].symbolName)

            groups.append(SpeakerGroup(
                id: pairID,
                displayName: displayName,
                members: sorted,
                symbolName: symbol,
                memberSymbolName: unitSymbolName(for: sorted[0]),
                groupName: identity?.groupName,
                isPair: true
            ))
        }

        for output in singles {
            groups.append(SpeakerGroup(
                id: output.id,
                displayName: output.name,
                members: [output],
                symbolName: symbolName(for: output),
                memberSymbolName: unitSymbolName(for: output),
                groupName: groupName(for: output),
                isPair: false
            ))
        }

        groups.sort { left, right in
            if left.anySelected != right.anySelected { return left.anySelected }
            return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
        return groups
    }

    func toggle(_ group: SpeakerGroup) {
        let target = !group.selected
        for member in group.members where member.selected != target {
            if !target || !member.needsVerification {
                setSelected(target, for: member)
            } else {
                beginVerification(for: member)
            }
        }
    }

    func setGroupVolume(_ value: Double, for group: SpeakerGroup) {
        for member in group.members {
            setVolume(value, for: member)
        }
    }

    func beginAdjusting(_ group: SpeakerGroup) {
        for member in group.members { adjusting.insert(member.id) }
    }

    func endAdjusting(_ group: SpeakerGroup) {
        for member in group.members { endAdjusting(member) }
    }

    // MARK: - Presentation

    /// The icon for an output: its real hardware when Bonjour has told us,
    /// the coarse guess from the engine's output type otherwise.
    func symbolName(for output: Output) -> String {
        let name = directory.identity(forOutputNamed: output.name)?.symbolName ?? output.symbolName
        return SymbolCatalog.name(name)
    }

    /// The icon for one physical unit of an output, never the joined two-unit
    /// variant. A merged pair row draws one per member so each can be tinted by
    /// its own selection.
    func unitSymbolName(for output: Output) -> String {
        let name = directory.identity(forOutputNamed: output.name)?.unitSymbolName ?? output.symbolName
        return SymbolCatalog.name(name)
    }

    /// The group a speaker was adopted into, when that is not simply itself --
    /// a HomePod pair belonging to an Apple TV's home theatre, say.
    func groupName(for output: Output) -> String? {
        directory.identity(forOutputNamed: output.name)?.groupName
    }

    /// Starts the Bonjour browse.
    ///
    /// Called when the popover first appears rather than at launch, so the
    /// local network prompt arrives with the speaker list on screen instead of
    /// unexplained at login.
    func startDirectoryIfEnabled() {
        guard !usesFixtures else { return }
        directory.start()
    }

    // MARK: - Helpers

    /// Seeds state directly, bypassing the network. Used by fixtures.
    func load(outputs: [Output], player: PlayerStatus?, nowPlaying: NowPlaying?) {
        self.outputs = outputs
        self.player = player
        self.nowPlaying = nowPlaying
        self.masterVolume = Double(player?.volume ?? 50)
        self.connection = .online
    }

    private func apply(to id: String, _ mutate: (inout Output) -> Void) {
        guard let index = outputs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&outputs[index])
    }

    private func debounce(key: String, _ work: @escaping @Sendable () async -> Void) {
        volumeWrites[key]?.cancel()
        volumeWrites[key] = Task {
            try? await Task.sleep(for: Self.volumeDebounce)
            guard !Task.isCancelled else { return }
            await work()
        }
    }
}
