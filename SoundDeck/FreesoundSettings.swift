import SwiftUI

/// The Freesound tab of the Settings window. The user pastes an API key here.
struct FreesoundSettings: View {
    static let applyURL = URL(string: "https://freesound.org/apiv2/apply")!

    @ObservedObject private var key = FreesoundKey.shared
    @State private var draft = ""

    var body: some View {
        Form {
            Section {
                SecureField("API key", text: $draft, prompt: Text("Paste the key"))
                    .onSubmit(save)
                HStack {
                    LabeledContent("Status", value: key.value == nil ? "No key" : "Key saved")
                    Spacer()
                    Button("Save", action: save)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove") { key.set(""); draft = "" }
                        .disabled(key.value == nil)
                }
            } footer: {
                Text("Sound Deck keeps the key in your keychain.")
            }

            Section {
                Link("Apply for an API key on freesound.org", destination: Self.applyURL)
            } footer: {
                Text("Make a free account, then apply for a key. Use the value of “Client secret/Api key”. Pads get the preview quality, 128 kbps MP3.")
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        key.set(draft)
        draft = ""
    }
}
