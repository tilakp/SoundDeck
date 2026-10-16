import Foundation

/// One entry point for every remote control of the deck: the URL scheme, Shortcuts,
/// OSC, MIDI, the web remote and Twitch chat.
///
/// A query finds a pad by id, by name or by key. A remote control must not need to know
/// how the library stores pads. Each command triggers through the engine, so the play
/// mode, the choke group and ducking apply as for a key press.
@MainActor
final class DeckCommands {
    /// The instance that the application uses. Tests make their own.
    static var shared: DeckCommands?

    let library: SoundLibrary
    let engine: AudioEngine

    init(library: SoundLibrary, engine: AudioEngine) {
        self.library = library
        self.engine = engine
    }

    /// A pad, as a remote control shows it.
    struct PadInfo: Equatable, Codable {
        let id: UUID
        let name: String
        let key: String?
        let deck: String
        let isPlaying: Bool
    }

    /// Finds a pad. The order is: the id, an exact name in the active deck, an exact name
    /// in another deck, the key in the active deck, then the first name that starts with the query.
    /// Names do not have to match case.
    func sound(matching query: String) -> SoundItem? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let id = UUID(uuidString: text), let sound = library.sound(withID: id) { return sound }
        let active = library.sounds
        let all = library.decks.flatMap(\.sounds)
        let same = { (sound: SoundItem) in sound.name.compare(text, options: .caseInsensitive) == .orderedSame }
        if let sound = active.first(where: same) ?? all.first(where: same) { return sound }
        if text.count == 1, let sound = library.sound(forHotKey: text) { return sound }
        let prefix = { (sound: SoundItem) in sound.name.lowercased().hasPrefix(text.lowercased()) }
        return active.first(where: prefix) ?? all.first(where: prefix)
    }

    /// Triggers a pad. Returns false when no pad matches. A playback error goes to `AudioEngine.lastError`.
    @discardableResult
    func play(_ query: String) -> Bool {
        guard let sound = sound(matching: query) else { return false }
        engine.triggerReportingErrors(sound, in: library)
        return true
    }

    /// Releases a pad. A Hold pad stops.
    @discardableResult
    func release(_ query: String) -> Bool {
        guard let sound = sound(matching: query) else { return false }
        engine.release(sound)
        return true
    }

    /// Stops one pad, or all pads when `query` is nil.
    @discardableResult
    func stop(_ query: String? = nil) -> Bool {
        guard let query else {
            engine.stopAll()
            return true
        }
        guard let sound = sound(matching: query) else { return false }
        engine.stop(sound)
        return true
    }

    /// Makes a deck active, by id or by name. Returns false when no deck matches.
    @discardableResult
    func selectDeck(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let deck = library.decks.first { $0.id.uuidString == text }
            ?? library.decks.first { $0.name.compare(text, options: .caseInsensitive) == .orderedSame }
        guard let deck else { return false }
        library.selectDeck(deck.id)
        return true
    }

    /// The pads of the active deck, or of all decks.
    func pads(allDecks: Bool = false) -> [PadInfo] {
        let decks = allDecks ? library.decks : [library.activeDeck]
        return decks.flatMap { deck in
            deck.sounds.map { sound in
                PadInfo(id: sound.id, name: sound.name, key: sound.hotKey, deck: deck.name,
                        isPlaying: engine.isPlaying(sound))
            }
        }
    }
}
