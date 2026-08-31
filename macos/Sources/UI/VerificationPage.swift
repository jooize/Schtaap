import SwiftUI

/// PIN entry for a device that answers a selection attempt by showing a code on
/// its own screen -- Apple TVs and some receivers require this before they will
/// accept a stream.
///
/// A page in the popover rather than a sheet: a menu bar window cannot host a
/// modal sheet without the popover dismissing out from under it. The page bar
/// above carries the device name and the way back, so neither is repeated here.
struct VerificationPage: View {
    let output: Output
    let symbolName: String
    let errorMessage: String?
    let onSubmit: (String) -> Void

    @State private var pin = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                DeviceIcon(symbol: symbolName, isActive: false)
                Text("Enter the code shown on this device.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                TextField("0000", text: $pin)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 88)
                    .focused($isFocused)
                    .onSubmit(submit)
                Spacer(minLength: 0)
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
    VerificationPage(
        output: Fixtures.outputs[9],
        symbolName: DeviceIdentity(kind: .television).symbolName,
        errorMessage: nil,
        onSubmit: { _ in }
    )
    .frame(width: Metrics.popoverWidth)
    .padding()
}
