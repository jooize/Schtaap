import Foundation

/// One AirPlay (or local) destination as reported by `GET /api/outputs`.
///
/// Field names match the engine's JSON under `convertFromSnakeCase`. The
/// engine always sends the optional fields, but they are modelled as optional
/// so a future version dropping one does not break decoding of the rest.
struct Output: Identifiable, Decodable, Sendable, Hashable {
    let id: String
    let name: String
    let type: String
    var selected: Bool
    var volume: Int
    let hasPassword: Bool?
    let requiresAuth: Bool?
    let needsAuthKey: Bool?
    let format: String?

    /// Matched by prefix: the engine reports "AirPlay 2", not "AirPlay".
    var isAirPlay: Bool { type.lowercased().hasPrefix("airplay") }

    /// The device will not accept a stream until a code shown on its screen is
    /// typed back. The engine sets this after a selection attempt triggers the
    /// device to display a PIN.
    var needsVerification: Bool { needsAuthKey == true }

    /// SF Symbol for the row's icon well. The engine does not tell us which
    /// AirPlay device is a HomePod versus an Apple TV, so this stays generic
    /// until we learn to read the model from the mDNS TXT record.
    var symbolName: String {
        let kind = type.lowercased()
        if kind.hasPrefix("airplay") { return "hifispeaker.fill" }
        if kind.hasPrefix("chromecast") { return "tv.and.hifispeaker.fill" }
        if kind.hasPrefix("fifo") { return "waveform" }
        return "speaker.wave.2.fill"
    }
}

struct OutputsResponse: Decodable, Sendable {
    let outputs: [Output]
}

/// `GET /api/player`.
struct PlayerStatus: Decodable, Sendable, Equatable {
    enum State: String, Decodable, Sendable {
        case play, pause, stop
    }

    let state: State
    let volume: Int
    let itemId: Int
    let itemLengthMs: Int
    let itemProgressMs: Int

    var isPlaying: Bool { state == .play }
}

/// `GET /api/queue/items/now_playing`. Returns 204 with no body when the
/// queue is empty, which the client maps to nil.
///
/// Everything here originates in librespot and reaches the engine through the
/// Shairport-format `.metadata` companion pipe. Until that bridge exists,
/// expect title/artist to be nil on a live engine.
struct NowPlaying: Decodable, Sendable, Equatable {
    let id: Int
    let title: String?
    let artist: String?
    let album: String?
    let lengthMs: Int?
    let artworkUrl: String?
    let dataKind: String?

    var hasMetadata: Bool {
        !(title ?? "").isEmpty || !(artist ?? "").isEmpty
    }
}
