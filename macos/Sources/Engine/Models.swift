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

/// A row in the speaker list: either a single output or a merged stereo pair.
///
/// The engine reports each half of a stereo pair as its own output. This groups
/// them into one row with a single volume slider and toggle.
///
/// Member order is the engine's names sorted: stable, but carrying no channel
/// meaning. Neither `_airplay._tcp` nor `_raop._tcp` advertises which half of a
/// pair is left and which is right -- verified against live HomePod pairs, where
/// `tsid` names the pair and the members' records are otherwise identical. The
/// one per-member key, `pgmid`, appears only inside an Apple TV home-theatre
/// group and indexes position in that group, not a channel. So the UI names the
/// speaker that is playing and never labels one "L" or "R".
struct SpeakerGroup: Identifiable {
    let id: String
    let displayName: String
    let members: [Output]
    /// Glyph for the row taken as one device.
    let symbolName: String
    /// Glyph for a single physical unit. A pair row draws one per member.
    let memberSymbolName: String
    let groupName: String?
    let isPair: Bool

    /// Every member playing.
    var selected: Bool { !members.isEmpty && members.allSatisfy(\.selected) }

    /// At least one member playing. What the row's on/off appearance follows,
    /// so a half-playing pair never looks switched off.
    var anySelected: Bool { members.contains(where: \.selected) }

    /// Some but not all of a pair is playing. The row is on, but the stereo
    /// image its name promises is not what is coming out of the speakers.
    var isPartial: Bool { anySelected && !selected }

    var selectedCount: Int { members.count(where: \.selected) }

    /// Names of the members currently playing, for the degraded subline.
    var selectedMemberNames: [String] { members.filter(\.selected).map(\.name) }

    /// The quietest member, so the slider never claims a level no speaker is at.
    var volume: Int {
        guard let first = members.first else { return 0 }
        return members.dropFirst().reduce(first.volume) { min($0, $1.volume) }
    }
    var needsVerification: Bool { members.contains(where: \.needsVerification) }
    var memberNames: [String] { members.map(\.name) }

    static func derivePairName(from members: [Output]) -> String {
        let stripped = members.map { output -> String in
            if let range = output.name.range(of: #" \(\d+\)$"#, options: .regularExpression) {
                return String(output.name[..<range.lowerBound])
            }
            return output.name
        }
        return stripped.first ?? ""
    }
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
