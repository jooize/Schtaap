import Foundation

/// Sample data shaped exactly like the engine's responses, so the UI can be
/// built and previewed without the engine running.
///
/// Launch with `-UseFixtures YES` (or the Xcode scheme argument) to run the
/// whole app against these instead of the network.
enum Fixtures {
    static let outputs: [Output] = [
        make(id: "1", name: "Studio", selected: true, volume: 62),
        make(id: "2", name: "Loft (2)", selected: true, volume: 45),
        make(id: "3", name: "Loft (3)", selected: true, volume: 45),
        make(id: "4", name: "Library", selected: false, volume: 30),
        // Deliberately half-selected, so the degraded stereo-pair row is
        // visible under -UseFixtures without touching real speakers.
        make(id: "5", name: "Den", selected: true, volume: 55),
        make(id: "6", name: "Den (2)", selected: false, volume: 55),
        make(id: "7", name: "Patio", selected: false, volume: 40),
        make(id: "8", name: "Guest Room", selected: false, volume: 25),
        make(id: "9", name: "Loft Apple TV", selected: false, volume: 35),
        make(id: "10", name: "Smart TV", selected: false, volume: 50,
             requiresAuth: true, needsAuthKey: true),
        make(id: "11", name: "MacBook Air", selected: false, volume: 20),
    ]

    /// What a Bonjour browse would report for the outputs above.
    static let deviceIdentities: [String: DeviceIdentity] = [
        "Studio": DeviceIdentity(kind: .homePod),
        "Loft (2)": DeviceIdentity(
            kind: .homePod,
            isStereoPairMember: true,
            groupName: "Loft Apple TV",
            pairID: "A1B2C3D4-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
        ),
        "Loft (3)": DeviceIdentity(
            kind: .homePod,
            isStereoPairMember: true,
            groupName: "Loft Apple TV",
            pairID: "A1B2C3D4-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
        ),
        "Library": DeviceIdentity(kind: .homePodMini),
        "Den": DeviceIdentity(
            kind: .homePodMini,
            isStereoPairMember: true,
            pairID: "E5F6A7B8-1111-2222-3333-444444444444"
        ),
        "Den (2)": DeviceIdentity(
            kind: .homePodMini,
            isStereoPairMember: true,
            pairID: "E5F6A7B8-1111-2222-3333-444444444444"
        ),
        "Patio": DeviceIdentity(kind: .homePodMini),
        "Guest Room": DeviceIdentity(kind: .homePod),
        "Loft Apple TV": DeviceIdentity(kind: .appleTV),
        "Smart TV": DeviceIdentity(kind: .television),
        "MacBook Air": DeviceIdentity(kind: .mac(portable: true)),
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

    private static func make(
        id: String, name: String, selected: Bool, volume: Int,
        requiresAuth: Bool = false, needsAuthKey: Bool = false
    ) -> Output {
        Output(
            id: id,
            name: name,
            type: "AirPlay",
            selected: selected,
            volume: volume,
            hasPassword: false,
            requiresAuth: requiresAuth,
            needsAuthKey: needsAuthKey,
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
        directory.load(Fixtures.deviceIdentities)
    }
}
