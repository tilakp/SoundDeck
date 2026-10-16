import Foundation

enum SoundImportError: LocalizedError {
    case copyFailed(underlying: Error)
    case duplicate(name: String)

    var errorDescription: String? {
        switch self {
        case .copyFailed(let underlying):
            let ns = underlying as NSError
            return "Could not copy that file into the library: \(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
        case .duplicate(let name):
            return "“\(name)” is already in the deck."
        }
    }
}

/// Owns the decks: what's in them, their order, and their per-sound settings.
@MainActor
final class SoundLibrary: ObservableObject {
    @Published private(set) var decks: [Deck] = []
    @Published private(set) var activeDeckID = UUID()
    @Published var searchText: String = ""

    private let store: SoundLibraryStore
    private let fileManager = FileManager.default

    /// The pads of the active deck.
    private(set) var sounds: [SoundItem] {
        get { decks[activeIndex].sounds }
        set { decks[activeIndex].sounds = newValue }
    }

    var activeDeck: Deck { decks[activeIndex] }

    private var activeIndex: Int {
        decks.firstIndex { $0.id == activeDeckID } ?? 0
    }

    init(store: SoundLibraryStore = SoundLibraryStore()) {
        self.store = store
        if let loaded = store.load() {
            decks = loaded.decks
            activeDeckID = loaded.activeDeckID
            replaceMissingBundledSounds()
            copyOldImports()
        } else {
            loadBundledSounds()
        }
        assignMissingHotKeys()
    }

    /// Some libraries have no hotkeys. This occurs with a library written before
    /// hotkeys existed, or with an import made while the keyboard was full.
    /// Fill the gaps so that every reachable pad has a trigger.
    private func assignMissingHotKeys() {
        var changed = false
        // Spread untinted pads across the palette so a fresh deck reads as a deck
        // rather than a wall of identical blue.
        let palette = SoundTint.allCases.filter { $0 != .none }
        for deck in decks.indices {
            for index in decks[deck].sounds.indices where decks[deck].sounds[index].hotKey == nil {
                guard let key = Self.nextAvailableHotKey(in: decks[deck].sounds) else { break }
                decks[deck].sounds[index].hotKey = key
                changed = true
            }
            for index in decks[deck].sounds.indices where decks[deck].sounds[index].tint == .none {
                decks[deck].sounds[index].tint = palette[index % palette.count]
                changed = true
            }
        }
        if changed { save() }
    }

    var filteredSounds: [SoundItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sounds }
        return sounds.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// Finds a sound in any deck. A sound in another deck can still play.
    func sound(withID id: UUID) -> SoundItem? {
        locate(id).map { decks[$0.deck].sounds[$0.sound] }
    }

    private func locate(_ id: UUID) -> (deck: Int, sound: Int)? {
        for deck in decks.indices {
            if let sound = decks[deck].sounds.firstIndex(where: { $0.id == id }) {
                return (deck, sound)
            }
        }
        return nil
    }

    // MARK: - Mutation

