import SwiftUI

/// The Settings window (Command-comma).
///
/// Each integration has its own tab in its own file, so that parallel work on
/// different integrations does not change the same lines. A tab that is not built
/// yet shows `SettingsPlaceholder`.
struct SettingsView: View {
    let rebindHotKeys: () -> Void

    var body: some View {
        TabView {
            GeneralSettings(rebindHotKeys: rebindHotKeys)
                .tabItem { Label("General", systemImage: "gearshape") }
            AudioSettings()
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
            MIDISettings()
                .tabItem { Label("MIDI", systemImage: "pianokeys") }
            OSCSettings()
                .tabItem { Label("OSC", systemImage: "network") }
            WebRemoteSettings()
                .tabItem { Label("Web Remote", systemImage: "iphone") }
            TwitchSettings()
                .tabItem { Label("Twitch", systemImage: "bubble.left.and.bubble.right") }
            FreesoundSettings()
                .tabItem { Label("Freesound", systemImage: "magnifyingglass") }
        }
        .frame(width: 520, height: 360)
    }
}

/// Shown by a tab whose integration is not built yet.
struct SettingsPlaceholder: View {
    let name: String

    var body: some View {
        Text("\(name) settings are not available yet.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GeneralSettings: View {
    let rebindHotKeys: () -> Void
    @State private var globalHotKeys = GlobalHotKeys.shared.isEnabled

    var body: some View {
        Form {
            Toggle("Global hotkeys", isOn: $globalHotKeys)
                .onChange(of: globalHotKeys) { _, enabled in
                    GlobalHotKeys.shared.setEnabled(enabled)
                    rebindHotKeys()
                }
            Text("Press \(GlobalHotKeys.modifierDescription) and the key of a pad in any app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
