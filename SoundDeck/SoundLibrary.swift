import Foundation

enum SoundImportError: LocalizedError {
    case bookmarkFailed(underlying: Error)
    case duplicate(name: String)

    var errorDescription: String? {
        switch self {
        case .bookmarkFailed(let underlying):
            let ns = underlying as NSError
            return "Could not keep access to that file: \(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
        case .duplicate(let name):
            return "“\(name)” is already in the deck."
        }
    }
}

/// Owns the deck: what's in it, its order, and its per-sound settings.
@MainActor
final class SoundLibrary: ObservableObject {
    @Published private(set) var sounds: [SoundItem] = []
    @Published var searchText: String = ""

    private let store = SoundLibraryStore()

    init() {
        if let loaded = store.load() {
            sounds = loaded
        } else {
            loadBundledSounds()
        }
        assignMissingHotKeys()
    }

    /// Libraries written before hotkeys existed — or imported while the keyboard was
    /// full — come back with none. Fill the gaps so every reachable pad has a trigger.
    private func assignMissingHotKeys() {
        var changed = false
        for index in sounds.indices where sounds[index].hotKey == nil {
            guard let key = nextAvailableHotKey() else { break }
            sounds[index].hotKey = key
            changed = true
        }
        // Spread untinted pads across the palette so a fresh deck reads as a deck
        // rather than a wall of identical blue.
        let palette = SoundTint.allCases.filter { $0 != .none }
        for index in sounds.indices where sounds[index].tint == .none {
            sounds[index].tint = palette[index % palette.count]
            changed = true
        }
        if changed { save() }
    }

    var filteredSounds: [SoundItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sounds }
        return sounds.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    // MARK: - Mutation

    @discardableResult
    func addSound(url: URL) throws -> SoundItem {
        let fileName = url.lastPathComponent
        if sounds.contains(where: { !$0.isBundled && $0.name == fileName }) {
            throw SoundImportError.duplicate(name: fileName)
        }
        // The picker hands back a URL whose scope must be open to bookmark it.
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try BookmarkFlavor.create(for: url)
            var item = SoundItem(name: fileName, bookmarkData: bookmark.data, isSecurityScoped: bookmark.isSecurityScoped)
            item.hotKey = nextAvailableHotKey()
            sounds.append(item)
            save()
            return item
        } catch {
            throw SoundImportError.bookmarkFailed(underlying: error)
        }
    }

    /// Imports several files, returning whatever went wrong so the caller can report
    /// partial failure rather than aborting the whole drop.
    func addSounds(urls: [URL]) -> [Error] {
        var failures: [Error] = []
        for url in urls {
            do { try addSound(url: url) } catch { failures.append(error) }
        }
        return failures
    }

    func remove(_ sound: SoundItem) {
        sounds.removeAll { $0.id == sound.id }
        save()
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        sounds.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    /// Reorders by id, which survives filtering — index-based moves do not when a
    /// search is active.
    func move(id: UUID, before targetID: UUID) {
        guard id != targetID,
              let from = sounds.firstIndex(where: { $0.id == id }),
              let to = sounds.firstIndex(where: { $0.id == targetID }) else { return }
        let item = sounds.remove(at: from)
        let insertAt = to > from ? to - 1 : to
        sounds.insert(item, at: insertAt)
        save()
    }

    func update(_ sound: SoundItem, _ mutate: (inout SoundItem) -> Void) {
        guard let index = sounds.firstIndex(where: { $0.id == sound.id }) else { return }
        mutate(&sounds[index])
        save()
    }

    func rename(_ sound: SoundItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        update(sound) { $0.name = trimmed }
    }

    func sound(forHotKey key: String) -> SoundItem? {
        sounds.first { $0.hotKey?.lowercased() == key.lowercased() }
    }

    /// 1-9 then 0, then letters — matching the order the deck is laid out in.
    private func nextAvailableHotKey() -> String? {
        let candidates = (1...9).map(String.init) + ["0"] + "abcdefghijklmnopqrstuvwxyz".map(String.init)
        let taken = Set(sounds.compactMap { $0.hotKey })
        return candidates.first { !taken.contains($0) }
    }

    // MARK: - Resolution

    /// Resolves a sound to a URL, persisting a refreshed bookmark if macOS handed one
    /// back. Callers still own opening the security scope around actual reads.
    func resolve(_ sound: SoundItem) -> SoundResolution? {
        guard let resolution = sound.resolve() else { return nil }
        if let refreshed = resolution.refreshedBookmark,
           let index = sounds.firstIndex(where: { $0.id == sound.id }) {
            sounds[index].bookmarkData = refreshed
            save()
        }
        return resolution
    }

    // MARK: - Persistence

    func save() { store.save(sounds) }

    private func loadBundledSounds() {
        guard let resourceURL = Bundle.main.resourceURL else { return }
        let audioExtensions: Set<String> = ["wav", "aiff", "aif", "mp3", "m4a", "caf"]
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: resourceURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let bundled = files
                .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for (index, file) in bundled.enumerated() {
                var item = SoundItem(name: file.lastPathComponent)
                item.hotKey = index < 9 ? String(index + 1) : (index == 9 ? "0" : nil)
                item.tint = SoundTint.allCases[(index % (SoundTint.allCases.count - 1)) + 1]
                sounds.append(item)
            }
            save()
        } catch {
            print("[DEBUG] Could not load bundled sounds: \(error)")
        }
    }
}
