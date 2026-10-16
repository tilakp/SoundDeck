import SwiftUI

@main
struct SoundDeckApp: App {
    // Owned here rather than in ContentView so the menu bar extra and the main window
    // drive the same deck and the same engine.
    @StateObject private var library: SoundLibrary
    @StateObject private var engine: AudioEngine
    @StateObject private var hotKeys: HotKeyBinder
    // Receives sounddeck:// URLs without a new window.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // print() is block-buffered when stdout is a pipe rather than a tty, which
        // swallows debug output when the app is launched from a script.
        setvbuf(stdout, nil, _IONBF, 0)
        let library: SoundLibrary
        if Self.isRunningTests {
            // The unit tests start the app as their host. Keep the deck of the user out of the
            // tests, and do not register global hotkeys.
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("SoundDeckTestHost-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            library = SoundLibrary(store: SoundLibraryStore(directoryURL: directory))
        } else {
            // Before the binder: it registers the keys at once if the hotkeys are on.
            GlobalHotKeys.shared.restoreEnabledState()
            library = SoundLibrary()
        }
        let engine = AudioEngine()
        _library = StateObject(wrappedValue: library)
        _engine = StateObject(wrappedValue: engine)
        _hotKeys = StateObject(wrappedValue: HotKeyBinder.live(library: library, engine: engine))
        DeckCommands.shared = DeckCommands(library: library, engine: engine)
        let floatingDeck = FloatingDeck(library: library, engine: engine)
        FloatingDeck.shared = floatingDeck
        // Start the remote controls that the user turned on. The test host starts none.
        if !Self.isRunningTests {
            OSCServer.shared.startIfEnabled()
            TwitchChat.shared.restart()
            // Wait for the end of the launch. Then open the floating deck if it was open at the last quit.
            DispatchQueue.main.async { floatingDeck.restore() }
        }
    }

    /// True when the app is the host of the unit tests.
    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var body: some Scene {
        WindowGroup {
            ContentView(library: library, engine: engine)
        }
        // Chromeless: the deck draws its own header, so the system title bar would
        // just be a grey band above a dark window.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .windowArrangement) {
                Button("Floating Deck") { FloatingDeck.shared?.toggle() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView(rebindHotKeys: hotKeys.refresh)
        }

        MenuBarExtra {
            MenuBarDeck(library: library, engine: engine, rebind: hotKeys.refresh)
        } label: {
            // Filled while something is sounding, so the menu bar reflects state.
            // A warning shows that the last play failed. The menu bar deck shows the error.
            Image(systemName: engine.lastError != nil ? "exclamationmark.triangle"
                  : engine.playingIDs.isEmpty ? "waveform" : "waveform.circle.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
