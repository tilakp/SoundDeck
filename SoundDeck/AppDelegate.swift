import AppKit

/// Receives `sounddeck://` URLs.
///
/// The handler catches the Apple Event directly. `WindowGroup.onOpenURL` can open a new
/// window for each URL. A remote control must not open windows.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Install before launch ends. The event that launches the app arrives after this call.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text) else { return }
        MainActor.assumeIsolated {
            guard let command = DeckURL.command(from: url) else {
                print("[DEBUG] URL: unknown command \(text)")
                return
            }
            guard let commands = DeckCommands.shared else {
                print("[DEBUG] URL: the deck is not ready for \(text)")
                return
            }
            if !DeckURL.run(command, on: commands) {
                print("[DEBUG] URL: no pad or deck matches \(text)")
            }
        }
    }
}
