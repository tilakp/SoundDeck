import SwiftUI

/// Records a new pad from the microphone into the active deck.
struct RecorderSheet: View {
    @ObservedObject var library: SoundLibrary
    let dismiss: () -> Void

    @StateObject private var recorder = Recorder()
    @State private var name = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Record a Sound")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Records from the default input device into “\(library.activeDeck.name)”.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
            }

            HStack(spacing: 14) {
                recordButton
                VStack(alignment: .leading, spacing: 6) {
                    Text(format(recorder.elapsed))
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .foregroundStyle(recorder.isRecording ? Theme.textPrimary : Theme.textSecondary)
                    LevelMeter(level: recorder.level)
                        .frame(height: 6)
                }
            }

            if recorder.recordingURL != nil && !recorder.isRecording {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(SoundTint.rose.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    recorder.discard()
                    dismiss()
                }
                Button("Add to Deck", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(recorder.recordingURL == nil || recorder.isRecording)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Theme.backdrop)
        .onDisappear { if recorder.isRecording { recorder.discard() } }
    }

    private var recordButton: some View {
        Button(action: toggle) {
            ZStack {
                Circle()
                    .fill(Theme.surfaceRaised)
                    .frame(width: 52, height: 52)
                    .overlay(Circle().strokeBorder(Theme.stroke, lineWidth: 1))
                if recorder.isRecording {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(SoundTint.rose.color)
                        .frame(width: 18, height: 18)
                } else {
                    Circle()
                        .fill(SoundTint.rose.color)
                        .frame(width: 22, height: 22)
                }
            }
        }
        .buttonStyle(.plain)
        .help(recorder.isRecording ? "Stop" : "Record")
    }

    private func toggle() {
        errorMessage = nil
        if recorder.isRecording {
            recorder.stop()
            if name.isEmpty { name = "Recording \(library.sounds.count + 1)" }
            return
        }
        Task {
            do {
                try await recorder.start()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func save() {
        guard let url = recorder.recordingURL else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            try library.addRecording(at: url, name: trimmed.isEmpty ? "Recording" : trimmed)
            recorder.release()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func format(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, Int((seconds - Double(whole)) * 10))
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface)
                Capsule()
                    .fill(level > 0.9 ? SoundTint.rose.color : Theme.accent)
                    .frame(width: geometry.size.width * CGFloat(level))
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}
