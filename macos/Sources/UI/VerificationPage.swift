import SwiftUI

/// PIN entry for a device that answers a selection attempt by showing a code on
/// its own screen -- Apple TVs and some receivers require this before they will
/// accept a stream.
///
/// A page in the popover rather than a sheet: a menu bar window cannot host a
/// modal sheet without the popover dismissing out from under it. The page bar
/// above carries the way back; the device name is the title here, since this
/// page is about that one device.
///
/// One field rather than a row of digit boxes: nothing promises the code is
/// four digits long, so the field is sized and centred to read like a code
/// without asserting a length.
struct VerificationPage: View {
    let output: Output
    let errorMessage: String?
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var pin = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(.quaternary)
                    .frame(width: 40, height: 40)
                Image(systemName: "lock.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .padding(.top, 8)

            Text(output.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 4)

            Text("Enter the code shown on its screen. You only need to do this once.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)

            TextField("0000", text: $pin)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .frame(width: 132)
                .focused($isFocused)
                .onSubmit(submit)
                .padding(.top, 8)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 6) {
                Button("Connect", action: submit)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(pin.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 13))
                    .frame(height: 24)
            }
            .padding(.top, 8)
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
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
        errorMessage: nil,
        onSubmit: { _ in },
        onCancel: {}
    )
    .frame(width: Metrics.popoverWidth)
    .padding()
}

#Preview("Rejected code") {
    VerificationPage(
        output: Fixtures.outputs[9],
        errorMessage: "That code was not accepted.",
        onSubmit: { _ in },
        onCancel: {}
    )
    .frame(width: Metrics.popoverWidth)
    .padding()
}
