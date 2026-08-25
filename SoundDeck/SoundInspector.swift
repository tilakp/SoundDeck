import AVFoundation
import SwiftUI

/// Per-sound settings: name, trim window, gain, loop, colour, icon and hotkey.
///
/// Trim exists because the useful part of a clip is often two seconds buried inside a
/// thirty second download. Handles are dragged directly on the waveform rather than
/// typed as numbers, which is how every audio tool does it and is far quicker.
struct SoundInspector: View {
    let sound: SoundItem
    @ObservedObject var library: SoundLibrary
    @ObservedObject var engine: AudioEngine
    let dismiss: () -> Void

    @State private var name: String = ""
    @State private var volume: Float = 1
    @State private var loops = false
    @State private var tint: SoundTint = .none
    @State private var emoji: String = ""
    @State private var hotKey: String = ""

    @State private var samples: [Float]?
    @State private var duration: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0

    private let emojiChoices = ["", "🔔", "💥", "🎺", "🥁", "⚡️", "🎉", "😂", "👏", "🚨", "💧", "🐸", "🎸", "📣", "🛎️"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            title
            trimSection
            settingsGrid
            footer
        }
        .padding(20)
        .frame(width: 460)
        .background(Theme.backdrop)
        .onAppear(perform: load)
    }

    // MARK: Sections

    private var title: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.color.opacity(0.20))
                    .frame(width: 32, height: 32)
                if emoji.isEmpty {
                    Text(sound.initials)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(tint.color)
                } else {
                    Text(emoji).font(.system(size: 16))
                }
            }
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private var trimSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Trim")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(format(trimStart)) to \(format(trimEnd))  ·  \(format(max(0, trimEnd - trimStart))) long")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }

            TrimTrack(
                samples: samples,
                duration: duration,
                start: $trimStart,
                end: $trimEnd,
                tint: tint.color
            )
            .frame(height: 66)

            HStack(spacing: 8) {
                Button("Reset") {
                    trimStart = 0
                    trimEnd = duration
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(Theme.textTertiary)

                Spacer()

                Button {
                    previewTrimmed()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.system(size: 9))
                        Text("Preview").font(.system(size: 10.5, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(Theme.accentBright)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var settingsGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 16)
                Slider(value: $volume, in: 0...1)
                    .controlSize(.small)
                    .tint(tint.color)
                    .onChange(of: volume) { _, newValue in
                        // Audible immediately if this sound is already playing.
                        engine.setVolume(newValue, for: sound.id)
                    }
                Text("\(Int(volume * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 34, alignment: .trailing)
            }

            HStack(spacing: 14) {
                Toggle(isOn: $loops) {
                    Text("Loop").font(.system(size: 11.5, design: .rounded))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(tint.color)

                Spacer()

                Picker("", selection: $hotKey) {
                    Text("No key").tag("")
                    ForEach((1...9).map(String.init) + ["0"], id: \.self) { key in
                        Text(key).tag(key)
                    }
                }
                .labelsHidden()
                .frame(width: 78)
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                ForEach(SoundTint.allCases) { option in
                    Button {
                        tint = option
                    } label: {
                        Circle()
                            .fill(option.color)
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle().strokeBorder(.white.opacity(tint == option ? 0.9 : 0), lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(option.label)
                }

                Divider().frame(height: 16).opacity(0.3)

                Picker("", selection: $emoji) {
                    ForEach(emojiChoices, id: \.self) { choice in
                        Text(choice.isEmpty ? "None" : choice).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(width: 74)
                .controlSize(.small)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: dismiss)
            Button("Save", action: commit)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Behaviour

    private func load() {
        name = sound.name
        volume = sound.volume
        loops = sound.loops
        tint = sound.tint
        emoji = sound.emoji ?? ""
        hotKey = sound.hotKey ?? ""

        guard let resolution = library.resolve(sound) else { return }
        let url = resolution.url
        let didAccess = resolution.needsSecurityScope && url.startAccessingSecurityScopedResource()

        let asset = AVAsset(url: url)
        Task {
            let loaded = (try? await asset.load(.duration).seconds) ?? 0
            await MainActor.run {
                duration = loaded
                trimStart = min(sound.trimStart, loaded)
                trimEnd = min(sound.trimEnd ?? loaded, loaded)
            }
            asset.waveformSamples(sampleCount: 400) { values in
                Task { @MainActor in
                    samples = values
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                }
            }
        }
    }

    private func previewTrimmed() {
        var preview = sound
        preview.trimStart = trimStart
        preview.trimEnd = trimEnd
        preview.volume = volume
        preview.loops = false
        try? engine.play(preview, in: library)
    }

    private func commit() {
        library.update(sound) { item in
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { item.name = trimmed }
            item.volume = volume
            item.loops = loops
            item.tint = tint
            item.emoji = emoji.isEmpty ? nil : emoji
            item.hotKey = hotKey.isEmpty ? nil : hotKey
            item.trimStart = trimStart
            // Store nil for "to the end" so a re-encode of the same file still works.
            item.trimEnd = (trimEnd >= duration - 0.01) ? nil : trimEnd
        }
        dismiss()
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let whole = Int(seconds)
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, Int((seconds - Double(whole)) * 10))
    }
}

/// Waveform with two draggable trim handles and a dimmed region outside them.
private struct TrimTrack: View {
    let samples: [Float]?
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let startX = position(start, in: width)
            let endX = position(end, in: width)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.surface)

                Group {
                    if let samples {
                        WaveformView(samples: samples, progress: 0, tint: Theme.textTertiary)
                    } else {
                        WaveformPlaceholder()
                    }
                }
                .padding(.horizontal, 6)

                // Dim everything outside the selection.
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .frame(width: max(0, startX))
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .frame(width: max(0, width - endX))
                    .offset(x: endX)

                Rectangle()
                    .fill(tint.opacity(0.10))
                    .frame(width: max(0, endX - startX))
                    .offset(x: startX)

                handle(at: startX, tint: tint) { newX in
                    start = min(max(0, time(newX, in: width)), max(0, end - 0.05))
                }
                handle(at: endX, tint: tint) { newX in
                    end = max(min(duration, time(newX, in: width)), min(duration, start + 0.05))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )
        }
    }

    private func handle(at x: CGFloat, tint: Color, move: @escaping (CGFloat) -> Void) -> some View {
        Capsule()
            .fill(tint)
            .frame(width: 4)
            .overlay(
                Capsule()
                    .fill(tint)
                    .frame(width: 12)
                    .opacity(0.001) // widen the hit target without showing it
            )
            .shadow(color: tint.opacity(0.7), radius: 4)
            .offset(x: x - 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in move(value.location.x) }
            )
    }

    private func position(_ time: Double, in width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * width
    }

    private func time(_ x: CGFloat, in width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(x / width) * duration
    }
}
