import Foundation

/// Persists the sound library as JSON in Application Support.
///
/// This replaces the original `UserDefaults` blob. `UserDefaults` is a preferences
/// store, not a document store: it is cached per-domain, rewritten wholesale on every
/// change. A change to the sandbox status replaces the container.
/// which is exactly how an earlier build appeared to lose its library.
///
/// Writes go through a temporary file and an atomic replace so an interrupted save
/// cannot leave a truncated library behind.
struct SoundLibraryStore {
    /// Bumped when the on-disk shape changes in a way `SoundItem`'s lenient decoding
    /// cannot absorb on its own.
    /// Version 1 has one list of sounds. Version 2 has decks.
    static let currentVersion = 2

    /// The decks and the active deck, as the store reads and writes them.
    struct State: Equatable {
        var decks: [Deck]
        var activeDeckID: UUID
    }

    private struct Payload: Codable {
        var version: Int
        var decks: [Deck]?
        var activeDeckID: UUID?
        /// Version 1 only.
        var sounds: [SoundItem]?
    }

    /// The name of the first deck when the library has no decks yet.
    static let defaultDeckName = "Main"

    private let legacyDefaultsKey = "SoundDeckSounds"
    private let fileManager = FileManager.default

    let directoryURL: URL

    /// Tests give a temporary directory.
    init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.directoryURL = base.appendingPathComponent("SoundDeck", isDirectory: true)
        }
    }

    var fileURL: URL { directoryURL.appendingPathComponent("library.json") }

    /// The copies of imported and recorded sounds, one directory for each pad.
    var soundsDirectoryURL: URL { directoryURL.appendingPathComponent("Sounds", isDirectory: true) }

    func load() -> State? {
        if let data = try? Data(contentsOf: fileURL) {
            do {
                let state = try Self.decode(data)
                print("[DEBUG] Loaded \(state.decks.count) decks from \(fileURL.path)")
                return state
            } catch {
                // Keep the unreadable file. Do not overwrite it. It is the only
                // copy of the user's deck and may be recoverable by hand.
                let salvage = directoryURL.appendingPathComponent("library-corrupt-\(Int(Date().timeIntervalSince1970)).json")
                try? fileManager.moveItem(at: fileURL, to: salvage)
                print("[DEBUG] Library unreadable (\(error)); preserved at \(salvage.lastPathComponent)")
            }
        }
        return migrateFromDefaults()
    }

    /// Reads version 1 and version 2 files. A version 1 file becomes one deck.
    static func decode(_ data: Data) throws -> State {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        var decks = payload.decks ?? []
        if decks.isEmpty {
            decks = [Deck(name: defaultDeckName, sounds: payload.sounds ?? [])]
        }
        let active = payload.activeDeckID.flatMap { id in decks.first { $0.id == id }?.id } ?? decks[0].id
        return State(decks: decks, activeDeckID: active)
    }

    static func encode(_ state: State) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Payload(version: currentVersion, decks: state.decks, activeDeckID: state.activeDeckID))
    }

    func save(_ state: State) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try Self.encode(state)
            let temp = directoryURL.appendingPathComponent("library.json.tmp")
            try data.write(to: temp, options: .atomic)
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: fileURL)
            }
            print("[DEBUG] Saved \(state.decks.count) decks")
        } catch {
            print("[DEBUG] Failed to save library: \(error)")
        }
    }

    /// One-time import of a library written by a pre-Application-Support build.
    private func migrateFromDefaults() -> State? {
        guard let data = UserDefaults.standard.data(forKey: legacyDefaultsKey),
              let sounds = try? JSONDecoder().decode([SoundItem].self, from: data) else {
            return nil
        }
        print("[DEBUG] Migrating \(sounds.count) sounds out of UserDefaults")
        let deck = Deck(name: Self.defaultDeckName, sounds: sounds)
        let state = State(decks: [deck], activeDeckID: deck.id)
        save(state)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        return state
    }
}
