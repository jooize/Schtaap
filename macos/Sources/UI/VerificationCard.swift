import SwiftUI

/// Inline PIN entry for a device that answers a selection attempt by showing a
/// code on its own screen -- Apple TVs and some receivers require this before
/// they will accept a stream.
///
/// Inline rather than a sheet: a menu bar window cannot host a modal sheet
/// without the popover dismissing out from under it.
struct VerificationCard: View {
    let output: Output
    let symbolName: String
    let errorMessage: String?
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var pin = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                IconWell(symbol: symbolName, isActive: false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(output.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("Enter the code shown on this device")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                TextField("0000", text: $pin)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 88)
                    .focused($isFocused)
                    .onSubmit(submit)
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .controlSize(.small)
                Button("Connect", action: submit)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(pin.isEmpty)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quinary)
        )
        .onAppear { isFocused = true }
        .onChange(of: output.id) { _, _ in pin = "" }
    }

    private func submit() {
        let trimmed = pin.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}

#Preview {
    VerificationCard(
        output: Fixtures.outputs[7],
        symbolName: DeviceKind.television.symbolName,
        errorMessage: nil,
        onSubmit: { _ in },
        onCancel: {}
    )
    .frame(width: Metrics.popoverWidth)
    .padding()
}
