import Foundation
import Testing
@testable import SoundDeck

/// Gives each test its own library directory.
private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SoundDeckTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes a short audio file. The library only copies it, so the content is not important.
private func makeAudioFile(named name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data("RIFF test audio".utf8).write(to: url)
    return url
}

private func pad(_ name: String, favorite: Bool = false) -> SoundItem {
    var item = SoundItem(copiedFileName: "\(name).wav")
    item.isFavorite = favorite
    return item
}

@MainActor
struct DeckLockTests {
    /// A library with a deck "Show" that holds the pads "Horn" and "Bell". "Show" is active.
    private func makeLibrary() throws -> (SoundLibrary, URL) {
        let directory = try temporaryDirectory()
        let library = SoundLibrary(store: SoundLibraryStore(directoryURL: directory))
        library.addDeck(named: "Show")
        try library.addSound(url: makeAudioFile(named: "Horn.wav", in: directory))
        try library.addSound(url: makeAudioFile(named: "Bell.wav", in: directory))
        return (library, directory)
    }

    @Test func lockedDeckRefusesChanges() throws {
        let (library, directory) = try makeLibrary()
        let show = library.activeDeck
        let other = try #require(library.decks.first { $0.id != show.id })
        let horn = show.sounds[0]
        let bell = show.sounds[1]
        library.setLocked(show.id, true)
        #expect(library.activeDeck.isLocked)

        #expect(throws: DeckLockError.locked(deck: "Show")) {
            try library.addSound(url: makeAudioFile(named: "Drum.wav", in: directory))
        }
        let failures = library.addSounds(urls: [try makeAudioFile(named: "A.wav", in: directory),
                                                try makeAudioFile(named: "B.wav", in: directory)])
        #expect(failures.count == 1)
        #expect(throws: DeckLockError.self) {
            try library.addRecording(at: makeAudioFile(named: "Take.wav", in: directory), name: "Take")
        }
        #expect(!library.remove(horn))
        #expect(!library.rename(horn, to: "Klaxon"))
        #expect(!library.update(horn) { $0.volume = 0.2 })
        library.move(id: bell.id, before: horn.id)
        library.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(!library.moveSound(horn, toDeck: other.id))
        #expect(!library.renameDeck(show.id, to: "Gig"))
        #expect(!library.removeDeck(show.id))

        // Nothing changed.
        #expect(library.activeDeck == Deck.lockedCopy(of: show))

        // A pad of another deck cannot move into the locked deck.
        let incoming = try #require(other.sounds.first)
        #expect(!library.moveSound(incoming, toDeck: show.id))
        #expect(!library.moveTargets(for: incoming).contains { $0.id == show.id })
        #expect(library.isLocked(horn))
        #expect(!library.isLocked(incoming))
    }

    @Test func lockedDeckStillAcceptsAFavoriteAndSelection() throws {
        let (library, _) = try makeLibrary()
        let show = library.activeDeck
        let horn = show.sounds[0]
        library.setLocked(show.id, true)

        #expect(library.update(horn) { $0.isFavorite = true })
        #expect(library.sound(withID: horn.id)?.isFavorite == true)
        // A change that also touches another field is refused.
        #expect(!library.update(horn) { $0.isFavorite = false; $0.name = "X" })

        let other = try #require(library.decks.first { $0.id != show.id })
        library.selectDeck(other.id)
        #expect(library.activeDeckID == other.id)
        library.selectDeck(show.id)
        #expect(library.activeDeckID == show.id)
    }

    @Test func unlockAllowsChangesAgainAndTheLockPersists() throws {
        let (library, directory) = try makeLibrary()
        let show = library.activeDeck
        library.setLocked(show.id, true)
        let reloaded = SoundLibrary(store: SoundLibraryStore(directoryURL: directory))
        #expect(reloaded.decks.first { $0.id == show.id }?.isLocked == true)

        library.setLocked(show.id, false)
        #expect(library.rename(show.sounds[0], to: "Klaxon"))
        #expect(library.remove(show.sounds[1]))
        #expect(library.removeDeck(show.id))
    }
}

private extension Deck {
    /// The deck with `isLocked` set, to compare with a deck that was locked later.
    static func lockedCopy(of deck: Deck) -> Deck {
        var copy = deck
        copy.isLocked = true
        return copy
    }
}

@MainActor
struct CrossDeckSearchTests {
    @Test func searchFindsPadsInAllDecksActiveDeckFirst() {
        let first = Deck(name: "One", sounds: [pad("Air horn"), pad("Gong")])
        let second = Deck(name: "Two", sounds: [pad("Horn section"), pad("Bell")])
        let names = { (active: UUID) in
            SoundLibrary.search("horn", in: [first, second], activeDeckID: active).map(\.name)
        }
        #expect(names(first.id) == ["Air horn", "Horn section"])
        #expect(names(second.id) == ["Horn section", "Air horn"])
        #expect(SoundLibrary.search("  ", in: [first, second], activeDeckID: first.id).isEmpty)
        #expect(SoundLibrary.search(" GONG ", in: [first, second], activeDeckID: first.id).map(\.name) == ["Gong"])
    }

    @Test func libraryGridShowsOtherDecksWhileSearching() throws {
        let directory = try temporaryDirectory()
        let library = SoundLibrary(store: SoundLibraryStore(directoryURL: directory))
        let main = library.activeDeckID
        library.addDeck(named: "Show")
        try library.addSound(url: makeAudioFile(named: "Zebra crossing.wav", in: directory))
        library.selectDeck(main)

        #expect(!library.filteredSounds.contains { $0.name == "Zebra crossing" })
        library.searchText = "zebra"
        #expect(library.filteredSounds.map(\.name) == ["Zebra crossing"])
        #expect(library.showsAllDecks)
        // Keys still use the active deck.
        #expect(library.activeDeckID == main)
        let zebra = try #require(library.filteredSounds.first)
        #expect(library.deckName(of: zebra.id) == "Show")
    }
}

