import Foundation
import Network
import Observation

/// Browses `_airplay._tcp` for the TXT records the engine's API does not carry,
/// so each output can be drawn with its actual hardware icon.
///
/// Matched to engine outputs by name: an AirPlay device's Bonjour service name
/// and the name the engine reports are the same string. Any output we do not
/// see keeps the generic icon rather than guessing.
///
/// Browsing prompts for local network access on macOS 15 and later. Declining
/// costs only icon accuracy -- nothing else in the app depends on this.
@MainActor
@Observable
final class AirPlayDirectory {
    private(set) var kinds: [String: DeviceKind] = [:]

    @ObservationIgnored private var browser: NWBrowser?

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

    func kind(forOutputNamed name: String) -> DeviceKind? {
        kinds[name]
    }

    /// Seeds the directory without the network, for fixtures and previews.
    func load(_ kinds: [String: DeviceKind]) {
        self.kinds = kinds
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        var discovered: [String: DeviceKind] = [:]

        for result in results {
            guard
                case .service(let name, _, _, _) = result.endpoint,
                case .bonjour(let txt) = result.metadata,
                let model = txt["model"], !model.isEmpty
            else { continue }

            discovered[name] = DeviceKind.from(
                model: model,
                manufacturer: txt["manufacturer"],
                integrator: txt["integrator"]
            )
        }

        // Replace wholesale: a device that left the network should lose its
        // icon rather than linger.
        kinds = discovered
    }
}
