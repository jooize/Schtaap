import Foundation

/// The kind of device this Mac claims to be in Spotify's device list.
///
/// librespot advertises this as `--device-type`, and it is the whole of what
/// decides the icon Spotify draws beside the name -- there is no artwork to
/// supply and no other hook. So the advertised value and the glyph the popover
/// draws are the same fact, and they live here together rather than in two
/// files that can drift.
///
/// librespot 0.8 also accepts tablet, smartphone, stb, audiodongle,
/// gameconsole, castaudio, castvideo, automobile, smartwatch, chromebook and
/// carthing. None of them describes a Mac feeding a room of speakers, so they
/// are not modelled; add one here when something needs it.
enum SpotifyDeviceType: String, Sendable, CaseIterable {
    case speaker
    case computer
    case tv
    /// An audio/video receiver: what Spotify shows for an amplifier.
    case avr

    /// What this app advertises.
    ///
    /// A speaker, not a computer, because that is what the user is choosing
    /// when they pick it: the Mac is the transport, the speakers are the
    /// point. It is also librespot's own default, so this only makes the
    /// choice explicit -- but explicit is what lets the popover draw the same
    /// icon Spotify will.
    static let advertised: SpotifyDeviceType = .speaker

    /// The closest SF Symbol to what Spotify draws for this type.
    var symbolName: String {
        switch self {
        case .speaker: "hifispeaker.fill"
        case .computer: "desktopcomputer"
        case .tv: "tv.fill"
        case .avr: "hifireceiver.fill"
        }
    }
}
