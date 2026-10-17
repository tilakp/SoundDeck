import Combine
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

/// A locked deck refuses a change.
enum DeckLockError: LocalizedError, Equatable {
    case locked(deck: String)

    var errorDescription: String? {
        switch self {
        case .locked(let deck): return "The deck “\(deck)” is locked. Unlock it to make changes."
        }
    }
}

/// A deck that the library makes from the pads of all decks. It is read-only.
enum SmartDeck: String, CaseIterable, Identifiable {
    case favorites, recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favorites: return "Favorites"
        case .recent: return "Recent"
        }
    }

    var symbol: String {
        switch self {
        case .favorites: return "star.fill"
        case .recent: return "clock"
        }
    }
}

/// Owns the decks: what's in them, their order, and their per-sound settings.
@MainActor
final class SoundLibrary: ObservableObject {
    @Published private(set) var decks: [Deck] = []
    @Published private(set) var activeDeckID = UUID()
    @Published var searchText: String = ""
    /// The smart deck that the grid shows, or nil for the active deck.
    /// The keys and the global hotkeys always use `activeDeckID`, the last real deck.
    @Published private(set) var smartDeck: SmartDeck?
    /// The ids of the pads that played last, the most recent first.
    @Published private(set) var recentIDs: [UUID] = []

    nonisolated static let recentLimit = 20

