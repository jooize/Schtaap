import SwiftUI

enum Metrics {
    static let popoverWidth: CGFloat = 300
    static let horizontalInset: CGFloat = 14
    static let iconColumn: CGFloat = 26
    /// Icon column plus the gap after it, so sliders line up under row titles.
    static let rowTextInset: CGFloat = 36
    /// The now-playing slot: a 40-point artwork row, a 16-point scrubber and
    /// a 22-point transport row, 6 points between each. Every other card in
    /// the slot fills the same height, so the popover does not jump when a
    /// track starts.
    static let cardHeight: CGFloat = 90
}

/// The device icon at the head of each row.
///
/// Drawn large and unenclosed rather than shrunk into a filled circle: a
/// HomePod or an Apple TV is recognisable at this size, and the silhouettes
/// carry more meaning than a well does. Selection is the accent tint.
struct DeviceIcon: View {
    let symbol: String
    let isActive: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .frame(width: Metrics.iconColumn, height: 24)
    }
}

/// The icon at the head of a speaker row.
///
/// A pair normally draws as the joined two-unit glyph, because normally it is
/// one thing. It splits into a glyph per member only when it stops behaving
/// like one -- when some of it is playing and some is not. The split is itself
/// half the signal; the tint on each half is the other.
///
/// Left-to-right is the members' sorted order, not their channels: AirPlay does
/// not say which half of a pair is left. See `SpeakerGroup`.
struct SpeakerGroupIcon: View {
    let group: SpeakerGroup

    var body: some View {
        Group {
            if group.isPartial {
                HStack(spacing: 1) {
                    ForEach(group.members) { member in
                        glyph(group.memberSymbolName, size: 14, isActive: member.selected)
                            .help(member.selected ? "\(member.name): playing" : "\(member.name): not playing")
                    }
                }
            } else {
                glyph(group.symbolName, size: 18, isActive: group.selected)
            }
        }
        .frame(width: Metrics.iconColumn, height: 24)
    }

    private func glyph(_ symbol: String, size: CGFloat, isActive: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(inactiveStyle))
    }

    /// A silent speaker inside a row that is otherwise playing recedes further
    /// than one in a row that is simply off, so the gap in a pair is the thing
    /// the eye lands on.
    private var inactiveStyle: HierarchicalShapeStyle {
        group.isPartial ? .quaternary : .secondary
    }
}

/// Native `Slider` with SF Symbol end caps. Deliberately not hand-drawn: this
/// is where the system's own knob, keyboard handling and VoiceOver come from.
/// The Control Center capsule is not a public control, so size is the one
/// lever: the master slider is `.regular`, the per-speaker ones `.small`, and
/// the end caps scale with it.
struct VolumeSlider: View {
    @Binding var value: Double
    var leadingSymbol: String? = "speaker.fill"
    var trailingSymbol: String? = "speaker.wave.3.fill"
    var controlSize: ControlSize = .small
    var isMuted: Bool = false
    /// The master's level, when this slider is one speaker under it. A speaker
    /// below the master gets a tick at the master's level and the headroom in
    /// between filled, so its share of the master is visible on the row; the
    /// speaker at the master's level draws nothing, because it is the master.
    /// See `MasterMark`.
    var markerValue: Double?
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onMuteToggle: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if let _ = leadingSymbol {
                Button {
                    onMuteToggle?()
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : effectiveLeadingSymbol)
                        .font(.system(size: glyphSize))
                        .foregroundStyle(isMuted ? .tertiary : .secondary)
                        .frame(width: glyphSize + 4)
                }
                .buttonStyle(.plain)
                .disabled(onMuteToggle == nil)
            }
            Slider(value: $value, in: 0...100, onEditingChanged: onEditingChanged)
                .controlSize(controlSize)
                .opacity(isMuted ? 0.4 : 1)
                .overlay {
                    if let markerValue, !isMuted, markerValue > value {
                        MasterMark(value: value, marker: markerValue, controlSize: controlSize)
                    }
                }
            if let trailingSymbol {
                Image(systemName: trailingSymbol)
                    .font(.system(size: glyphSize))
                    .foregroundStyle(isMuted ? .tertiary : .secondary)
                    .frame(width: glyphSize + 4)
            }
        }
    }

    private var glyphSize: CGFloat {
        controlSize == .small || controlSize == .mini ? 11 : 13
    }

    private var effectiveLeadingSymbol: String {
        leadingSymbol ?? "speaker.fill"
    }
}

/// The master's level drawn onto a speaker's slider: a tick where the master
/// sits and the track between this speaker's knob and that tick filled in the
/// paler accent. Together they show what a master drag will do to the row: the
/// knob keeps its share of the distance to the tick.
///
/// Drawn only when the speaker is below the master. The loudest speaker is the
/// master by the engine's definition, so its knob would cover the tick anyway;
/// and a lone playing speaker never gets one, because then its slider and the
/// master say the same number twice.
///
/// Laid over the native `Slider`, so the knob geometry is a guess at
/// AppKit's: the knob centre runs from one knob radius in to one radius short
/// of the far end.
private struct MasterMark: View {
    let value: Double
    let marker: Double
    let controlSize: ControlSize

    var body: some View {
        GeometryReader { proxy in
            let usable = proxy.size.width - 2 * knobRadius
            let knobX = knobRadius + usable * value / 100
            let markX = knobRadius + usable * marker / 100
            let start = knobX + knobRadius
            let midY = proxy.size.height / 2

            ZStack(alignment: .leading) {
                if markX > start {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.28))
                        .frame(width: markX - start, height: trackHeight)
                        .position(x: (start + markX) / 2, y: midY)
                }
                Capsule()
                    .fill(Color.accentColor.opacity(0.4))
                    .frame(width: 2, height: 9)
                    .position(x: markX, y: midY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var knobRadius: CGFloat {
        controlSize == .small || controlSize == .mini ? 7.5 : 10
    }

    private var trackHeight: CGFloat {
        controlSize == .small || controlSize == .mini ? 3 : 4
    }
}

/// A menu-style row that highlights on hover, for the popover's footer.
struct MenuRow<Trailing: View>: View {
    let title: String
    var action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                trailing()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// The now-playing card's previous, play/pause and next: a bare glyph at
/// rest, a soft circle under the pointer, darker and a touch smaller while
/// pressed, so a click is seen to land. `.plain` shows none of that.
///
/// The circle is drawn outside the label's frame and takes no layout, so
/// the transport row keeps the height the card is measured for.
struct TransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TransportButtonBody(configuration: configuration)
    }
}

private struct TransportButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    /// How far the circle reaches past the 22-point label.
    private static let halo: CGFloat = 5

    var body: some View {
        configuration.label
            // A custom style draws its own disabled state; SwiftUI dims
            // only the built-in ones.
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .background {
                Circle()
                    .fill(Color.primary.opacity(fillOpacity))
                    .padding(-Self.halo)
            }
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .contentShape(Circle().inset(by: -Self.halo))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var fillOpacity: Double {
        guard isEnabled else { return 0 }
        if configuration.isPressed { return 0.16 }
        return isHovering ? 0.08 : 0
    }
}

extension MenuRow where Trailing == EmptyView {
    init(title: String, action: @escaping () -> Void) {
        self.init(title: title, action: action, trailing: { EmptyView() })
    }
}

/// A small tinted capsule beside a row title, for the one thing about a speaker
/// that its name does not already say.
struct RowBadge: View {
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tint.opacity(0.12))
            )
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}
