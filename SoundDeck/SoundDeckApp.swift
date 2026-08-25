import SwiftUI
import AVFoundation

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
    }
}
