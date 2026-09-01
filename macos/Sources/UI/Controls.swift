import SwiftUI

enum Metrics {
    static let popoverWidth: CGFloat = 300
    static let horizontalInset: CGFloat = 14
    static let iconColumn: CGFloat = 26
    /// Icon column plus the gap after it, so sliders line up under row titles.
    static let rowTextInset: CGFloat = 36
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
struct VolumeSlider: View {
    @Binding var value: Double
    var leadingSymbol: String? = "speaker.fill"
    var trailingSymbol: String? = "speaker.wave.3.fill"
    var isMuted: Bool = false
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onMuteToggle: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if let _ = leadingSymbol {
                Button {
                    onMuteToggle?()
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : effectiveLeadingSymbol)
                        .font(.system(size: 11))
                        .foregroundStyle(isMuted ? .tertiary : .secondary)
                        .frame(width: 15)
                }
                .buttonStyle(.plain)
                .disabled(onMuteToggle == nil)
            }
            Slider(value: $value, in: 0...100, onEditingChanged: onEditingChanged)
                .controlSize(.small)
                .opacity(isMuted ? 0.4 : 1)
            if let trailingSymbol {
                Image(systemName: trailingSymbol)
                    .font(.system(size: 11))
                    .foregroundStyle(isMuted ? .tertiary : .secondary)
                    .frame(width: 15)
            }
        }
    }

    private var effectiveLeadingSymbol: String {
        leadingSymbol ?? "speaker.fill"
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
