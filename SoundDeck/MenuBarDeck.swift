import SwiftUI

/// Compact deck for the menu bar, so sounds are reachable without bringing the window
/// forward. This is the usual condition during a call.
struct MenuBarDeck: View {
    @ObservedObject var library: SoundLibrary
    @ObservedObject var engine: AudioEngine
    let rebind: () -> Void

    @State private var globalHotKeys = GlobalHotKeys.shared.isEnabled
    @Environment(\.openSettings) private var openSettings

    static let width: CGFloat = 300
    static let gridMaxHeight: CGFloat = 360

    /// The control that selects the active deck.
    enum DeckPickerStyle: Equatable {
        case none, segmented, menu

        /// Segments fit up to four decks. More decks use a pop-up menu.
        static func forDeckCount(_ count: Int) -> DeckPickerStyle {
            switch count {
            case ..<2: return .none
            case 2...4: return .segmented
            default: return .menu
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if !engine.playingIDs.isEmpty {
                stopBar
            }
            deckPicker
            if let error = engine.lastError {
                Text(error)
                    .font(Theme.Font.caption())
                    .foregroundStyle(SoundTint.rose.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                MiniPadGrid(library: library, engine: engine, showsGlobalHint: globalHotKeys)
            }
            .frame(maxHeight: Self.gridMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.4)
            controls
        }
        .padding(Theme.Spacing.m)
        .frame(width: Self.width)
        .background(Theme.surface)
        .animation(Theme.hover, value: engine.playingIDs.isEmpty)
        .onChange(of: globalHotKeys) { _, enabled in
            GlobalHotKeys.shared.setEnabled(enabled)
            rebind()
        }
    }

    private var stopBar: some View {
        Button {
            engine.stopAll()
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "stop.fill")
                Text(engine.playingIDs.count > 1 ? "Stop All (\(engine.playingIDs.count))" : "Stop")
            }
            .font(Theme.Font.body(.semibold))
            .foregroundStyle(Theme.backdropBottom)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(SoundTint.rose.color)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop all sounds")
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private var deckPicker: some View {
        let selection = Binding(
            get: { library.activeDeckID },
            set: { library.selectDeck($0) }
        )
        switch DeckPickerStyle.forDeckCount(library.decks.count) {
        case .none:
            EmptyView()
        case .segmented:
            Picker("Deck", selection: selection) {
                ForEach(library.decks) { deck in
                    Text(deck.name).tag(deck.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        case .menu:
            Picker("Deck", selection: selection) {
                ForEach(library.decks) { deck in
                    Text(deck.name).tag(deck.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private var controls: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "speaker.wave.2.fill")
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.textTertiary)
            Slider(value: $engine.masterVolume, in: 0...1)
                .controlSize(.mini)
                .tint(Theme.accent)
                .accessibilityLabel("Master volume")
            gearMenu
        }
    }

    private var gearMenu: some View {
        Menu {
            Toggle("Global hotkeys", isOn: $globalHotKeys)
            Text("\(GlobalHotKeys.modifierDescription) + a sound's key, from any app")
            Divider()
            Button("Open Deck") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            }
            Button("Settings…") {
                // Activate first. Otherwise the Settings window opens behind the front app.
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Divider()
            Button("Quit Sound Deck") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(Theme.Font.body())
                .foregroundStyle(Theme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Options")
    }
}
