import Foundation
import Testing
@testable import SoundDeck

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SoundDeckTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
struct TestHostTests {
    @Test func appKnowsThatItHostsTheTests() {
        #expect(SoundDeckApp.isRunningTests)
    }
}

struct PadNameTests {
    @Test func displayNameHasNoExtension() {
        #expect(SoundItem.displayName(forFileName: "Gong.wav") == "Gong")
        #expect(SoundItem.displayName(forFileName: "Sad trombone.wav") == "Sad trombone")
        #expect(SoundItem.displayName(forFileName: "intro.final.mp3") == "intro.final")
        #expect(SoundItem.displayName(forFileName: "Horn") == "Horn")
        #expect(SoundItem(name: "Gong.wav").name == "Gong")
        #expect(SoundItem(name: "Gong.wav").fileName == "Gong.wav")
    }

    @MainActor
    @Test func version2LibraryLosesExtensionsOneTime() throws {
        let directory = try temporaryDirectory()
        var plain = SoundItem(name: "Gong.wav")
        plain.name = "Gong.wav"
        var renamed = SoundItem(name: "Chime.wav")
        renamed.name = "My chime.wav"
        let deck = Deck(name: "Main", sounds: [plain, renamed])
        let store = SoundLibraryStore(directoryURL: directory)
        store.save(.init(decks: [deck], activeDeckID: deck.id, version: 2))
        // The save always writes the current version. Write version 2 by hand.
        let file = directory.appendingPathComponent("library.json")
        let text = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "\"version\" : 3", with: "\"version\" : 2")
        try text.write(to: file, atomically: true, encoding: .utf8)

        let library = SoundLibrary(store: store)
        #expect(library.sound(withID: plain.id)?.name == "Gong")
        // A name that the user changed stays as it is.
        #expect(library.sound(withID: renamed.id)?.name == "My chime.wav")

        // After the migration, a name with an extension stays.
        library.rename(try #require(library.sound(withID: plain.id)), to: "Gong.wav")
        let reloaded = SoundLibrary(store: store)
        #expect(reloaded.sound(withID: plain.id)?.name == "Gong.wav")
    }
}

@MainActor
struct DeckCommandsTests {
    private func makeCommands() throws -> DeckCommands {
        let library = SoundLibrary(store: SoundLibraryStore(directoryURL: try temporaryDirectory()))
        return DeckCommands(library: library, engine: AudioEngine())
    }

    @Test func findsPadsByIdNameKeyAndPrefix() throws {
        let commands = try makeCommands()
        let gong = try #require(commands.library.sounds.first { $0.fileName == "Gong.wav" })
        #expect(commands.sound(matching: gong.id.uuidString)?.id == gong.id)
        #expect(commands.sound(matching: "gong")?.id == gong.id)
        #expect(commands.sound(matching: "  GONG ")?.id == gong.id)
        #expect(commands.sound(matching: "Gon")?.id == gong.id)
        #expect(commands.sound(matching: try #require(gong.hotKey))?.id == gong.id)
        #expect(commands.sound(matching: "no such pad") == nil)
        #expect(commands.sound(matching: "") == nil)
    }

    @Test func findsAPadInAnotherDeck() throws {
        let commands = try makeCommands()
        let gong = try #require(commands.library.sounds.first { $0.fileName == "Gong.wav" })
        commands.library.addDeck(named: "Empty")
        #expect(commands.sound(matching: "Gong")?.id == gong.id)
        #expect(commands.pads().isEmpty)
        #expect(commands.pads(allDecks: true).count == 9)
    }

    @Test func selectsDecksByName() throws {
        let commands = try makeCommands()
        let main = commands.library.activeDeck
        commands.library.addDeck(named: "Stream")
        #expect(commands.selectDeck("main"))
        #expect(commands.library.activeDeckID == main.id)
        #expect(commands.selectDeck("Nothing") == false)
    }

    @Test func unknownPadDoesNotPlay() throws {
        let commands = try makeCommands()
        #expect(commands.play("no such pad") == false)
        #expect(commands.stop("no such pad") == false)
        #expect(commands.stop())
    }
}
