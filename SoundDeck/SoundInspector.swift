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
    @State private var matchesLoudness = true
    @State private var playMode: PlayMode = .layer
    @State private var chokeGroup = 0
    @State private var ducksOthers = false
    @State private var fadeIn = 0.0
    @State private var fadeOut = SoundItem.defaultFadeOut
    @State private var pitch = 0.0
    @State private var speed = 1.0
    @State private var tint: SoundTint = .none
    @State private var emoji: String = ""
    @State private var hotKey: String = ""

    @State private var samples: [Float]?
    @State private var duration: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var previewError: String?

    private let emojiChoices = ["", "🔔", "💥", "🎺", "🥁", "⚡️", "🎉", "😂", "👏", "🚨", "💧", "🐸", "🎸", "📣", "🛎️"]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            title
            trimSection
            playbackSection
            settingsGrid
            footer
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 460)
        .background(Theme.backdrop)
        .onAppear(perform: load)
    }

    // MARK: Sections

    private var title: some View {
        HStack(spacing: Theme.Spacing.m) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(tint.color.opacity(0.20))
                    .frame(width: 32, height: 32)
                if emoji.isEmpty {
                    Text(sound.initials)
                        .font(Theme.Font.title(.bold))
                        .foregroundStyle(tint.color)
                } else {
                    Text(emoji).font(Theme.Font.title(.regular))
                }
            }
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .font(Theme.Font.title())
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private var trimSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Text("Trim")
                    .font(Theme.Font.caption(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(format(trimStart)) to \(format(trimEnd))  ·  \(format(max(0, trimEnd - trimStart))) long")
                    .font(Theme.Font.caption().monospacedDigit())
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

            HStack(spacing: Theme.Spacing.s) {
                Button("Reset") {
                    trimStart = 0
                    trimEnd = duration
                }
                .buttonStyle(.plain)
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.textTertiary)

                Spacer()

                Button {
                    previewTrimmed()
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "play.fill").font(Theme.Font.caption())
                        Text("Preview").font(Theme.Font.caption(.medium))
                    }
                    .foregroundStyle(Theme.accentBright)
                }
                .buttonStyle(.plain)
            }

            if let previewError {
                Text(previewError)
                    .font(Theme.Font.caption())
                    .foregroundStyle(SoundTint.rose.color)
            }
        }
    }

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Picker("", selection: $playMode) {
                ForEach(PlayMode.allCases) { mode in Text(mode.label).tag(mode) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Play over: each press adds a sound. Restart: plays from the start. Toggle: the next press stops it. Hold: plays while you hold the key.")

            HStack(spacing: Theme.Spacing.l) {
                Picker("Choke group", selection: $chokeGroup) {
                    Text("No group").tag(0)
                    ForEach(1...4, id: \.self) { group in Text("Group \(group)").tag(group) }
                }
                .labelsHidden()
                .frame(width: 110)
                .controlSize(.small)
                .help("A pad stops the other pads in its group.")

                Toggle(isOn: $ducksOthers) {
                    Text("Duck other pads").font(Theme.Font.body())
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(tint.color)
                .help("While this pad plays, the other pads go down by 12 dB.")
            }

            HStack(spacing: Theme.Spacing.l) {
                labeledSlider("Fade in", value: $fadeIn, in: 0...2, text: String(format: "%.2f s", fadeIn))
                labeledSlider("Fade out", value: $fadeOut, in: 0...2, text: String(format: "%.2f s", fadeOut))
            }
            HStack(spacing: Theme.Spacing.l) {
                labeledSlider("Pitch", value: $pitch, in: -12...12, step: 1, text: String(format: "%+.0f st", pitch))
                labeledSlider("Speed", value: $speed, in: 0.5...2, text: String(format: "%.2fx", speed))
            }
        }
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                               step: Double? = nil, text: String) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(title)
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 48, alignment: .leading)
            Group {
                if let step {
                    Slider(value: value, in: range, step: step)
                } else {
                    Slider(value: value, in: range)
                }
            }
            .controlSize(.small)
            .tint(tint.color)
            Text(text)
                .font(Theme.Font.caption().monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var settingsGrid: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(Theme.Font.caption())
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
                    .font(Theme.Font.caption().monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 34, alignment: .trailing)
            }

            HStack(spacing: Theme.Spacing.l) {
                Toggle(isOn: $loops) {
                    Text("Loop").font(Theme.Font.body())
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(tint.color)

                Toggle(isOn: $matchesLoudness) {
                    Text("Match loudness").font(Theme.Font.body())
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(tint.color)
                .help(loudnessHelp)

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

            HStack(spacing: Theme.Spacing.s) {
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
        matchesLoudness = sound.matchesLoudness
        playMode = sound.playMode
        chokeGroup = sound.chokeGroup ?? 0
        ducksOthers = sound.ducksOthers
        fadeIn = sound.fadeIn
        fadeOut = sound.fadeOut
        pitch = sound.pitch
        speed = sound.speed
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
        preview.matchesLoudness = matchesLoudness
        applyPlayback(to: &preview)
        do {
            try engine.play(preview, in: library)
            previewError = nil
        } catch {
            previewError = error.localizedDescription
        }
    }

    private func commit() {
        library.update(sound) { item in
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { item.name = trimmed }
            item.volume = volume
            item.loops = loops
            item.matchesLoudness = matchesLoudness
            applyPlayback(to: &item)
            item.tint = tint
            item.emoji = emoji.isEmpty ? nil : emoji
            item.hotKey = hotKey.isEmpty ? nil : hotKey
            // Before the duration loads, the trim values are not real. Keep the saved trim.
            guard duration > 0 else { return }
            item.trimStart = trimStart
            // Store nil for "to the end" so a re-encode of the same file still works.
            item.trimEnd = (trimEnd >= duration - 0.01) ? nil : trimEnd
        }
        dismiss()
    }

    private func applyPlayback(to item: inout SoundItem) {
        item.playMode = playMode
        item.chokeGroup = chokeGroup == 0 ? nil : chokeGroup
        item.ducksOthers = ducksOthers
        item.fadeIn = fadeIn
        item.fadeOut = fadeOut
        item.pitch = pitch
        item.speed = speed
    }

    /// For example: "-29.1 LUFS. Match loudness adds +11.1 dB."
    private var loudnessHelp: String {
        guard sound.isMeasured else { return "The loudness of this sound is not measured yet." }
        guard let lufs = sound.measuredLoudness else { return "This sound is silent." }
        let gain = 20 * log10(Double(Loudness.gain(lufs: lufs, peak: sound.measuredPeak)))
        return String(format: "%.1f LUFS. Match loudness changes the level by %+.1f dB to %.0f LUFS.",
                      lufs, gain, Loudness.target)
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let whole = Int(seconds)
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, Int((seconds - Double(whole)) * 10))
    }
}
