import Foundation
import Testing
@testable import SoundDeck

struct CleanNameTests {
    @Test func removesSitesIdsAndFillers() {
        #expect(SoundItem.cleanName(forFileName: "viralaudio-descent-whoosh-long-cinematic-sound-effect-405921.mp3")
                == "Descent whoosh long cinematic")
        #expect(SoundItem.cleanName(forFileName: "mixkit-crowd-laugh-424.wav") == "Crowd laugh")
        #expect(SoundItem.cleanName(forFileName: "zapsplat_cartoon_boing_001.mp3") == "Cartoon boing")
        #expect(SoundItem.cleanName(forFileName: "123456__someone__air horn.wav") == "Air horn")
    }

    @Test func keepsNamesThatAPersonWrote() {
        #expect(SoundItem.cleanName(forFileName: "Ba-dum-tss.wav") == "Ba-dum-tss")
        #expect(SoundItem.cleanName(forFileName: "Intro Take 2.m4a") == "Intro Take 2")
        #expect(SoundItem.cleanName(forFileName: "DJ Airhorn.mp3") == "DJ Airhorn")
        // A name that is only an id keeps the file name.
        #expect(SoundItem.cleanName(forFileName: "405921.mp3") == "405921")
        // Two hyphenated words are not a slug. Only the first letter changes.
        #expect(SoundItem.cleanName(forFileName: "sound-effect.wav") == "Sound-effect")
    }

    @MainActor
    @Test func version6LibraryCleansImportedNames() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundDeckTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let raw = SoundItem(copiedFileName: "mixkit-crowd-laugh-424.wav")
        var renamed = SoundItem(copiedFileName: "mixkit-door-bell-12.wav")
        renamed.name = "Front door"
        let deck = Deck(name: "Main", sounds: [raw, renamed])
        let store = SoundLibraryStore(directoryURL: directory)
        store.save(.init(decks: [deck], activeDeckID: deck.id, version: 6))
        // The save always writes the current version. Write version 6 by hand.
        let file = directory.appendingPathComponent("library.json")
        let text = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "\"version\" : \(SoundLibraryStore.currentVersion)", with: "\"version\" : 6")
        try text.write(to: file, atomically: true, encoding: .utf8)

        let library = SoundLibrary(store: store)
        #expect(library.sound(withID: raw.id)?.name == "Crowd laugh")
        #expect(library.sound(withID: renamed.id)?.name == "Front door")
    }
}

@MainActor
struct UndoRemoveTests {
    private func makeLibrary() throws -> (SoundLibrary, SoundLibraryStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundDeckTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SoundLibraryStore(directoryURL: directory)
        return (SoundLibrary(store: store), store)
    }

    @Test func restorePutsThePadAndItsFileBack() throws {
        let (library, store) = try makeLibrary()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("undo-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: try #require(Bundle.main.url(forResource: "Gong", withExtension: "wav")), to: source)
        let pad = try library.addSound(url: source)
        let file = pad.copyURL(in: store.soundsDirectoryURL)
        let index = try #require(library.sounds.firstIndex { $0.id == pad.id })

        let removed = try #require(library.removeUndoably(pad))
        #expect(library.sound(withID: pad.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        #expect(library.restore(removed))
        #expect(library.sounds.firstIndex { $0.id == pad.id } == index)
        #expect(FileManager.default.fileExists(atPath: file.path))
        // A second restore does nothing.
        #expect(library.restore(removed) == false)
    }

    @Test func restoredPadLosesAKeyThatAnotherPadTook() throws {
        let (library, _) = try makeLibrary()
        let gong = try #require(library.sounds.first { $0.fileName == "Gong.wav" })
        let key = try #require(gong.hotKey)
        let removed = try #require(library.removeUndoably(gong))
        let chime = try #require(library.sounds.first { $0.fileName == "Chime.wav" })
        library.update(chime) { $0.hotKey = key }
        #expect(library.restore(removed))
        #expect(library.sound(withID: gong.id)?.hotKey == nil)
    }

    @Test func nextStartEmptiesTheHoldingDirectory() throws {
        let (library, store) = try makeLibrary()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("undo-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: try #require(Bundle.main.url(forResource: "Gong", withExtension: "wav")), to: source)
        let pad = try library.addSound(url: source)
        library.remove(pad)
        let holding = store.soundsDirectoryURL.appendingPathComponent(".removed/\(pad.id.uuidString)")
        #expect(FileManager.default.fileExists(atPath: holding.path))
        _ = SoundLibrary(store: store)
        #expect(!FileManager.default.fileExists(atPath: holding.path))
    }

    @Test func adjacentDeckWraps() throws {
        let (library, _) = try makeLibrary()
        let main = library.activeDeckID
        let second = library.addDeck(named: "Second")
        library.selectDeck(main)
        library.selectAdjacentDeck(offset: 1)
        #expect(library.activeDeckID == second.id)
        library.selectAdjacentDeck(offset: 1)
        #expect(library.activeDeckID == main)
        library.selectAdjacentDeck(offset: -1)
        #expect(library.activeDeckID == second.id)
    }
}
