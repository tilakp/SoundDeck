import SwiftUI

/// The Twitch tab of the Settings window. Viewers type `!sound <pad>` in the chat to play a pad.
struct TwitchSettings: View {
    @ObservedObject private var chat = TwitchChat.shared

    @AppStorage(TwitchChat.Keys.enabled) private var enabled = false
    @AppStorage(TwitchChat.Keys.channel) private var channel = ""
    @AppStorage(TwitchChat.Keys.prefix) private var prefix = "!sound"
    @AppStorage(TwitchChat.Keys.allowAllPads) private var allowAllPads = true
    @AppStorage(TwitchChat.Keys.allowedPads) private var allowedPads = ""
    @AppStorage(TwitchChat.Keys.globalCooldown) private var globalCooldown = 10.0
    @AppStorage(TwitchChat.Keys.userCooldown) private var userCooldown = 30.0
    @AppStorage(TwitchChat.Keys.privilegedOnly) private var privilegedOnly = false

    var body: some View {
        Form {
            Section {
                Toggle("Play pads from Twitch chat", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in chat.restart() }
                TextField("Channel", text: $channel, prompt: Text("channel name"))
                    .onSubmit { chat.restart() }
                LabeledContent("Status", value: chat.state.label)
            } footer: {
                Text("Sound Deck reads the chat anonymously. Press Return after you change the channel.")
            }

            Section("Commands") {
                TextField("Prefix", text: $prefix)
                Picker("Allowed pads", selection: $allowAllPads) {
                    Text("All pads of the active deck").tag(true)
                    Text("Only these pads").tag(false)
                }
                if !allowAllPads {
                    TextField("Pad names", text: $allowedPads, prompt: Text("Gong, Airhorn"))
                }
                Stepper("Global cooldown: \(Int(globalCooldown)) s", value: $globalCooldown, in: 0...600, step: 5)
                Stepper("Cooldown for each viewer: \(Int(userCooldown)) s", value: $userCooldown, in: 0...3600, step: 5)
                Toggle("Subscribers and moderators only", isOn: $privilegedOnly)
            }

            Section("Last triggers") {
                if chat.recentTriggers.isEmpty {
                    Text("No triggers yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(chat.recentTriggers) { trigger in
                        LabeledContent(trigger.user, value: trigger.pad)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
