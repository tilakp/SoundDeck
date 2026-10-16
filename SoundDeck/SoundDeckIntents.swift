import AppIntents
import Foundation

/// Actions for the Shortcuts app. Each action uses `DeckCommands.shared`.

enum DeckIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case noPad(String)
    case noDeck(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: return "Sound Deck is not ready. Open Sound Deck and try again."
        case .noPad(let name): return "No pad has the name \(name)."
        case .noDeck(let name): return "No deck has the name \(name)."
        }
    }
}

@MainActor
private func deckCommands() throws -> DeckCommands {
    guard let commands = DeckCommands.shared else { throw DeckIntentError.notReady }
    return commands
}

/// A pad, as the Shortcuts app shows it.
struct PadEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Pad"
    static var defaultQuery = PadQuery()

    let id: UUID
    let name: String
    let deck: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(deck)")
    }

    init(id: UUID, name: String, deck: String) {
        self.id = id
        self.name = name
        self.deck = deck
    }

    init(_ pad: DeckCommands.PadInfo) {
        self.init(id: pad.id, name: pad.name, deck: pad.deck)
    }
}

/// Lists the pads of all decks.
struct PadQuery: EntityStringQuery {
    /// The pads in `pads` with the given ids, in the order of `ids`.
    static func entities(for ids: [UUID], in pads: [DeckCommands.PadInfo]) -> [PadEntity] {
        ids.compactMap { id in pads.first { $0.id == id }.map(PadEntity.init) }
    }

    /// The pads in `pads` with a name that contains `text`. Case does not matter.
    static func entities(matching text: String, in pads: [DeckCommands.PadInfo]) -> [PadEntity] {
        pads.filter { $0.name.localizedCaseInsensitiveContains(text) }.map(PadEntity.init)
    }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [PadEntity] {
        Self.entities(for: identifiers, in: try deckCommands().pads(allDecks: true))
    }

    @MainActor
    func entities(matching string: String) async throws -> [PadEntity] {
        Self.entities(matching: string, in: try deckCommands().pads(allDecks: true))
    }

    @MainActor
    func suggestedEntities() async throws -> [PadEntity] {
        try deckCommands().pads(allDecks: true).map(PadEntity.init)
    }
}

struct PlayPadIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Pad"
    static var description = IntentDescription("Plays a pad of Sound Deck.")

    @Parameter(title: "Pad")
    var pad: PadEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard try deckCommands().play(pad.id.uuidString) else { throw DeckIntentError.noPad(pad.name) }
        return .result()
    }
}

struct StopPadIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Pad"
    static var description = IntentDescription("Stops a pad of Sound Deck.")

    @Parameter(title: "Pad")
    var pad: PadEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard try deckCommands().stop(pad.id.uuidString) else { throw DeckIntentError.noPad(pad.name) }
        return .result()
    }
}

struct StopAllPadsIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop All Pads"
    static var description = IntentDescription("Stops all pads of Sound Deck.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try deckCommands().stop()
        return .result()
    }
}

struct SelectDeckIntent: AppIntent {
    static var title: LocalizedStringResource = "Select Deck"
    static var description = IntentDescription("Makes a deck of Sound Deck active.")

    @Parameter(title: "Deck Name")
    var deck: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard try deckCommands().selectDeck(deck) else { throw DeckIntentError.noDeck(deck) }
        return .result()
    }
}

struct SoundDeckShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayPadIntent(),
                    phrases: ["Play a pad in \(.applicationName)"],
                    shortTitle: "Play Pad", systemImageName: "play.fill")
        AppShortcut(intent: StopPadIntent(),
                    phrases: ["Stop a pad in \(.applicationName)"],
                    shortTitle: "Stop Pad", systemImageName: "stop.fill")
        AppShortcut(intent: StopAllPadsIntent(),
                    phrases: ["Stop all pads in \(.applicationName)", "Stop \(.applicationName)"],
                    shortTitle: "Stop All Pads", systemImageName: "stop.circle")
        AppShortcut(intent: SelectDeckIntent(),
                    phrases: ["Select a deck in \(.applicationName)"],
                    shortTitle: "Select Deck", systemImageName: "square.stack")
    }
}
