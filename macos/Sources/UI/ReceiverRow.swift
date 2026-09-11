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
///
/// Unlike a speaker row, a click on the row does nothing: the switch is the
/// only thing that flips whether this Mac appears in Spotify. A row-wide click
/// used to do that too, and got flipped by accident. The name is the one
/// click target, and it is the only thing that lights up on hover, with the
/// pencil, so the click says what it does before it happens: rename.
struct ReceiverRow: View {
    @Binding var name: String
    @Binding var isEditing: Bool
    @Binding var showsInSpotify: Bool
    let subtitle: String
    /// A subtitle that reports a fault (Spotify out of reach) rather than a
    /// state, drawn so it is not mistaken for the usual quiet line.
    var subtitleIsWarning = false
    let symbolName: String
    let onCommit: () -> Void
    /// True while a rename is written down but not applied, because applying
    /// it would disconnect the Spotify client that is using the receiver.
    var isRenamePending = false
    var onRename: () -> Void = {}
    var onCancelRename: () -> Void = {}

    @FocusState private var isFocused: Bool
    @State private var isHoveringName = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                leading

                Toggle("", isOn: $showsInSpotify)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityLabel("Appear in Spotify")
            }

            if isRenamePending {
                pendingRename
            }
        }
        .opacity(showsInSpotify ? 1 : 0.55)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
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

    /// Icon, name and subtitle.
    private var leading: some View {
        HStack(spacing: 10) {
            DeviceIcon(symbol: symbolName, isActive: showsInSpotify)

            VStack(alignment: .leading, spacing: 1) {
                nameField
                // A warning names what to fix and where ("... is off for
                // Schtaap Engine"), which does not fit one line beside the
                // toggle; cutting the name off would cut off the one thing
                // the user needs to find the switch.
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(subtitleIsWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    .lineLimit(subtitleIsWarning ? 2 : 1)
                    .truncationMode(.tail)
                    // Inside an HStack a Text truncates rather than wraps
                    // unless it may take the height it needs.
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)
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
            // The fill and the pencil belong to the name alone, so hovering
            // the row promises nothing and hovering the name promises a
            // rename. The negative padding keeps the text where it sits when
            // nothing is hovered.
            Button { isEditing = true } label: {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isHoveringName {
                        pencil
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(isHoveringName ? 0.08 : 0))
                )
                .padding(.horizontal, -4)
                .padding(.vertical, -2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringName = $0 }
            .help("Rename how this Mac appears in Spotify")
        }
    }

    /// The new name is kept but not applied while a Spotify client is using
    /// the receiver: the restart it takes would drop that client, and the
    /// music with it. A note rather than a warning -- nothing is wrong, the
    /// user simply decides when. It sits under the name, indented past the
    /// icon so it reads as part of this row.
    private var pendingRename: some View {
        HStack(spacing: 8) {
            Text("Renaming disconnects Spotify.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button("Rename", action: onRename)
                .controlSize(.small)
            Button("Cancel", action: onCancelRename)
                .controlSize(.small)
        }
        .padding(.leading, Metrics.iconColumn + 10)
    }

    /// Says the name can be changed, only while the pointer is on it, the
    /// way a speaker row's slider shows up only once it plays. Part of the
    /// name's button, not one of its own.
    private var pencil: some View {
        Image(systemName: "pencil")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
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

#Preview("Rename waiting") {
    ReceiverRow(
        name: .constant("Living Room"),
        isEditing: .constant(false),
        showsInSpotify: .constant(true),
        subtitle: "Connected",
        symbolName: SpotifyDeviceType.advertised.symbolName,
        onCommit: {},
        isRenamePending: true
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