    /// Copies the file into the library. Thus a moved or deleted original does not break the pad.
    @discardableResult
    func addSound(url: URL) throws -> SoundItem {
        let fileName = url.lastPathComponent
        if sounds.contains(where: { !$0.isBundled && $0.fileName == fileName }) {
            throw SoundImportError.duplicate(name: fileName)
        }
        // The picker hands back a URL whose scope must be open to read it.
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        var item = SoundItem(copiedFileName: fileName)
        do {
            try storeCopy(of: url, for: item, move: false)
        } catch {
            throw SoundImportError.copyFailed(underlying: error)
        }
        item.hotKey = Self.nextAvailableHotKey(in: sounds)
        sounds.append(item)
        save()
        return item
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

    /// Moves a recorded file into the library and adds a pad for it to the active deck.
    @discardableResult
    func addRecording(at url: URL, name: String) throws -> SoundItem {
        var item = SoundItem(copiedFileName: url.lastPathComponent)
        item.name = name
        do {
            try storeCopy(of: url, for: item, move: true)
        } catch {
            throw SoundImportError.copyFailed(underlying: error)
        }
        item.hotKey = Self.nextAvailableHotKey(in: sounds)
        sounds.append(item)
        save()
        return item
    }

    func remove(_ sound: SoundItem) {
        guard let location = locate(sound.id) else { return }
        let item = decks[location.deck].sounds.remove(at: location.sound)
        deleteCopy(of: item)
        save()
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        sounds.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    /// Reorders by id. An id survives filtering. An index-based move does not
    /// survive filtering when a search is active.
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
        guard let (deck, index) = locate(sound.id) else { return }
        mutate(&decks[deck].sounds[index])
        // A hotkey can trigger only one pad. Remove the key from the other pads.
        if let key = decks[deck].sounds[index].hotKey?.lowercased() {
            for other in decks[deck].sounds.indices
            where other != index && decks[deck].sounds[other].hotKey?.lowercased() == key {
                decks[deck].sounds[other].hotKey = nil
            }
        }
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

    /// Uses 1 to 9, then 0, then letters. This matches the layout order of the deck.
    private static func nextAvailableHotKey(in sounds: [SoundItem]) -> String? {
        // Separate statements with types. The Swift 6.1 compiler (Xcode 16) cannot check one long expression in time.
        let digits: [String] = (1...9).map { String($0) } + ["0"]
        let letters: [String] = "abcdefghijklmnopqrstuvwxyz".map { String($0) }
        let candidates = digits + letters
        let taken = Set(sounds.compactMap { $0.hotKey?.lowercased() })
        return candidates.first { !taken.contains($0) }
    }

    // MARK: - Decks

    @discardableResult
    func addDeck(named name: String) -> Deck {
        let deck = Deck(name: uniqueDeckName(name))
        decks.append(deck)
        activeDeckID = deck.id
        save()
        return deck
    }

    /// Adds a deck whose sounds are copies. `files` holds the audio of each sound, by id.
    func addDeck(_ deck: Deck, files: [UUID: Data]) throws {
        var deck = deck
        deck.name = uniqueDeckName(deck.name)
        do {
            for sound in deck.sounds {
                guard let data = files[sound.id] else { continue }
                let target = sound.copyURL(in: store.soundsDirectoryURL)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            }
        } catch {
            deck.sounds.forEach(deleteCopy)
            throw SoundImportError.copyFailed(underlying: error)
        }
        decks.append(deck)
        activeDeckID = deck.id
        save()
    }

    func selectDeck(_ id: UUID) {
        guard id != activeDeckID, decks.contains(where: { $0.id == id }) else { return }
        activeDeckID = id
        save()
    }

    func renameDeck(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = decks.firstIndex(where: { $0.id == id }) else { return }
        decks[index].name = trimmed
        save()
    }

    /// Removes a deck and the copies of its sounds. The last deck cannot be removed.
    func removeDeck(_ id: UUID) {
        guard decks.count > 1, let index = decks.firstIndex(where: { $0.id == id }) else { return }
        let removed = decks.remove(at: index)
        removed.sounds.forEach(deleteCopy)
        if activeDeckID == id { activeDeckID = decks[0].id }
        save()
    }

    /// Moves a pad to the end of another deck. The pad gets a free key in that deck.
    func moveSound(_ sound: SoundItem, toDeck id: UUID) {
        guard let (deck, index) = locate(sound.id),
              let target = decks.firstIndex(where: { $0.id == id }), target != deck else { return }
        var item = decks[deck].sounds.remove(at: index)
        item.hotKey = Self.nextAvailableHotKey(in: decks[target].sounds)
        decks[target].sounds.append(item)
        save()
    }

    /// Adds " 2", " 3" and so on when another deck has the same name.
    private func uniqueDeckName(_ base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let root = trimmed.isEmpty ? "Deck" : trimmed
        let names = Set(decks.map(\.name))
        guard names.contains(root) else { return root }
        var number = 2
        while names.contains("\(root) \(number)") { number += 1 }
        return "\(root) \(number)"
    }

    // MARK: - Copies

    private func storeCopy(of source: URL, for item: SoundItem, move: Bool) throws {
        let target = item.copyURL(in: store.soundsDirectoryURL)
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        if move {
            try fileManager.moveItem(at: source, to: target)
        } else {
            try fileManager.copyItem(at: source, to: target)
        }
    }

    private func deleteCopy(of item: SoundItem) {
        guard item.isCopied else { return }
        try? fileManager.removeItem(at: item.copyURL(in: store.soundsDirectoryURL).deletingLastPathComponent())
    }

    /// Earlier builds kept a bookmark to the original file. Copy each file that the
    /// app can still find. A pad whose file is missing keeps its bookmark.
    private func copyOldImports() {
        var changed = false
        for deck in decks.indices {
            for index in decks[deck].sounds.indices {
                let item = decks[deck].sounds[index]
                guard !item.isBundled, !item.isCopied,
                      let resolution = item.resolve(copies: store.soundsDirectoryURL) else { continue }
                let url = resolution.url
                let didAccess = resolution.needsSecurityScope && url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                var copy = item
                copy.fileName = url.lastPathComponent
                copy.isCopied = true
                do {
                    try storeCopy(of: url, for: copy, move: false)
                } catch {
                    print("[DEBUG] Could not copy \(item.name) into the library: \(error)")
                    continue
                }
                copy.bookmarkData = nil
                copy.isSecurityScoped = false
                decks[deck].sounds[index] = copy
                changed = true
                print("[DEBUG] Copied \(item.name) into the library")
            }
        }
        if changed { save() }
    }

    // MARK: - Resolution

    /// Resolves a sound to a URL, persisting a refreshed bookmark if macOS handed one
    /// back. Callers still own opening the security scope around actual reads.
    func resolve(_ sound: SoundItem) -> SoundResolution? {
        guard let resolution = sound.resolve(copies: store.soundsDirectoryURL) else { return nil }
        if let refreshed = resolution.refreshedBookmark, let (deck, index) = locate(sound.id) {
            decks[deck].sounds[index].bookmarkData = refreshed
            save()
        }
        return resolution
    }

    // MARK: - Persistence

    func save() { store.save(SoundLibraryStore.State(decks: decks, activeDeckID: activeDeckID)) }

    /// The order of the bundled sounds on a new deck. It is the same as the web demo.
    /// A bundled file that is not in this list goes after these files, in name order.
    private static let bundledOrder = [
        "Ba-dum-tss.wav", "Laser.wav", "Glass.wav", "Chime.wav", "Bike bell.wav",
        "Whistle.wav", "Gong.wav", "Sad trombone.wav", "Applause.wav",
    ]

    /// The file names of the bundled sounds, in deck order.
    private func bundledFileNames() -> [String] {
        guard let resourceURL = Bundle.main.resourceURL else { return [] }
        let audioExtensions: Set<String> = ["wav", "aiff", "aif", "mp3", "m4a", "caf"]
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: resourceURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let rank = { (name: String) in Self.bundledOrder.firstIndex(of: name) ?? Self.bundledOrder.count }
            return files
                .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
                .map(\.lastPathComponent)
                .sorted { (rank($0), $0) < (rank($1), $1) }
        } catch {
            print("[DEBUG] Could not load bundled sounds: \(error)")
            return []
        }
    }

    private func loadBundledSounds() {
        var deck = Deck(name: SoundLibraryStore.defaultDeckName)
        for (index, name) in bundledFileNames().enumerated() {
            var item = SoundItem(name: name)
            item.hotKey = index < 9 ? String(index + 1) : (index == 9 ? "0" : nil)
            item.tint = SoundTint.allCases[(index % (SoundTint.allCases.count - 1)) + 1]
            deck.sounds.append(item)
        }
        decks = [deck]
        activeDeckID = deck.id
        save()
    }

    /// An update can remove bundled files. Version 2.0.0 had different bundled sounds.
    /// In each deck, remove the pads of the missing files. Then add the bundled sounds that are not in that deck.
    /// The new pads go first, as on a new deck.
    /// This occurs only when a pad points to a missing file. Thus a sound that the user removed does not come back.
    private func replaceMissingBundledSounds() {
        let names = bundledFileNames()
        guard !names.isEmpty else { return }
        let isMissing = { (item: SoundItem) in item.isBundled && !names.contains(item.fileName) }
        var changed = false
        for deck in decks.indices where decks[deck].sounds.contains(where: isMissing) {
            decks[deck].sounds.removeAll(where: isMissing)
            let present = Set(decks[deck].sounds.filter(\.isBundled).map(\.fileName))
            let added = names.filter { !present.contains($0) }.map { SoundItem(name: $0) }
            decks[deck].sounds.insert(contentsOf: added, at: 0)
            changed = true
        }
        guard changed else { return }
        print("[DEBUG] Replaced missing bundled sounds")
        save()
    }
}
