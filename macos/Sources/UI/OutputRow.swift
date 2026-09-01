import SwiftUI

/// One row in the speaker list: a single output or a merged stereo pair.
///
/// Tapping anywhere on the title line toggles it; the volume slider appears
/// once the speaker is playing, matching the system Sound popover.
///
/// A stereo pair is one row with one slider, so it needs to say when it is not
/// actually in stereo. Three things carry that at once: the joined icon splits
/// into its halves and lights only the ones playing, the badge counts them, and
/// the subline names the speaker that has gone quiet.
struct OutputRow: View {
    let group: SpeakerGroup
    var isMuted: Bool = false
    /// What the engine said when it refused to start this speaker. A refusal
    /// leaves the row switched off, so without this the click reads as a
    /// no-op.
    var failure: String?
    @Binding var volume: Double
    let onToggle: () -> Void
    var onVolumeEditingChanged: (Bool) -> Void = { _ in }
    var onMuteToggle: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    SpeakerGroupIcon(group: group)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(group.displayName)
                                .font(.system(size: 13))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if group.isPair {
                                PairBadge(group: group)
                            }
                            if group.isThisMac {
                                RowBadge(text: "This Mac", tint: .secondary)
                            }
                        }
                        subline
                    }
                    Spacer(minLength: 0)
                    if group.needsVerification, !group.anySelected {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .help("This device asks for a code before it will play")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(group.anySelected ? [.isSelected] : [])
            .accessibilityValue(group.isPartial ? Text(partialText) : Text(""))

            if group.anySelected {
                VolumeSlider(
                    value: $volume,
                    isMuted: isMuted,
                    onEditingChanged: onVolumeEditingChanged,
                    onMuteToggle: onMuteToggle
                )
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

    /// One line under the title. Trouble displaces the group name while it
    /// lasts: a speaker that refused to start is the most urgent thing the row
    /// can say, then a pair playing on one half.
    @ViewBuilder
    private var subline: some View {
        if let failure {
            warning(failure)
        } else if group.isPartial {
            warning(partialText)
        } else if let groupName = group.groupName {
            Text("\u{25B8} \(groupName)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(text)
    }

    /// Names the silent speaker in full, rather than calling it L or R: which
    /// half of a pair is left is not something AirPlay tells us, and a name is
    /// the only handle the user has on the thing. See `SpeakerGroup`.
    private var partialText: String {
        let silent = group.silentMemberNames
        if silent.count == 1, let name = silent.first {
            return "\(name) is not playing"
        }
        return "\(group.selectedCount) of \(group.members.count) speakers playing"
    }
}

/// "Stereo" while a pair plays on both speakers, a warning count while it does
/// not. The tint change is what makes the difference readable at 9 points.
private struct PairBadge: View {
    let group: SpeakerGroup

    var body: some View {
        RowBadge(text: label, tint: tint)
    }

    private var label: String {
        group.isPartial ? "\(group.selectedCount) of \(group.members.count)" : "Stereo"
    }

    private var tint: Color {
        group.isPartial ? .orange : .accentColor
    }
}

#Preview("Selected HomePod") {
    OutputRow(
        group: SpeakerGroup(
            id: "1",
            displayName: Fixtures.outputs[0].name,
            members: [Fixtures.outputs[0]],
            symbolName: DeviceIdentity(kind: .homePod).symbolName,
            memberSymbolName: DeviceIdentity(kind: .homePod).unitSymbolName,
            groupName: nil,
            isPair: false
        ),
        volume: .constant(62),
        onToggle: {}
    )
    .frame(width: Metrics.popoverWidth)
    .padding()
}

#Preview("Stereo pair in a group") {
    OutputRow(
        group: SpeakerGroup(
            id: "PAIR",
            displayName: "Loft",
            members: [Fixtures.outputs[1], Fixtures.outputs[2]],
            symbolName: DeviceIdentity(kind: .homePod, isStereoPairMember: true).symbolName,
            memberSymbolName: DeviceIdentity(kind: .homePod).unitSymbolName,
            groupName: "Loft Apple TV",
            isPair: true
        ),
        volume: .constant(45),
        onToggle: {}
    )
    .frame(width: Metrics.popoverWidth)
    .padding()
}

#Preview("Stereo pair, one speaker missing") {
    OutputRow(
        group: SpeakerGroup(
            id: "PAIR",
            displayName: "Den",
            members: [Fixtures.outputs[4], Fixtures.outputs[5]],
            symbolName: DeviceIdentity(kind: .homePodMini, isStereoPairMember: true).symbolName,
            memberSymbolName: DeviceIdentity(kind: .homePodMini).unitSymbolName,
            groupName: nil,
            isPair: true
        ),
        volume: .constant(55),
        onToggle: {}
    )
    .frame(width: Metrics.popoverWidth)
    .padding()
}
