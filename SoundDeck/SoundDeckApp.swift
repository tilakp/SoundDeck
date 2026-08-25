import SwiftUI

@main
struct SoundDeckApp: App {
    init() {
        // print() is block-buffered when stdout is a pipe rather than a tty, which
        // swallows debug output when the app is launched from a script.
        setvbuf(stdout, nil, _IONBF, 0)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Chromeless: the deck draws its own header, so the system title bar would
        // just be a grey band above a dark window.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
