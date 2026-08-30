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

        directory.start()

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
        nowPlaying = try? await client.nowPlaying()
    }

    // MARK: - Writes

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
        let level = outputs.first(where: { $0.id == output.id })?.volume ?? output.volume
        Task { [client] in
            try? await client.setVolume(level, forOutput: output.id)
            await self.refreshOutputs()
        }
    }

    func setMasterVolume(_ value: Double) {
        masterVolume = value
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
        let level = Int(masterVolume.rounded())
        Task { [client] in
            try? await client.setMasterVolume(level)
            await self.refreshPlayer()
        }
    }

    // MARK: - Presentation

    /// The icon for an output: its real hardware when Bonjour has told us,
    /// the coarse guess from the engine's output type otherwise.
    func symbolName(for output: Output) -> String {
        let name = directory.kind(forOutputNamed: output.name)?.symbolName ?? output.symbolName
        return SymbolCatalog.name(name)
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
