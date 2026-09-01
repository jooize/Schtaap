import SwiftUI

/// This Mac as Spotify sees it: the icon Spotify will draw, the name it will
/// show, and a switch for whether it appears at all.
///
/// Built from the same parts as a speaker row on purpose. The old header said
/// "Spotify -> HomePods", which read as a destination and so competed with the
/// speaker list underneath it. It never was one: Spotify plays to this Mac,
/// and this Mac plays to whatever is ticked below. Making the receiver a row
/// under its own heading puts the two in signal order, and the topology stops
/// needing to be explained.
struct ReceiverRow: View {
    @Binding var name: String
    @Binding var isEditing: Bool
    @Binding var showsInSpotify: Bool
    let subtitle: String
    let symbolName: String
    let onCommit: () -> Void

    @FocusState private var isFocused: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            DeviceIcon(symbol: symbolName, isActive: showsInSpotify)

            VStack(alignment: .leading, spacing: 1) {
                nameField
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 6)

            Toggle("", isOn: $showsInSpotify)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("Appear in Spotify")
        }
        .opacity(showsInSpotify ? 1 : 0.55)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isHovering && !isEditing ? 0.07 : 0))
        )
        .onHover { isHovering = $0 }
        // The popover commits the name on dismissal and on a tap outside the
        // field, so leaving the field is driven from out here as well as from
        // the focus below.
        .onChange(of: isEditing) { _, editing in
            isFocused = editing
        }
        .onChange(of: isFocused) { _, focused in
            if !focused && isEditing { onCommit() }
        }
    }

    @ViewBuilder
    private var nameField: some View {
        if isEditing {
            TextField(Branding.defaultConnectName, text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .focused($isFocused)
                .onSubmit { onCommit() }
                .onExitCommand { onCommit() }
        } else {
            Button { isEditing = true } label: {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(.plain)
            .help("Rename how this Mac appears in Spotify")
        }
    }
}

#Preview("Appearing") {
    ReceiverRow(
        name: .constant("HomePods"),
        isEditing: .constant(false),
        showsInSpotify: .constant(true),
        subtitle: "on MacBook Pro",
        symbolName: SpotifyDeviceType.advertised.symbolName,
        onCommit: {}
    )
    .frame(width: Metrics.popoverWidth)
    .padding()
}

#Preview("Hidden from Spotify") {
    ReceiverRow(
        name: .constant("HomePods"),
        isEditing: .constant(false),
        showsInSpotify: .constant(false),
        subtitle: "on MacBook Pro",
        symbolName: SpotifyDeviceType.advertised.symbolName,
        onCommit: {}
    )
    .frame(width: Metrics.popoverWidth)
    .padding()
}