    private let store: SoundLibraryStore
    private let fileManager = FileManager.default
    /// The pads that a background measurement has now. This prevents a second measurement.
    private var measuring: Set<UUID> = []
    private var playObserver: AnyCancellable?

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
            recentIDs = loaded.recentIDs
            if loaded.version < 3 { removeExtensionsFromNames() }
            replaceMissingBundledSounds()
            copyOldImports()
        } else {
            loadBundledSounds()
        }
        assignMissingHotKeys()
        measureMissingLoudness()
    }

    /// Before version 3, a pad showed its file extension. Remove it from each name that the
    /// user did not change. This runs one time: the next save writes version 3.
    private func removeExtensionsFromNames() {
        for deck in decks.indices {
            for index in decks[deck].sounds.indices {
                let sound = decks[deck].sounds[index]
                guard sound.name == sound.fileName else { continue }
                decks[deck].sounds[index].name = SoundItem.displayName(forFileName: sound.fileName)
            }
        }
        save()
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

    /// The pads that the grid shows. A search finds pads in all decks. A smart deck shows
    /// pads from all decks. Else the grid shows the active deck.
    var filteredSounds: [SoundItem] {
        if isSearching { return Self.search(searchText, in: decks, activeDeckID: activeDeckID) }
        switch smartDeck {
        case .favorites: return Self.favorites(in: decks)
        case .recent: return recentIDs.compactMap(sound(withID:))
        case nil: return sounds
        }
    }

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// True when the grid shows pads from more than one deck. Such a view is read-only.
    var showsAllDecks: Bool { isSearching || smartDeck != nil }

    /// The pads whose names contain `query`, from all decks. The pads of the active deck come first.
    static func search(_ query: String, in decks: [Deck], activeDeckID: UUID) -> [SoundItem] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        let ordered = decks.filter { $0.id == activeDeckID } + decks.filter { $0.id != activeDeckID }
        return ordered.flatMap(\.sounds).filter { $0.name.localizedCaseInsensitiveContains(text) }
    }

    /// The favorite pads of all decks, in deck order.
    static func favorites(in decks: [Deck]) -> [SoundItem] {
        decks.flatMap(\.sounds).filter(\.isFavorite)
    }

    /// Puts `id` first in `recent`. It removes an earlier entry of the same id and keeps `limit` ids.
    static func noting(_ id: UUID, in recent: [UUID], limit: Int = recentLimit) -> [UUID] {
        Array(([id] + recent.filter { $0 != id }).prefix(limit))
    }

    /// Records a pad that played. Recent shows it first.
    func noteDidPlay(_ id: UUID) {
        let updated = Self.noting(id, in: recentIDs)
        guard updated != recentIDs else { return }
        recentIDs = updated
        save()
    }

    /// Records each successful play of the engine. `AudioEngine.play` sets `lastPlayedID`
    /// only after the voice starts. Thus every play path counts: keys, menus and remote controls.
    func followPlays(of engine: AudioEngine) {
        playObserver = engine.$lastPlayedID
            .compactMap { $0 }
            .sink { [weak self] id in
                MainActor.assumeIsolated { self?.noteDidPlay(id) }
            }
    }

    /// Shows a smart deck. The active deck does not change, so the keys still play its pads.
    func selectSmartDeck(_ smart: SmartDeck) {
        smartDeck = smart
    }

    /// The name of the deck that holds a pad.
    func deckName(of id: UUID) -> String? {
        locate(id).map { decks[$0.deck].name }
    }

    /// True when the deck that holds the pad is locked.
    func isLocked(_ sound: SoundItem) -> Bool {
        locate(sound.id).map { decks[$0.deck].isLocked } ?? false
    }

    /// The decks that can receive the pad: not its own deck and not a locked deck.
    func moveTargets(for sound: SoundItem) -> [(id: UUID, name: String)] {
        let own = locate(sound.id).map { decks[$0.deck].id }
        return decks.filter { $0.id != own && !$0.isLocked }.map { (id: $0.id, name: $0.name) }
    }

    /// Throws when the active deck is locked. An import goes into the active deck.
    private func checkActiveDeckUnlocked() throws {
        if activeDeck.isLocked { throw DeckLockError.locked(deck: activeDeck.name) }
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
        try checkActiveDeckUnlocked()
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
        // The new pad goes into the active deck. Show that deck, not a smart deck.
        smartDeck = nil
        save()
        measureMissingLoudness()
        return item
    }

    /// Imports several files, returning whatever went wrong so the caller can report
    /// partial failure rather than aborting the whole drop.
    func addSounds(urls: [URL]) -> [Error] {
        // One error for a locked deck, not one for each file.
        do { try checkActiveDeckUnlocked() } catch { return [error] }
        var failures: [Error] = []
        for url in urls {
            do { try addSound(url: url) } catch { failures.append(error) }
        }
        return failures
    }

    /// Moves a recorded file into the library and adds a pad for it to the active deck.
    @discardableResult
    func addRecording(at url: URL, name: String) throws -> SoundItem {
        try checkActiveDeckUnlocked()
        var item = SoundItem(copiedFileName: url.lastPathComponent)
        item.name = name
        do {
            try storeCopy(of: url, for: item, move: true)
        } catch {
            throw SoundImportError.copyFailed(underlying: error)
        }
        item.hotKey = Self.nextAvailableHotKey(in: sounds)
        sounds.append(item)
        smartDeck = nil
        save()
        measureMissingLoudness()
        return item
    }

    /// Returns false when the deck of the pad is locked.
    @discardableResult
    func remove(_ sound: SoundItem) -> Bool {
        guard let location = locate(sound.id), !decks[location.deck].isLocked else { return false }
        let item = decks[location.deck].sounds.remove(at: location.sound)
        deleteCopy(of: item)
        recentIDs.removeAll { $0 == item.id }
        save()
        return true
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard !activeDeck.isLocked, !showsAllDecks else { return }
        sounds.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    /// Reorders by id. An id survives filtering. An index-based move does not
    /// survive filtering when a search is active.
    /// A view of all decks has no order of its own, so it does not reorder.
    func move(id: UUID, before targetID: UUID) {
        guard id != targetID, !activeDeck.isLocked, !showsAllDecks,
              let from = sounds.firstIndex(where: { $0.id == id }),
              let to = sounds.firstIndex(where: { $0.id == targetID }) else { return }
        let item = sounds.remove(at: from)
        let insertAt = to > from ? to - 1 : to
        sounds.insert(item, at: insertAt)
        save()
    }

    /// Changes a pad. A locked deck accepts only a change to `isFavorite`, because a
    /// favorite is a mark for the user and not a change to the deck. Returns false when the deck refuses.
    @discardableResult
    func update(_ sound: SoundItem, _ mutate: (inout SoundItem) -> Void) -> Bool {
        guard let (deck, index) = locate(sound.id) else { return false }
        var changed = decks[deck].sounds[index]
        mutate(&changed)
        if decks[deck].isLocked {
            guard Self.differsOnlyInFavorite(changed, decks[deck].sounds[index]) else { return false }
        }
        decks[deck].sounds[index] = changed
        // A hotkey can trigger only one pad. Remove the key from the other pads.
        if let key = decks[deck].sounds[index].hotKey?.lowercased() {
            for other in decks[deck].sounds.indices
            where other != index && decks[deck].sounds[other].hotKey?.lowercased() == key {
                decks[deck].sounds[other].hotKey = nil
            }
        }
        save()
        return true
    }

    private static func differsOnlyInFavorite(_ changed: SoundItem, _ original: SoundItem) -> Bool {
        var other = changed
        other.isFavorite = original.isFavorite
        return other == original
    }

    @discardableResult
    func rename(_ sound: SoundItem, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return update(sound) { $0.name = trimmed }
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
        measureMissingLoudness()
    }

    /// Makes a deck active. It also leaves a smart deck.
    func selectDeck(_ id: UUID) {
        guard decks.contains(where: { $0.id == id }) else { return }
        smartDeck = nil
        guard id != activeDeckID else { return }
        activeDeckID = id
        save()
    }

    @discardableResult
    func renameDeck(_ id: UUID, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = decks.firstIndex(where: { $0.id == id }),
              !decks[index].isLocked else { return false }
        decks[index].name = trimmed
        save()
        return true
    }

    /// Locks or unlocks a deck. This is the only change that a locked deck accepts.
    func setLocked(_ id: UUID, _ locked: Bool) {
        guard let index = decks.firstIndex(where: { $0.id == id }), decks[index].isLocked != locked else { return }
        decks[index].isLocked = locked
        save()
    }

    /// Removes a deck and the copies of its sounds. The last deck and a locked deck cannot be removed.
    @discardableResult
    func removeDeck(_ id: UUID) -> Bool {
        guard decks.count > 1, let index = decks.firstIndex(where: { $0.id == id }),
              !decks[index].isLocked else { return false }
        let removed = decks.remove(at: index)
        removed.sounds.forEach(deleteCopy)
        let removedIDs = Set(removed.sounds.map(\.id))
        recentIDs.removeAll { removedIDs.contains($0) }
        if activeDeckID == id { activeDeckID = decks[0].id }
        save()
        return true
    }

    /// Moves a pad to the end of another deck. The pad gets a free key in that deck.
    /// Returns false when one of the two decks is locked.
    @discardableResult
    func moveSound(_ sound: SoundItem, toDeck id: UUID) -> Bool {
        guard let (deck, index) = locate(sound.id),
              let target = decks.firstIndex(where: { $0.id == id }), target != deck,
              !decks[deck].isLocked, !decks[target].isLocked else { return false }
        var item = decks[deck].sounds.remove(at: index)
        item.hotKey = Self.nextAvailableHotKey(in: decks[target].sounds)
        decks[target].sounds.append(item)
        save()
        return true
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

    // MARK: - Loudness

    /// Measures each pad that has no measurement, off the main thread. A pad plays at its
    /// user volume until its measurement is ready. A pad whose file is missing stays unmeasured.
    func measureMissingLoudness() {
        let pending = decks.flatMap(\.sounds).filter { !$0.isMeasured && !measuring.contains($0.id) }
        let jobs = pending.compactMap { sound in
            resolve(sound).map { (id: sound.id, url: $0.url, scoped: $0.needsSecurityScope) }
        }
        guard !jobs.isEmpty else { return }
        measuring.formUnion(jobs.map(\.id))
        Task.detached(priority: .utility) { [weak self] in
            var results: [UUID: Loudness.Measurement] = [:]
            for job in jobs {
                let didAccess = job.scoped && job.url.startAccessingSecurityScopedResource()
                defer { if didAccess { job.url.stopAccessingSecurityScopedResource() } }
                do {
                    results[job.id] = try Loudness.measure(url: job.url)
                } catch {
                    print("[DEBUG] Could not measure \(job.url.lastPathComponent): \(error)")
                }
            }
            await self?.applyMeasurements(results, for: jobs.map(\.id))
        }
    }

    private func applyMeasurements(_ results: [UUID: Loudness.Measurement], for ids: [UUID]) {
        measuring.subtract(ids)
        for (id, measurement) in results {
            guard let (deck, index) = locate(id) else { continue }
            decks[deck].sounds[index].measuredLoudness = measurement.lufs
            decks[deck].sounds[index].measuredPeak = measurement.peak
        }
        if !results.isEmpty {
            print("[DEBUG] Measured the loudness of \(results.count) sounds")
            save()
        }
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

    func save() {
        store.save(SoundLibraryStore.State(decks: decks, activeDeckID: activeDeckID, recentIDs: recentIDs))
    }

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
