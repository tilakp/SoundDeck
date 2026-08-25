import Foundation

/// Persists the sound library as JSON in Application Support.
///
/// This replaces the original `UserDefaults` blob. `UserDefaults` is a preferences
/// store, not a document store: it is cached per-domain, rewritten wholesale on every
/// change, and a sandbox transition silently swaps it for a different container —
/// which is exactly how an earlier build appeared to lose its library.
///
/// Writes go through a temporary file and an atomic replace so an interrupted save
/// cannot leave a truncated library behind.
struct SoundLibraryStore {
    /// Bumped when the on-disk shape changes in a way `SoundItem`'s lenient decoding
    /// cannot absorb on its own.
    static let currentVersion = 1

    private struct Payload: Codable {
        var version: Int
        var sounds: [SoundItem]
    }

    private let legacyDefaultsKey = "SoundDeckSounds"
    private let fileManager = FileManager.default

    var directoryURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SoundDeck", isDirectory: true)
    }

    var fileURL: URL { directoryURL.appendingPathComponent("library.json") }

    func load() -> [SoundItem]? {
        if let data = try? Data(contentsOf: fileURL) {
            do {
                let payload = try JSONDecoder().decode(Payload.self, from: data)
                print("[DEBUG] Loaded \(payload.sounds.count) sounds from \(fileURL.path)")
                return payload.sounds
            } catch {
                // Keep the unreadable file rather than overwriting it — it is the only
                // copy of the user's deck and may be recoverable by hand.
                let salvage = directoryURL.appendingPathComponent("library-corrupt-\(Int(Date().timeIntervalSince1970)).json")
                try? fileManager.moveItem(at: fileURL, to: salvage)
                print("[DEBUG] Library unreadable (\(error)); preserved at \(salvage.lastPathComponent)")
            }
        }
        return migrateFromDefaults()
    }

    func save(_ sounds: [SoundItem]) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Payload(version: Self.currentVersion, sounds: sounds))
            let temp = directoryURL.appendingPathComponent("library.json.tmp")
            try data.write(to: temp, options: .atomic)
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temp)
            print("[DEBUG] Saved \(sounds.count) sounds")
        } catch {
            print("[DEBUG] Failed to save library: \(error)")
        }
    }

    /// One-time import of a library written by a pre-Application-Support build.
    private func migrateFromDefaults() -> [SoundItem]? {
        guard let data = UserDefaults.standard.data(forKey: legacyDefaultsKey),
              let sounds = try? JSONDecoder().decode([SoundItem].self, from: data) else {
            return nil
        }
        print("[DEBUG] Migrating \(sounds.count) sounds out of UserDefaults")
        save(sounds)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        return sounds
    }
}
