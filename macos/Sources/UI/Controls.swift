import SwiftUI

enum Metrics {
    static let popoverWidth: CGFloat = 300
    static let horizontalInset: CGFloat = 14
    static let iconWell: CGFloat = 26
    /// Icon well plus the gap after it, so sliders line up under row titles.
    static let rowTextInset: CGFloat = 36
}

/// The circular icon behind each output name.
///
/// Selection is carried entirely by this well being accent-tinted, matching
/// the system Sound menu. No checkmark, no badge.
struct IconWell: View {
    let symbol: String
    let isActive: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        }
        .frame(width: Metrics.iconWell, height: Metrics.iconWell)
    }
}

/// Native `Slider` with SF Symbol end caps. Deliberately not hand-drawn: this
/// is where the system's own knob, keyboard handling and VoiceOver come from.
struct VolumeSlider: View {
    @Binding var value: Double
    var leadingSymbol: String? = "speaker.fill"
    var trailingSymbol: String? = "speaker.wave.3.fill"
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 8) {
            if let leadingSymbol { cap(leadingSymbol) }
            Slider(value: $value, in: 0...100, onEditingChanged: onEditingChanged)
                .controlSize(.small)
            if let trailingSymbol { cap(trailingSymbol) }
        }
    }

    private func cap(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(width: 15)
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

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}
