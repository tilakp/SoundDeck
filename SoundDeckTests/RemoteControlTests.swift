import Foundation
import Testing
@testable import SoundDeck

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SoundDeckTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func command(_ text: String) throws -> DeckURL.Command? {
    DeckURL.command(from: try #require(URL(string: text)))
}

struct DeckURLTests {
    @Test func readsEachCommand() throws {
        #expect(try command("sounddeck://play/Gong") == .play("Gong"))
        #expect(try command("sounddeck://release/Gong") == .release("Gong"))
        #expect(try command("sounddeck://stop") == .stop(nil))
        #expect(try command("sounddeck://stop/") == .stop(nil))
        #expect(try command("sounddeck://stop/Gong") == .stop("Gong"))
        #expect(try command("sounddeck://deck/Main") == .deck("Main"))
    }

    @Test func decodesSpacesAndPercentEncoding() throws {
        #expect(try command("sounddeck://play/Sad%20trombone") == .play("Sad trombone"))
        #expect(try command("sounddeck://deck/My%20show") == .deck("My show"))
        #expect(try command("sounddeck://play/AC%2FDC") == .play("AC/DC"))
        #expect(try command("sounddeck://play/Caf%C3%A9") == .play("Café"))
        #expect(try command("sounddeck://play/%20Gong%20") == .play("Gong"))
    }

    @Test func schemeAndHostDoNotMatchCase() throws {
        #expect(try command("SoundDeck://PLAY/Gong") == .play("Gong"))
    }

    @Test func rejectsUnknownOrIncompleteURLs() throws {
        #expect(try command("sounddeck://jump/Gong") == nil)
        #expect(try command("other://play/Gong") == nil)
        #expect(try command("sounddeck:play/Gong") == nil)
        #expect(try command("sounddeck://play") == nil)
        #expect(try command("sounddeck://play/") == nil)
        #expect(try command("sounddeck://play/%20") == nil)
        #expect(try command("sounddeck://release") == nil)
        #expect(try command("sounddeck://deck") == nil)
    }

    @MainActor
    @Test func runSelectsADeck() throws {
        let library = SoundLibrary(store: SoundLibraryStore(directoryURL: try temporaryDirectory()))
        let commands = DeckCommands(library: library, engine: AudioEngine())
        library.addDeck(named: "Show")
        let main = try #require(library.decks.first { $0.name != "Show" })
        #expect(DeckURL.run(.deck(main.name), on: commands))
        #expect(library.activeDeck.id == main.id)
        #expect(!DeckURL.run(.deck("No such deck"), on: commands))
        #expect(!DeckURL.run(.play("No such pad"), on: commands))
    }
}

struct PadQueryTests {
    private let pads = [
        DeckCommands.PadInfo(id: UUID(), name: "Gong", key: "1", deck: "Main", isPlaying: false),
        DeckCommands.PadInfo(id: UUID(), name: "Sad trombone", key: nil, deck: "Main", isPlaying: false),
        DeckCommands.PadInfo(id: UUID(), name: "Gong", key: nil, deck: "Show", isPlaying: true),
    ]

    @Test func findsEntitiesByIdInTheOrderOfTheIds() {
        let found = PadQuery.entities(for: [pads[2].id, UUID(), pads[0].id], in: pads)
        #expect(found.map(\.id) == [pads[2].id, pads[0].id])
        #expect(found.map(\.deck) == ["Show", "Main"])
    }

    @Test func findsEntitiesByPartOfTheName() {
        #expect(PadQuery.entities(matching: "TROMB", in: pads).map(\.id) == [pads[1].id])
        #expect(PadQuery.entities(matching: "gong", in: pads).count == 2)
        #expect(PadQuery.entities(matching: "horn", in: pads).isEmpty)
    }

    @MainActor
    @Test func entityKeepsTheNameAndDeckOfThePad() throws {
        let library = SoundLibrary(store: SoundLibraryStore(directoryURL: try temporaryDirectory()))
        let commands = DeckCommands(library: library, engine: AudioEngine())
        let entities = commands.pads(allDecks: true).map(PadEntity.init)
        let gong = try #require(library.sounds.first { $0.fileName == "Gong.wav" })
        let entity = try #require(entities.first { $0.id == gong.id })
        #expect(entity.name == gong.name)
        #expect(entity.deck == library.activeDeck.name)
    }
}
