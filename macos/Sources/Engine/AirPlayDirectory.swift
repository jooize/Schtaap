import Foundation
import Network
import Observation

/// Browses `_airplay._tcp` for the TXT records the engine's API does not carry:
/// each output's hardware model, its stereo-pair membership, and the group it
/// belongs to.
///
/// Matched to engine outputs by name -- an AirPlay device's Bonjour service
/// name and the name the engine reports are the same string. Any output we do
/// not see keeps a generic icon rather than guessing.
///
/// Entirely optional. Browsing prompts for local network access on macOS 15 and
/// later; declining it, or turning the feature off in Settings, costs icons and
/// pair labelling and nothing else. Nothing in playback depends on this.
@MainActor
@Observable
final class AirPlayDirectory {
    private(set) var identities: [String: DeviceIdentity] = [:]

    /// True once a browse has actually returned something, so the UI can tell
    /// "not allowed / not started" apart from "no speakers".
    private(set) var hasResults = false

    @ObservationIgnored private var browser: NWBrowser?

    var isBrowsing: Bool { browser != nil }

    func start() {
        guard browser == nil else { return }

        let parameters = NWParameters()
        parameters.includePeerToPeer = false

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: nil),
            using: parameters
        )

        browser.browseResultsChangedHandler = { results, _ in
            // start(queue: .main) below guarantees this callback is on main.
            MainActor.assumeIsolated { self.apply(results) }
        }

        browser.stateUpdateHandler = { state in
            MainActor.assumeIsolated {
                // Denied permission surfaces here. Stop cleanly and stay in the
                // no-identities state; the UI already handles it.
                if case .failed = state { self.stop() }
            }
        }

        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Drops everything learned and stops browsing, for turning the feature off.
    func reset() {
        stop()
        identities = [:]
        hasResults = false
    }

    func identity(forOutputNamed name: String) -> DeviceIdentity? {
        identities[name]
    }

    /// Seeds the directory without the network, for fixtures and previews.
    func load(_ identities: [String: DeviceIdentity]) {
        self.identities = identities
        hasResults = !identities.isEmpty
    }

    // MARK: - Parsing

    private struct Advertisement {
        var kind: DeviceKind
        /// Stereo-pair id. Shared by both halves of a pair.
        var pairID: String?
        /// Group parent name.
        var groupName: String?
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        var advertised: [String: Advertisement] = [:]

        for result in results {
            guard
                case .service(let name, _, _, _) = result.endpoint,
                case .bonjour(let txt) = result.metadata,
                let model = txt["model"], !model.isEmpty
            else { continue }

            advertised[name] = Advertisement(
                kind: DeviceKind.from(
                    model: model,
                    manufacturer: txt["manufacturer"],
                    integrator: txt["integrator"]
                ),
                pairID: txt["tsid"],
                groupName: txt["gpn"]
            )
        }

        // A pair id is only meaningful when two devices share it. A lone
        // device can carry one -- a speaker that was once half of a pair.
        var pairCounts: [String: Int] = [:]
        for advertisement in advertised.values {
            guard let pairID = advertisement.pairID else { continue }
            pairCounts[pairID, default: 0] += 1
        }

        identities = advertised.mapValues { advertisement in
            let paired = advertisement.pairID.map { (pairCounts[$0] ?? 0) >= 2 } ?? false
            return DeviceIdentity(
                kind: advertisement.kind,
                isStereoPairMember: paired,
                // Every device names its own group; only a name that differs
                // from the device's own tells the user anything.
                groupName: advertisement.groupName
            )
        }

        // Resolve self-named groups now that the whole set is known.
        for (name, identity) in identities where identity.groupName == name {
            identities[name]?.groupName = nil
        }

        hasResults = !identities.isEmpty
    }
}
