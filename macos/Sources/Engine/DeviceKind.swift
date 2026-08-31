import AppKit

/// The hardware behind an AirPlay output.
///
/// Derived from the `model` key in the device's Bonjour TXT record, which the
/// engine reads but never exposes -- it uses the value only to pick protocol
/// quirks (`src/outputs/airplay.c`), and the JSON API drops it. So the app
/// browses for it directly. See `AirPlayDirectory`.
enum DeviceKind: Sendable, Equatable {
    case homePod
    case homePodMini
    case appleTV
    case mac(portable: Bool)
    case television
    case speaker

    /// Apple encodes hardware in `model` the same way it does in `hw.model`:
    /// a family name followed by generation,revision.
    static func from(model: String, manufacturer: String?, integrator: String?) -> DeviceKind {
        if model.hasPrefix("AudioAccessory") {
            // AudioAccessory5,x is the mini; 1,x and 6,x are full size.
            return model.hasPrefix("AudioAccessory5") ? .homePodMini : .homePod
        }
        if model.hasPrefix("AppleTV") { return .appleTV }
        if model.hasPrefix("MacBook") { return .mac(portable: true) }
        if model.hasPrefix("Mac") || model.hasPrefix("iMac") { return .mac(portable: false) }

        // An AirPort Express is an AirPlay speaker as far as anyone using it is
        // concerned, and its own symbol is an unrecognisable brick at row size.
        if model.hasPrefix("AirPort") { return .speaker }

        // Third-party. `integrator` is advertised by the built-into-the-TV
        // AirPlay 2 program (LG, Samsung, Sony, Vizio); third-party speakers
        // generally advertise only `manufacturer`. A heuristic, not a
        // guarantee -- it degrades to a plain speaker, never to a wrong claim.
        let isApple = manufacturer?.hasPrefix("Apple") ?? false
        if !isApple, integrator != nil { return .television }
        return .speaker
    }
}

/// What Bonjour told us about one output: its hardware, whether it is half of
/// a stereo pair, and the name of the group it belongs to.
struct DeviceIdentity: Sendable, Equatable {
    var kind: DeviceKind
    var isStereoPairMember: Bool = false

    /// Set only when the device belongs to a group named something other than
    /// itself -- a HomePod pair adopted into an Apple TV's home theatre, for
    /// instance. Nil for a device that is its own group.
    var groupName: String?

    /// Shared by both halves of a stereo pair (the `tsid` TXT key). Nil for
    /// unpaired speakers or when only one half is visible on the network.
    var pairID: String?

    /// The glyph for one physical unit, ignoring pair membership.
    ///
    /// A merged pair row draws one of these per member rather than the joined
    /// `.2` variant, because only separate glyphs can be tinted separately --
    /// which is how a pair playing on one speaker shows as half-lit.
    var unitSymbolName: String {
        switch kind {
        case .homePod: "homepod.fill"
        case .homePodMini: "homepodmini.fill"
        case .appleTV: "appletv.fill"
        case .mac(let portable): portable ? "laptopcomputer" : "desktopcomputer"
        case .television: "tv.fill"
        case .speaker: "hifispeaker.fill"
        }
    }

    /// The glyph for the device as one thing: a paired speaker gets the joined
    /// two-unit variant where SF Symbols has one.
    var symbolName: String {
        guard isStereoPairMember else { return unitSymbolName }
        switch kind {
        case .homePod: return "homepod.2.fill"
        case .homePodMini: return "homepodmini.2.fill"
        case .speaker: return "hifispeaker.2.fill"
        default: return unitSymbolName
        }
    }
}

/// Symbol names differ across SF Symbols releases, and a missing one renders
/// as an empty box rather than failing loudly. Everything the UI draws goes
/// through here so an unknown name degrades to a generic speaker.
@MainActor
enum SymbolCatalog {
    private static var resolved: [String: String] = [:]

    static func name(_ requested: String, fallback: String = "hifispeaker.fill") -> String {
        if let cached = resolved[requested] { return cached }
        let exists = NSImage(systemSymbolName: requested, accessibilityDescription: nil) != nil
        let value = exists ? requested : fallback
        resolved[requested] = value
        return value
    }
}
