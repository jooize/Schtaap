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

    private(set) var connection: Connection = .connecting {
        didSet { if connection.isOnline { isAwaitingFirstContact = false } }
    }

    /// True from `start()` until the engine answers for the first time, or
    /// the grace period runs out. launchd may still be spawning the agents
    /// -- after a rebuild, up to about 35 s while the registration heals --
    /// and the notify client retries throughout, so the honest thing to show
    /// meanwhile is "starting", not "not running". The grace is generous
    /// because a wrong "failed" costs more than a slow spinner.
    private(set) var isAwaitingFirstContact = false
    private var firstContactGrace: Task<Void, Never>?
    private static let firstContactGracePeriod = Duration.seconds(60)
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

    /// Outputs the engine refused to start, by id, with what to tell the user.
    ///
    /// A refusal is answered by a refetch that puts the row back to off, so
    /// without this the click looks like it did nothing at all.
    private(set) var startFailures: [String: String] = [:]

    /// This Mac's name, which is also the name of its own AirPlay receiver.
    /// Read once: `Host.current().localizedName` goes to SystemConfiguration.
    private let localDeviceName = Host.current().localizedName

    /// Speakers the user asked for and the engine has not got right now, by
    /// output id. Each is being retried until it comes back. See
    /// `IntendedOutputs` for why this exists.
    private(set) var rejoining: Set<String> = []

    /// What the user asked for, persisted so it outlives the app. Nil under
    /// fixtures, where it must not be read or written.
    private var intended: IntendedOutputs?
    private var rejoinTasks: [String: Task<Void, Never>] = [:]

    /// Seconds between attempts to win a speaker back. Capped at the last
    /// entry: a speaker taken for a film should not be hammered all evening,
    /// but it should still come back within the minute of being freed.
    private static let rejoinBackoff: [Duration] = [
        .seconds(5), .seconds(10), .seconds(20), .seconds(30), .seconds(60),
    ]

    /// Whether to hold the system's Now Playing slot. Off, the slot is left to
    /// whatever else on this Mac wants it.
    var publishesNowPlaying = true {
        didSet { publishNowPlaying() }
    }
    private let nowPlayingCenter = NowPlayingCenter()

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
        // Left nil until the first live refresh when there is no file yet, so
        // the speakers already playing become the intent rather than an
        // empty set that would treat them as nobody's.
        self.intended = usesFixtures ? nil : IntendedOutputs.load(from: Self.intendedFile)
    }

    private static var intendedFile: URL {
        Branding.supportDirectory.appending(path: "intended-outputs.json")
    }

    // MARK: - Lifecycle

    func start() {
        guard lifecycle == nil else { return }

        if usesFixtures {
            applyFixtures()
            return
        }

        isAwaitingFirstContact = true
        firstContactGrace = Task { [weak self] in
            try? await Task.sleep(for: Self.firstContactGracePeriod)
            guard !Task.isCancelled else { return }
            self?.isAwaitingFirstContact = false
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
        firstContactGrace?.cancel()
        firstContactGrace = nil
        isAwaitingFirstContact = false
        for task in volumeWrites.values { task.cancel() }
        volumeWrites.removeAll()
        for task in rejoinTasks.values { task.cancel() }
        rejoinTasks.removeAll()
        rejoining.removeAll()
        nowPlayingCenter.clear()
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
            adoptSelectionIfUnset()
            reconcileRejoins()
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
            publishNowPlaying()
        } catch {
            connection = .offline(error.localizedDescription)
        }
    }

    func refreshNowPlaying() async {
        guard !usesFixtures else { return }
        nowPlaying = try? await client.nowPlaying()
        publishNowPlaying()
    }

    /// Hands the current track to the system's Now Playing slot, or lets go
    /// of it. Fixtures never touch the slot: it is shared with every other
    /// app on the Mac, which makes it as far from offline as the network.
    private func publishNowPlaying() {
        guard !usesFixtures else { return }
        guard publishesNowPlaying, connection.isOnline else {
            nowPlayingCenter.clear()
            return
        }
        let artwork = nowPlaying?.artworkUrl.flatMap { path -> URL? in
            guard !path.isEmpty else { return nil }
            return client.artworkURL(for: path, maxPixels: 600)
        }
        nowPlayingCenter.publish(track: nowPlaying, player: player, artworkURL: artwork)
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
        // Trying again clears the last complaint, whatever comes of this one.
        startFailures[output.id] = nil
        // This is the user speaking, which is the only thing that rewrites
        // what they asked for. Switching a speaker off also calls off any
        // attempt to win it back.
        setIntended(selected, output)
        guard !isOffline else { return }

        Task { [client] in
            do {
                try await client.setSelected(selected, forOutput: output.id)
            } catch {
                self.startFailures[output.id] = Self.startFailureText(error, selecting: selected)
            }
            await self.refreshOutputs()
            if selected { self.promptForVerificationIfNeeded(output.id) }
        }
    }

    /// What the engine's refusal is worth saying in a 300pt row.
    ///
    /// The engine answers a failed activation with a bare 400 -- the reason is
    /// in its log and not in the response -- so the status code is all we have
    /// to go on. Anything that is not an HTTP status is the network.
    private static func startFailureText(_ error: Error, selecting: Bool) -> String {
        guard case EngineError.http = error else { return error.localizedDescription }
        return selecting ? "This speaker would not start" : "This speaker would not stop"
    }

    /// The complaint to show on a row, if any member of it has one.
    func startFailure(for group: SpeakerGroup) -> String? {
        group.members.lazy.compactMap { self.startFailures[$0.id] }.first
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
                    self.setIntended(true, output)
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

    // MARK: - Rejoining speakers

    private func setIntended(_ wanted: Bool, _ output: Output) {
        guard var set = intended else { return }
        if wanted { set.insert(output) } else { set.remove(output) }
        guard set != intended else { return }
        intended = set
        set.save(to: Self.intendedFile)
        if !wanted { endRejoin(output.id) }
    }

    /// The first live refresh on a Mac with no record yet takes whatever is
    /// playing as what was asked for. Until then every speaker is nobody's.
    private func adoptSelectionIfUnset() {
        guard intended == nil, !usesFixtures else { return }
        var set = IntendedOutputs()
        for output in outputs where output.selected && output.isAirPlay {
            set.insert(output)
        }
        intended = set
        set.save(to: Self.intendedFile)
    }

    /// Lines the engine's selection up against the intent after every
    /// refresh. An intended speaker that is not playing starts being won
    /// back; one that is playing again, or was given up on, stops.
    private func reconcileRejoins() {
        guard let intended, !isOffline else { return }
        var live: Set<String> = []
        for output in outputs where output.isAirPlay {
            let wanted = intended.contains(output)
            // A device asking for its code is not busy, it is waiting on the
            // user, and retrying would only make it show the code again.
            if wanted, !output.selected, !output.needsVerification {
                live.insert(output.id)
                beginRejoin(output.id)
            } else {
                endRejoin(output.id)
            }
        }
        for id in rejoining.subtracting(live) { endRejoin(id) }
    }

    private func beginRejoin(_ id: String) {
        guard rejoinTasks[id] == nil else { return }
        rejoining.insert(id)
        rejoinTasks[id] = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                let delay = Self.rejoinBackoff[min(attempt, Self.rejoinBackoff.count - 1)]
                attempt += 1
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                // The engine answers a speaker that is still taken with a
                // refusal, and that refusal is the probe: nothing else on the
                // network says whether it is free.
                let joined = (try? await self.client.setSelected(true, forOutput: id)) != nil
                guard !Task.isCancelled else { return }
                if joined { self.startFailures[id] = nil }
                // Refreshing runs the reconcile, which ends this task once the
                // speaker reports itself playing.
                await self.refreshOutputs()
            }
        }
    }

    private func endRejoin(_ id: String) {
        rejoinTasks[id]?.cancel()
        rejoinTasks[id] = nil
        rejoining.remove(id)
    }

    /// Whether any member of a row is being won back.
    func isRejoining(_ group: SpeakerGroup) -> Bool {
        group.members.contains { rejoining.contains($0.id) }
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
                isPair: true,
                isRejoining: sorted.contains { rejoining.contains($0.id) }
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
                isPair: false,
                isThisMac: isThisMac(output),
                isRejoining: rejoining.contains(output.id)
            ))
        }

        // Playing first, then the ones on their way back, then the rest. A
        // speaker being won back is still one of the user's, so it stays up
        // with them rather than dropping into the silent alphabet below.
        groups.sort { left, right in
            if left.anySelected != right.anySelected { return left.anySelected }
            if left.isRejoining != right.isRejoining { return left.isRejoining }
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

    /// Whether an output is this Mac's own AirPlay receiver.
    ///
    /// macOS names that receiver after the computer, and the engine reports it
    /// like any other speaker on the network, so the name is the whole test.
    /// Renaming the receiver away from the computer name is possible and costs
    /// only the badge.
    func isThisMac(_ output: Output) -> Bool {
        guard let localDeviceName else { return false }
        return output.name.compare(localDeviceName, options: .caseInsensitive) == .orderedSame
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
