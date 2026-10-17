import SwiftUI

/// The Settings window (Command-comma).
///
/// Each integration has its own tab in its own file, so that parallel work on
/// different integrations does not change the same lines. A tab that is not built
/// yet shows `SettingsPlaceholder`.
struct SettingsView: View {
    let rebindHotKeys: () -> Void

    /// The tab names. Another view can set `selectedTabKey` before it opens Settings,
    /// to show a given tab.
    enum Tab: String {
        case general, audio, midi, osc, webRemote, twitch, freesound
    }

    static let selectedTabKey = "settingsSelectedTab"

    @AppStorage(SettingsView.selectedTabKey) private var selection = Tab.general.rawValue

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettings(rebindHotKeys: rebindHotKeys)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general.rawValue)
            AudioSettings()
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
                .tag(Tab.audio.rawValue)
            MIDISettings()
                .tabItem { Label("MIDI", systemImage: "pianokeys") }
                .tag(Tab.midi.rawValue)
            OSCSettings()
                .tabItem { Label("OSC", systemImage: "network") }
                .tag(Tab.osc.rawValue)
            WebRemoteSettings()
                .tabItem { Label("Web Remote", systemImage: "iphone") }
                .tag(Tab.webRemote.rawValue)
            TwitchSettings()
                .tabItem { Label("Twitch", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.twitch.rawValue)
            FreesoundSettings()
                .tabItem { Label("Freesound", systemImage: "magnifyingglass") }
                .tag(Tab.freesound.rawValue)
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
