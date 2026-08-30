import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 520)
    }
}

struct GeneralSettings: View {
    @AppStorage(PreferenceKey.presenceMode) private var presence: PresenceMode = .menuBarOnly
    @AppStorage(PreferenceKey.connectName) private var connectName: String = Branding.defaultConnectName

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Picker(selection: $presence) {
                    ForEach(PresenceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    Text("Show \(Branding.appName) in")
                }
                .pickerStyle(.radioGroup)

                Text(presence.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } footer: {
                Text("\(Branding.appName) keeps playing in every mode. These options only change where the app is visible.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Start \(Branding.appName) at login", isOn: $launchAtLogin)
                if let loginItemError {
                    Text(loginItemError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                LabeledContent("Name in Spotify") {
                    TextField("", text: $connectName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
                Text("How this Mac appears in the Spotify app's device list.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: presence) { _, mode in
            mode.apply()
        }
        .onChange(of: launchAtLogin) { _, enabled in
            do {
                try LoginItem.setEnabled(enabled)
                loginItemError = nil
            } catch {
                loginItemError = error.localizedDescription
                launchAtLogin = LoginItem.isEnabled
            }
        }
    }
}

#Preview {
    SettingsView()
}
