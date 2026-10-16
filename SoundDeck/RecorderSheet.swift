import AVFoundation
import SwiftUI

/// Records a new pad from the microphone into the active deck.
///
/// After the recording stops, the sheet shows the waveform with trim handles.
/// "Add to Deck" saves the handle positions as the `trimStart` and `trimEnd` of the new pad.
/// The file itself stays complete, so the user can change the trim later in the inspector.
struct RecorderSheet: View {
    @ObservedObject var library: SoundLibrary
    let dismiss: () -> Void

    @StateObject private var recorder = Recorder()
    @StateObject private var preview = TrimPreview()
    @State private var name = ""
    @State private var errorMessage: String?
    @State private var inputName: String?
    @FocusState private var nameFocused: Bool

    // The trim of the finished recording, in seconds.
    @State private var duration: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var samples: [Float]?

    private var hasRecording: Bool { recorder.recordingURL != nil && !recorder.isRecording }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Record a Sound")
                    .font(Theme.Font.title())
                    .foregroundStyle(Theme.textPrimary)
                Text("Records from \(inputName ?? "the default input device") into “\(library.activeDeck.name)”.")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                LevelMeter(level: recorder.level)
                    .frame(height: 6)

                HStack(spacing: Theme.Spacing.l) {
                    recordButton
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(RecordingTrim.format(recorder.elapsed))
                            .font(Theme.Font.numeral().monospacedDigit())
                            .foregroundStyle(recorder.isRecording ? Theme.textPrimary : Theme.textSecondary)
                        Text(recorder.isRecording ? "Press Space to stop." : "Press Space to record.")
                            .font(Theme.Font.caption())
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }

            if hasRecording {
                trimSection
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(Theme.Font.caption())
                    .foregroundStyle(SoundTint.rose.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    preview.stop()
                    recorder.discard()
                    dismiss()
                }
                Button("Add to Deck", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasRecording)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 380)
        .background(Theme.backdrop)
        .onAppear { inputName = AudioDeviceList.defaultInputDeviceName() }
        .onDisappear {
            preview.stop()
            if recorder.isRecording { recorder.discard() }
        }
    }

    private var recordButton: some View {
        Button(action: toggle) {
            ZStack {
                Circle()
                    .fill(Theme.surfaceRaised)
                    .frame(width: 52, height: 52)
                    .overlay(Circle().strokeBorder(Theme.stroke, lineWidth: 1))
                if recorder.isRecording {
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
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
        // Space types a space in the name field. It starts and stops the recording at all other times.
        .keyboardShortcut(nameFocused ? nil : KeyboardShortcut(.space, modifiers: []))
        .help(recorder.isRecording ? "Stop (Space)" : "Record (Space)")
    }

    private var trimSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Text("Trim")
                    .font(Theme.Font.caption(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(trimSummary)
                    .font(Theme.Font.caption().monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }

            TrimTrack(samples: samples, duration: duration, start: $trimStart, end: $trimEnd, tint: Theme.accent)
                .frame(height: 66)

            HStack(spacing: Theme.Spacing.s) {
                Button("Reset") {
                    trimStart = 0
                    trimEnd = duration
                }
                .buttonStyle(.plain)
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.textTertiary)

                Spacer()

                Button(action: togglePreview) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: preview.isPlaying ? "stop.fill" : "play.fill")
                            .font(Theme.Font.caption())
                        Text(preview.isPlaying ? "Stop" : "Preview")
                            .font(Theme.Font.caption(.medium))
                    }
                    .foregroundStyle(Theme.accentBright)
                }
                .buttonStyle(.plain)
                .disabled(duration <= 0)
            }
        }
    }

    private var trimSummary: String {
        let length = max(0, trimEnd - trimStart)
        return "\(RecordingTrim.format(trimStart)) to \(RecordingTrim.format(trimEnd))  ·  \(RecordingTrim.format(length)) long"
    }

    private func toggle() {
        errorMessage = nil
        preview.stop()
        if recorder.isRecording {
            recorder.stop()
            if name.isEmpty { name = "Recording \(library.sounds.count + 1)" }
            loadRecording()
            return
        }
        duration = 0
        samples = nil
        Task {
            do {
                try await recorder.start()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Reads the duration and the waveform of the finished file for the trim track.
    private func loadRecording() {
        guard let url = recorder.recordingURL else { return }
        // The timer is a good first value. The file gives the exact value.
        duration = recorder.elapsed
        trimStart = 0
        trimEnd = recorder.elapsed

        let asset = AVURLAsset(url: url)
        Task {
            let loaded = (try? await asset.load(.duration).seconds) ?? 0
            await MainActor.run {
                guard recorder.recordingURL == url, loaded.isFinite, loaded > 0 else { return }
                duration = loaded
                trimEnd = loaded
            }
            asset.waveformSamples(sampleCount: 400) { values in
                Task { @MainActor in
                    if recorder.recordingURL == url { samples = values }
                }
            }
        }
    }

    private func togglePreview() {
        if preview.isPlaying {
            preview.stop()
            return
        }
        guard let url = recorder.recordingURL else { return }
        do {
            try preview.play(url, from: trimStart, to: trimEnd)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        guard let url = recorder.recordingURL else { return }
        preview.stop()
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let window = RecordingTrim.window(start: trimStart, end: trimEnd, duration: duration)
        do {
            let item = try library.addRecording(at: url, name: trimmed.isEmpty ? "Recording" : trimmed)
            recorder.release()
            if window.start > 0 || window.end != nil {
                library.update(item) {
                    $0.trimStart = window.start
                    $0.trimEnd = window.end
                }
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Plays the trimmed part of the recording inside the sheet.
///
/// It uses its own `AVAudioPlayer`, so it does not change `AudioEngine`. The player uses
/// the system output device, not the output device of the deck.
@MainActor
private final class TrimPreview: ObservableObject {
    @Published private(set) var isPlaying = false

    private var player: AVAudioPlayer?
    private var stopTimer: Timer?

    func play(_ url: URL, from start: Double, to end: Double) throws {
        stop()
        let player = try AVAudioPlayer(contentsOf: url)
        player.currentTime = max(0, start)
        guard player.play() else { return }
        self.player = player
        isPlaying = true
        stopTimer = Timer.scheduledTimer(withTimeInterval: max(0, end - start), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    func stop() {
        stopTimer?.invalidate()
        stopTimer = nil
        player?.stop()
        player = nil
        isPlaying = false
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
