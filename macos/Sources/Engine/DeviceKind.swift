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
    case airPortExpress
    case mac(portable: Bool)
    case television
    case speaker

    var symbolName: String {
        switch self {
        case .homePod: "homepod.fill"
        case .homePodMini: "homepodmini.fill"
        case .appleTV: "appletv.fill"
        case .airPortExpress: "airport.express"
        case .mac(let portable): portable ? "laptopcomputer" : "desktopcomputer"
        case .television: "tv.fill"
        case .speaker: "hifispeaker.fill"
        }
    }

    /// Apple encodes hardware in `model` the same way it does in
    /// `hw.model`: a family name followed by generation,revision.
    static func from(model: String, manufacturer: String?, integrator: String?) -> DeviceKind {
        if model.hasPrefix("AudioAccessory") {
            // AudioAccessory5,x is the mini; 1,x and 6,x are full size.
            return model.hasPrefix("AudioAccessory5") ? .homePodMini : .homePod
        }
        if model.hasPrefix("AppleTV") { return .appleTV }
        if model.hasPrefix("AirPort") { return .airPortExpress }
        if model.hasPrefix("MacBook") { return .mac(portable: true) }
        if model.hasPrefix("Mac") || model.hasPrefix("iMac") { return .mac(portable: false) }

        // Third-party. `integrator` is advertised by the built-into-the-TV
        // AirPlay 2 program (LG, Samsung, Sony, Vizio); third-party speakers
        // generally advertise only `manufacturer`. A heuristic, not a
        // guarantee -- it degrades to a plain speaker, never to a wrong claim.
        let isApple = manufacturer?.hasPrefix("Apple") ?? false
        if !isApple, integrator != nil { return .television }
        return .speaker
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
