import SwiftUI

/// Compact deck for the menu bar, so sounds are reachable without bringing the window
/// forward. This is the usual condition during a call.
struct MenuBarDeck: View {
    @ObservedObject var library: SoundLibrary
    @ObservedObject var engine: AudioEngine
    let rebind: () -> Void

    @State private var globalHotKeys = GlobalHotKeys.shared.isEnabled
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            soundList
            Divider().opacity(0.4)
            controls
        }
        .frame(width: 268)
        .background(Theme.surface)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.accentBright)
            Text("Sound Deck")
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if !engine.playingIDs.isEmpty {
                Button {
                    engine.stopAll()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(5)
                        .background(Circle().fill(Color.white.opacity(0.13)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var soundList: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(library.sounds) { sound in
                    MenuBarRow(
                        sound: sound,
                        isPlaying: engine.playingIDs.contains(sound.id),
                        showsGlobalHint: globalHotKeys
                    ) {
                        try? engine.play(sound, in: library)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        .frame(maxHeight: 300)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(isOn: $globalHotKeys) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Global hotkeys")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    Text("\(GlobalHotKeys.modifierDescription) + a sound's key, from any app")
                        .font(.system(size: 9.5, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Theme.accent)
            .onChange(of: globalHotKeys) { _, enabled in
                GlobalHotKeys.shared.setEnabled(enabled)
                rebind()
            }

            HStack(spacing: 7) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                Slider(value: $engine.masterVolume, in: 0...1)
                    .controlSize(.mini)
                    .tint(Theme.accent)
            }

            HStack {
                Button("Open Deck") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
                }
                .font(.system(size: 11, design: .rounded))
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .font(.system(size: 11, design: .rounded))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct MenuBarRow: View {
    let sound: SoundItem
    let isPlaying: Bool
    let showsGlobalHint: Bool
    let play: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: play) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(sound.tint.color.opacity(isPlaying ? 0.32 : 0.16))
                        .frame(width: 22, height: 22)
                    if let emoji = sound.emoji, !emoji.isEmpty {
                        Text(emoji).font(.system(size: 11))
                    } else if isPlaying {
                        PlayingBars(color: sound.tint.color)
                            .scaleEffect(0.75)
                    } else {
                        Text(sound.initials)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(sound.tint.color)
                    }
                }
                Text(sound.name)
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let key = sound.hotKey {
                    KeyCap(key: showsGlobalHint ? "\(GlobalHotKeys.modifierDescription)\(key.uppercased())" : key)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Theme.surfaceHover : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
