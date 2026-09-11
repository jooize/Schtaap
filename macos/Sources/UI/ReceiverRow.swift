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
/// It behaves like a speaker row too: a click anywhere on it flips whether
/// this Mac appears in Spotify, which is what the hover fill promises all the
/// way down the popover. Renaming is the pencil that appears beside the name
/// on hover, and a click on the name itself.
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
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if isEditing {
                    leading
                } else {
                    Button {
                        showsInSpotify.toggle()
                    } label: {
                        leading.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Appear in Spotify")
                    .accessibilityValue(name)
                    .accessibilityAddTraits(showsInSpotify ? [.isSelected] : [])
                }

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

    /// Icon, name and subtitle: the part of the row that is the click target
    /// when not editing.
    private var leading: some View {
        HStack(spacing: 10) {
            DeviceIcon(symbol: symbolName, isActive: showsInSpotify)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    nameField
                    if isHovering, !isEditing {
                        pencil
                    }
                }
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
            Button { isEditing = true } label: {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(.plain)
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

    /// Says the name can be changed, only while the pointer is on the row,
    /// the way a speaker row's slider shows up only once it plays.
    private var pencil: some View {
        Button { isEditing = true } label: {
            Image(systemName: "pencil")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Rename how this Mac appears in Spotify")
        .accessibilityLabel("Rename")
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
