import SwiftUI

/// One speaker. Tapping anywhere on the title line toggles it; the volume
/// slider only appears once the speaker is selected, which is how the system
/// handles multi-output AirPlay.
struct OutputRow: View {
    let output: Output
    @Binding var volume: Double
    let onToggle: () -> Void
    var onVolumeEditingChanged: (Bool) -> Void = { _ in }

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    IconWell(symbol: output.symbolName, isActive: output.selected)
                    Text(output.name)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if output.needsVerification, !output.selected {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .help("This device asks for a code before it will play")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(output.selected ? [.isSelected] : [])

            if output.selected {
                VolumeSlider(value: $volume, onEditingChanged: onVolumeEditingChanged)
                    .padding(.leading, Metrics.rowTextInset)
                    .padding(.trailing, 2)
                    .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.07 : 0))
        )
        .onHover { isHovering = $0 }
    }
}

#Preview("Selected") {
    OutputRow(
        output: Fixtures.outputs[0],
        volume: .constant(62),
        onToggle: {}
    )
    .frame(width: Metrics.popoverWidth)
    .padding()
}

#Preview("Not selected") {
    OutputRow(
        output: Fixtures.outputs[2],
        volume: .constant(30),
        onToggle: {}
    )
    .frame(width: Metrics.popoverWidth)
    .padding()
}
