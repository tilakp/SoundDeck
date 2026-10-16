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
            if library.decks.count > 1 {
                Picker("Deck", selection: Binding(
                    get: { library.activeDeckID },
                    set: { library.selectDeck($0) }
                )) {
                    ForEach(library.decks) { deck in
                        Text(deck.name).tag(deck.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.bottom, Theme.Spacing.s)
            }
            if let error = engine.lastError {
                Text(error)
                    .font(Theme.Font.caption())
                    .foregroundStyle(SoundTint.rose.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.bottom, Theme.Spacing.s)
            }
            Divider().opacity(0.4)
            soundList
            Divider().opacity(0.4)
            controls
        }
        .frame(width: 268)
        .background(Theme.surface)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "waveform")
                .font(Theme.Font.body(.bold))
                .foregroundStyle(Theme.accentBright)
            Text("Sound Deck")
                .font(Theme.Font.body(.bold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if !engine.playingIDs.isEmpty {
                Button {
                    engine.stopAll()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(Theme.Font.caption(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(Theme.Spacing.xs)
                        .background(Circle().fill(Color.white.opacity(0.13)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.m)
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
                        // A menu has no release, so a Hold pad plays to its end here.
                        engine.triggerReportingErrors(sound, in: library)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, Theme.Spacing.xs)
        }
        .frame(maxHeight: 300)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Toggle(isOn: $globalHotKeys) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Global hotkeys")
                        .font(Theme.Font.body(.medium))
                    Text("\(GlobalHotKeys.modifierDescription) + a sound's key, from any app")
                        .font(Theme.Font.caption())
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

            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(Theme.Font.caption())
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
                .font(Theme.Font.caption())
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .font(Theme.Font.caption())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.m)
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
            HStack(spacing: Theme.Spacing.s) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill(sound.tint.color.opacity(isPlaying ? 0.32 : 0.16))
                        .frame(width: 22, height: 22)
                    if let emoji = sound.emoji, !emoji.isEmpty {
                        Text(emoji).font(Theme.Font.caption())
                    } else if isPlaying {
                        PlayingBars(color: sound.tint.color)
                            .scaleEffect(0.75)
                    } else {
                        Text(sound.initials)
                            .font(Theme.Font.caption(.bold))
                            .foregroundStyle(sound.tint.color)
                    }
                }
                Text(sound.name)
                    .font(Theme.Font.padName.weight(.regular))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Spacing.xs)
                if let key = sound.hotKey {
                    KeyCap(key: showsGlobalHint ? "\(GlobalHotKeys.modifierDescription)\(key.uppercased())" : key)
                }
            }
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, Theme.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(hovering ? Theme.surfaceHover : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