@MainActor
struct SmartDeckTests {
    @Test func favoritesFilterKeepsDeckOrder() {
        let first = Deck(name: "One", sounds: [pad("A", favorite: true), pad("B")])
        let second = Deck(name: "Two", sounds: [pad("C"), pad("D", favorite: true)])
        #expect(SoundLibrary.favorites(in: [first, second]).map(\.name) == ["A", "D"])
        #expect(SoundLibrary.favorites(in: []).isEmpty)
    }

    @Test func recentListDedupesOrdersAndLimits() {
        let a = UUID(), b = UUID(), c = UUID()
        var recent: [UUID] = []
        recent = SoundLibrary.noting(a, in: recent)
        recent = SoundLibrary.noting(b, in: recent)
        recent = SoundLibrary.noting(c, in: recent)
        #expect(recent == [c, b, a])
        recent = SoundLibrary.noting(a, in: recent)
        #expect(recent == [a, c, b])

        let many = (0..<30).map { _ in UUID() }
        let limited = many.reduce([UUID]()) { SoundLibrary.noting($1, in: $0) }
        #expect(limited.count == SoundLibrary.recentLimit)
        #expect(limited.first == many.last)
        #expect(limited == Array(many.reversed().prefix(20)))
    }

    @Test func smartDeckKeepsTheActiveDeckAndIsReadOnly() throws {
        let directory = try temporaryDirectory()
        let library = SoundLibrary(store: SoundLibraryStore(directoryURL: directory))
        library.addDeck(named: "Show")
        let show = library.activeDeckID
        let horn = try library.addSound(url: makeAudioFile(named: "Horn.wav", in: directory))
        let bell = try library.addSound(url: makeAudioFile(named: "Bell.wav", in: directory))
        library.update(bell) { $0.isFavorite = true }

        library.selectSmartDeck(.favorites)
        #expect(library.smartDeck == .favorites)
        #expect(library.activeDeckID == show)
        #expect(library.filteredSounds.map(\.id) == [bell.id])
        #expect(library.sound(forHotKey: horn.hotKey ?? "") == library.sound(withID: horn.id))

        // No reorder in a smart deck.
        library.move(id: bell.id, before: horn.id)
        #expect(library.activeDeck.sounds.map(\.id) == [horn.id, bell.id])

        // Selecting a real deck leaves the smart deck.
        library.selectDeck(show)
        #expect(library.smartDeck == nil)
        #expect(library.filteredSounds.map(\.id) == [horn.id, bell.id])
    }

    @Test func recentPersistsAndDropsRemovedPads() throws {
        let directory = try temporaryDirectory()
        let library = SoundLibrary(store: SoundLibraryStore(directoryURL: directory))
        let horn = try library.addSound(url: makeAudioFile(named: "Horn.wav", in: directory))
        let bell = try library.addSound(url: makeAudioFile(named: "Bell.wav", in: directory))
        library.noteDidPlay(horn.id)
        library.noteDidPlay(bell.id)
        library.noteDidPlay(horn.id)
        #expect(library.recentIDs == [horn.id, bell.id])

        let reloaded = SoundLibrary(store: SoundLibraryStore(directoryURL: directory))
        #expect(reloaded.recentIDs == [horn.id, bell.id])
        reloaded.selectSmartDeck(.recent)
        #expect(reloaded.filteredSounds.map(\.name) == ["Horn", "Bell"])

        reloaded.remove(horn)
        #expect(reloaded.recentIDs == [bell.id])
    }
}

struct OrganizationDecodingTests {
    @Test func oldFilesDecodeWithDefaults() throws {
        let json = """
        {"version": 3, "activeDeckID": "6F7C2B9A-0000-4000-8000-000000000001",
         "decks": [{"id": "6F7C2B9A-0000-4000-8000-000000000001", "name": "Main", "sounds": [
           {"id": "0E2699C1-F84B-4FFD-B2C3-15D1E1954DA4", "name": "Laser", "isBundled": true}
         ]}]}
        """
        let state = try SoundLibraryStore.decode(Data(json.utf8))
        #expect(state.recentIDs.isEmpty)
        #expect(state.decks[0].isLocked == false)
        #expect(state.decks[0].sounds[0].isFavorite == false)
    }

    @Test func newFieldsRoundTrip() throws {
        let deck = Deck(name: "Show", sounds: [pad("Horn", favorite: true)], isLocked: true)
        let state = SoundLibraryStore.State(decks: [deck], activeDeckID: deck.id, recentIDs: [deck.sounds[0].id])
        let decoded = try SoundLibraryStore.decode(SoundLibraryStore.encode(state))
        #expect(decoded == state)
    }

    @Test func archiveEntryWithoutFavoriteDecodes() throws {
        let json = """
        {"format": "SoundDeck.deck", "version": 1, "name": "Show", "sounds": [
          {"name": "Horn", "fileName": "Horn.wav", "volume": 1, "loops": false, "trimStart": 0,
           "tint": "amber", "audio": "UklGRg=="}
        ]}
        """
        let archive = try JSONDecoder().decode(DeckArchive.self, from: Data(json.utf8))
        #expect(archive.sounds[0].isFavorite == nil)
    }
}
