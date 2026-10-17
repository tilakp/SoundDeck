import AVFoundation
import SwiftUI

/// Makes a pad that speaks a phrase with a system voice.
///
/// The sheet renders the phrase to a CAF file. "Add to Deck" moves the file into the library.
/// The voices are offline, so the sheet operates without a network connection.
struct SpeechPadSheet: View {
    @ObservedObject var library: SoundLibrary
    let dismiss: () -> Void

    @StateObject private var preview = SpeechPreview()
    @State private var text = ""
    @State private var name = ""
    @State private var nameEdited = false
    @State private var groups: [SpeechVoiceGroup] = []
    @State private var voiceID = ""
    @State private var rate: Float = 0.5
    @State private var pitch: Float = 1
    @State private var renderer: SpeechRenderer?
    @State private var errorMessage: String?

    private var phrase: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isRendering: Bool { renderer != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Speech Pad")
                    .font(Theme.Font.title())
                    .foregroundStyle(Theme.textPrimary)
                Text("Speaks a phrase with a system voice. Adds the pad to “\(library.activeDeck.name)”.")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            textEditor
            voicePicker
            sliders

            TextField("Name", text: Binding(
                get: { name },
                set: {
                    name = $0
                    nameEdited = true
                }
            ))
            .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .font(Theme.Font.caption())
                    .foregroundStyle(SoundTint.rose.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Theme.Spacing.s) {
                previewButton
                Spacer()
                if isRendering {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Cancel") {
                    stopAll()
                    dismiss()
                }
                Button("Add to Deck", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(phrase.isEmpty || isRendering)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 420)
        .background(Theme.backdrop)
        .onAppear(perform: loadVoices)
        .onDisappear(perform: stopAll)
        .onChange(of: text) { _, newValue in
            if newValue.count > SpeechPad.maxTextLength {
                text = String(newValue.prefix(SpeechPad.maxTextLength))
                return
            }
            if !nameEdited { name = SpeechPad.defaultName(for: newValue) }
        }
    }

    private var textEditor: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(Theme.Font.body())
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Spacing.xs)
                if text.isEmpty {
                    Text("Type a phrase, for example “I will be right back.”")
                        .font(Theme.Font.body())
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, Theme.Spacing.s)
                        .padding(.vertical, Theme.Spacing.xs)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 96)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )

            Text("\(text.count) / \(SpeechPad.maxTextLength)")
                .font(Theme.Font.caption().monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var voicePicker: some View {
        Picker("Voice", selection: $voiceID) {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.voices) { voice in
                        Text(voice.label).tag(voice.id)
                    }
                }
            }
        }
        .font(Theme.Font.body())
        .disabled(groups.isEmpty)
    }

    private var sliders: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            labeledSlider("Rate", value: $rate, in: 0...1, text: String(format: "%.2fx", rate * 2))
            labeledSlider("Pitch", value: $pitch, in: 0.5...2, text: String(format: "%.2fx", pitch))
        }
    }

    private func labeledSlider(_ title: String, value: Binding<Float>, in range: ClosedRange<Float>, text: String) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(title)
                .font(Theme.Font.caption(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 44, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.small)
                .tint(Theme.accent)
                .accessibilityLabel(title)
            Text(text)
                .font(Theme.Font.caption().monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var previewButton: some View {
        Button(action: togglePreview) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: preview.isSpeaking ? "stop.fill" : "play.fill")
                    .font(Theme.Font.caption())
                Text(preview.isSpeaking ? "Stop" : "Preview")
                    .font(Theme.Font.caption(.medium))
            }
            .foregroundStyle(Theme.accentBright)
        }
        .buttonStyle(.plain)
        .disabled(phrase.isEmpty || isRendering)
    }

    private func loadVoices() {
        let system = SpeechPad.systemGroups()
        groups = system.groups
        voiceID = system.defaultVoiceID ?? groups.first?.voices.first?.id ?? ""
        if groups.isEmpty { errorMessage = "No system voices are available." }
    }

    private func makeUtterance() -> AVSpeechUtterance {
        SpeechPad.utterance(phrase, voiceID: voiceID.isEmpty ? nil : voiceID, rate: rate, pitch: pitch)
    }

    private func togglePreview() {
        if preview.isSpeaking {
            preview.stop()
        } else {
            preview.speak(makeUtterance())
        }
    }

    private func stopAll() {
        preview.stop()
        renderer?.cancel()
        renderer = nil
    }

    private func save() {
        guard !phrase.isEmpty, !isRendering else { return }
        preview.stop()
        errorMessage = nil
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let padName = trimmed.isEmpty ? SpeechPad.defaultName(for: phrase) : trimmed
        let renderer = SpeechRenderer()
        self.renderer = renderer
        let utterance = makeUtterance()
        Task { @MainActor in
            defer { if self.renderer === renderer { self.renderer = nil } }
            do {
                let url = try await renderer.render(utterance)
                _ = try library.addRecording(at: url, name: padName)
                dismiss()
            } catch SpeechRenderError.cancelled {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Speaks the phrase aloud inside the sheet. It uses the system output device, not the output device of the deck.
@MainActor
private final class SpeechPreview: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ utterance: AVSpeechUtterance) {
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = self.synthesizer.isSpeaking }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = self.synthesizer.isSpeaking }
    }
}
