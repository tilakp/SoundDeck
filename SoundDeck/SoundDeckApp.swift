import SwiftUI

@main
struct SoundDeckApp: App {
    // Owned here rather than in ContentView so the menu bar extra and the main window
    // drive the same deck and the same engine.
    @StateObject private var library = SoundLibrary()
    @StateObject private var engine = AudioEngine()

    init() {
        // print() is block-buffered when stdout is a pipe rather than a tty, which
        // swallows debug output when the app is launched from a script.
        setvbuf(stdout, nil, _IONBF, 0)
        GlobalHotKeys.shared.restoreEnabledState()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(library: library, engine: engine)
                .onAppear(perform: rebindGlobalHotKeys)
                .onChange(of: library.sounds) { _, _ in rebindGlobalHotKeys() }
        }
        // Chromeless: the deck draws its own header, so the system title bar would
        // just be a grey band above a dark window.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarDeck(library: library, engine: engine, rebind: rebindGlobalHotKeys)
        } label: {
            // Filled while something is sounding, so the menu bar reflects state.
            Image(systemName: engine.playingIDs.isEmpty ? "waveform" : "waveform.circle.fill")
        }
        .menuBarExtraStyle(.window)
    }

    private func rebindGlobalHotKeys() {
        let bindings: [(key: String, action: () -> Void)] = library.sounds.compactMap { sound in
            guard let key = sound.hotKey else { return nil }
            return (key, { [weak library, weak engine] in
                guard let library, let engine,
                      let current = library.sounds.first(where: { $0.id == sound.id }) else { return }
                try? engine.play(current, in: library)
            })
        }
        GlobalHotKeys.shared.rebind(bindings)
    }
}
