import Foundation

/// Reads a `sounddeck://` URL.
///
/// The forms are:
/// - `sounddeck://play/<pad>`
/// - `sounddeck://release/<pad>`
/// - `sounddeck://stop` stops all pads.
/// - `sounddeck://stop/<pad>`
/// - `sounddeck://deck/<deck>`
///
/// `<pad>` is a percent-encoded name, id or key. `DeckCommands` finds the pad.
enum DeckURL {
    static let scheme = "sounddeck"

    enum Command: Equatable {
        case play(String)
        case release(String)
        /// Nil stops all pads.
        case stop(String?)
        case deck(String)
    }

    /// Returns nil when the URL is not a known command.
    static func command(from url: URL) -> Command? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              let host = components.host?.lowercased() else { return nil }
        // Decode after the first slash is gone, so that "%2F" in a name stays in the name.
        let encoded = components.percentEncodedPath.hasPrefix("/")
            ? String(components.percentEncodedPath.dropFirst())
            : components.percentEncodedPath
        let argument = (encoded.removingPercentEncoding ?? encoded)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = argument.isEmpty ? nil : argument
        switch host {
        case "play": return value.map(Command.play)
        case "release": return value.map(Command.release)
        case "stop": return .stop(value)
        case "deck": return value.map(Command.deck)
        default: return nil
        }
    }

    /// Runs a command. Returns false when no pad or deck matches.
    @MainActor
    @discardableResult
    static func run(_ command: Command, on commands: DeckCommands) -> Bool {
        switch command {
        case .play(let pad): return commands.play(pad)
        case .release(let pad): return commands.release(pad)
        case .stop(let pad): return commands.stop(pad)
        case .deck(let name): return commands.selectDeck(name)
        }
    }
}
