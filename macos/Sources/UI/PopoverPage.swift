import SwiftUI

/// What the popover shows between its persistent header and its footer.
///
/// The app has no windows and no Settings scene, so everything it can do has to
/// happen here. A subpage swaps only the middle section: the connect name gives
/// way to a title and a way back, while now playing and the master volume stay
/// where they were and stay usable.
enum PopoverPage: Equatable {
    case speakers
    case verification(Output)

    /// Nil on the root page, which keeps the connect-name line instead of a
    /// title and a back button.
    var title: String? {
        switch self {
        case .speakers: nil
        case .verification(let output): output.name
        }
    }
}

/// Stands in for the connect-name line while a subpage is open: what you are
/// looking at, and the way back out of it.
struct PageBar: View {
    let title: String
    let onBack: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onBack) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Back to speakers")
    }
}
