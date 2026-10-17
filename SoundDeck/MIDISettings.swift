import SwiftUI

/// The MIDI tab of the Settings window.
struct MIDISettings: View {
    @ObservedObject private var midi = MIDIControl.shared

    var body: some View {
        Form {
            Section {
                Toggle("Receive MIDI", isOn: Binding(
                    get: { midi.isEnabled },
                    set: { midi.setEnabled($0) }))
                if let error = midi.error {
                    Text(error).foregroundStyle(.red)
                }
                LabeledContent("Sources") {
                    Text(sourcesText)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Last message") {
                    Text(midi.lastMessage ?? "None")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("Stop All") {
                    MIDITriggerField(owner: "stopAll", trigger: Binding(
                        get: { midi.stopAllTrigger },
                        set: { midi.setStopAllTrigger($0) }))
                }
            } footer: {
                Text("To map a pad, open the pad settings and click Learn in the MIDI row. A note or a controller value of 64 or more plays the pad.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var sourcesText: String {
        guard midi.isEnabled else { return "Off" }
        return midi.sources.isEmpty ? "No MIDI sources" : midi.sources.joined(separator: "\n")
    }
}

/// The current mapping, a Learn button and a Clear button.
/// Learn waits for the next note or controller. The pad inspector and the Settings window use it.
/// The field uses system text styles, because the Settings window can be light.
struct MIDITriggerField: View {
    /// Identifies this field to `MIDILearn`.
    let owner: String
    @Binding var trigger: MIDITrigger?
    var tint: Color = .accentColor

    @ObservedObject private var midi = MIDIControl.shared
    @ObservedObject private var learn = MIDIControl.shared.learn

    private var isLearning: Bool { learn.owner == owner }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.s) {
                Text(isLearning ? "Play a note or move a control" : trigger?.label ?? "None")
                    .font(Theme.Font.body().monospacedDigit())
                    .foregroundStyle(isLearning ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                Spacer(minLength: Theme.Spacing.s)
                Button(isLearning ? "Cancel" : "Learn") {
                    if isLearning {
                        learn.cancel(owner: owner)
                    } else {
                        let binding = $trigger
                        learn.begin(owner: owner) { binding.wrappedValue = $0 }
                    }
                }
                .controlSize(.small)
                .disabled(!midi.isEnabled)
                Button("Clear") { trigger = nil }
                    .controlSize(.small)
                    .disabled(trigger == nil)
            }
            if !midi.isEnabled {
                Text("Turn on MIDI in Settings to learn.")
                    .font(Theme.Font.caption())
                    .foregroundStyle(.tertiary)
            }
        }
        .onDisappear { learn.cancel(owner: owner) }
    }
}
