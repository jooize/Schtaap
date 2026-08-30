import Foundation

/// Sample data shaped exactly like the engine's responses, so the UI can be
/// built and previewed without the engine running.
///
/// Launch with `-UseFixtures YES` (or the Xcode scheme argument) to run the
/// whole app against these instead of the network.
enum Fixtures {
    static let outputs: [Output] = [
        make(id: "1", name: "Kitchen", selected: true, volume: 62),
        make(id: "2", name: "Living Room", selected: true, volume: 45),
        make(id: "3", name: "The Office", selected: false, volume: 30),
        make(id: "4", name: "Goober's Room", selected: false, volume: 55),
        make(id: "5", name: "Pantry", selected: false, volume: 40),
        make(id: "6", name: "Bedroom", selected: false, volume: 25),
    ]

    static let player = PlayerStatus(
        state: .play,
        volume: 58,
        itemId: 1,
        itemLengthMs: 230_000,
        itemProgressMs: 74_000
    )

    static let nowPlaying = NowPlaying(
        id: 1,
        title: "Dancing Queen",
        artist: "ABBA",
        album: "Arrival",
        lengthMs: 230_000,
        artworkUrl: nil,
        dataKind: "pipe"
    )

    private static func make(id: String, name: String, selected: Bool, volume: Int) -> Output {
        Output(
            id: id,
            name: name,
            type: "AirPlay",
            selected: selected,
            volume: volume,
            hasPassword: false,
            requiresAuth: false,
            needsAuthKey: false,
            format: "alac"
        )
    }
}

extension EngineStore {
    /// Whether this launch was asked to run without an engine.
    static var fixturesRequested: Bool {
        UserDefaults.standard.bool(forKey: "UseFixtures")
    }

    static func preview() -> EngineStore {
        let store = EngineStore(usesFixtures: true)
        store.start()
        return store
    }

    func applyFixtures() {
        load(outputs: Fixtures.outputs, player: Fixtures.player, nowPlaying: Fixtures.nowPlaying)
    }
}
