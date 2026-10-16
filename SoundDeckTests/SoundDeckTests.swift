import AVFoundation
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

struct StoreTests {
    @Test func version1FileLoadsAsOneDeck() throws {
        let json = """
        {"version": 1, "sounds": [
          {"id": "0E2699C1-F84B-4FFD-B2C3-15D1E1954DA4", "name": "Laser.wav", "isBundled": true, "hotKey": "1"}
        ]}
        """
        let state = try SoundLibraryStore.decode(Data(json.utf8))
        #expect(state.decks.count == 1)
        #expect(state.decks[0].name == SoundLibraryStore.defaultDeckName)
        #expect(state.activeDeckID == state.decks[0].id)
        let sound = try #require(state.decks[0].sounds.first)
        // An old file has no fileName. The name is the file name.
        #expect(sound.fileName == "Laser.wav")
        #expect(sound.isCopied == false)
    }

    @Test func version2RoundTrip() throws {
        let first = Deck(name: "Podcast", sounds: [SoundItem(name: "Gong.wav")])
        let second = Deck(name: "Stream", sounds: [SoundItem(copiedFileName: "a.mp3")])
        let state = SoundLibraryStore.State(decks: [first, second], activeDeckID: second.id)
        let decoded = try SoundLibraryStore.decode(SoundLibraryStore.encode(state))
        #expect(decoded == state)
    }

    @Test func unknownActiveDeckFallsBackToFirstDeck() throws {
        let deck = Deck(name: "Podcast")
        var data = try SoundLibraryStore.encode(.init(decks: [deck], activeDeckID: UUID()))
        let decoded = try SoundLibraryStore.decode(data)
        #expect(decoded.activeDeckID == deck.id)
        data = Data()
        #expect(throws: (any Error).self) { try SoundLibraryStore.decode(data) }
    }
}

@MainActor
struct LibraryTests {
    @Test func importCopiesTheFileAndRemoveDeletesIt() throws {
        let directory = try temporaryDirectory()
        let store = SoundLibraryStore(directoryURL: directory)
        let library = SoundLibrary(store: store)
        let source = try makeAudioFile(named: "Horn.wav", in: directory)

        let item = try library.addSound(url: source)
        let copy = item.copyURL(in: store.soundsDirectoryURL)
        #expect(item.isCopied)
        #expect(item.isBundled == false)
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(library.resolve(item)?.url == copy)

        // The original can go away. The pad keeps its copy.
        try FileManager.default.removeItem(at: source)
        #expect(FileManager.default.fileExists(atPath: copy.path))

        library.remove(item)
        #expect(FileManager.default.fileExists(atPath: copy.path) == false)
    }

    @Test func duplicateImportIsRefused() throws {
        let directory = try temporaryDirectory()
        let library = SoundLibrary(store: SoundLibraryStore(directoryURL: directory))
        let source = try makeAudioFile(named: "Horn.wav", in: directory)
        try library.addSound(url: source)
        #expect(throws: SoundImportError.self) { try library.addSound(url: source) }
    }

    @Test func renamedBundledPadKeepsItsFile() throws {
        let directory = try temporaryDirectory()
        let store = SoundLibraryStore(directoryURL: directory)
        let library = SoundLibrary(store: store)
        let pad = try #require(library.sounds.first { $0.isBundled })
        library.rename(pad, to: "Drum roll")

        // A new start must keep the pad, and the pad must still find its file.
        let reloaded = SoundLibrary(store: store)
        let same = try #require(reloaded.sound(withID: pad.id))
        #expect(same.name == "Drum roll")
        let url = try #require(reloaded.resolve(same)?.url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aHotKeyTriggersOnlyOnePad() throws {
        let library = SoundLibrary(store: SoundLibraryStore(directoryURL: try temporaryDirectory()))
        let first = library.sounds[0]
        let second = library.sounds[1]
        library.update(second) { $0.hotKey = first.hotKey }
        #expect(library.sound(withID: first.id)?.hotKey == nil)
        #expect(library.sound(forHotKey: try #require(first.hotKey))?.id == second.id)
    }

    @Test func oldImportIsCopiedAtStart() throws {
        let directory = try temporaryDirectory()
        let store = SoundLibraryStore(directoryURL: directory)
        let source = try makeAudioFile(named: "Old.wav", in: directory)
        let bookmark = try BookmarkFlavor.makeBookmark(for: source, scoped: false)
        let old = SoundItem(name: "Old.wav", bookmarkData: bookmark, isSecurityScoped: false)
        let deck = Deck(name: "Main", sounds: [old])
        store.save(.init(decks: [deck], activeDeckID: deck.id))

        let library = SoundLibrary(store: store)
        let item = try #require(library.sound(withID: old.id))
        #expect(item.isCopied)
        #expect(item.bookmarkData == nil)
        #expect(FileManager.default.fileExists(atPath: item.copyURL(in: store.soundsDirectoryURL).path))
    }

    @Test func decksKeepTheirOwnPadsAndKeys() throws {
        let directory = try temporaryDirectory()
        let store = SoundLibraryStore(directoryURL: directory)
        let library = SoundLibrary(store: store)
        let main = library.activeDeck
        let pad = library.sounds[0]

        let stream = library.addDeck(named: "Stream")
        #expect(library.activeDeckID == stream.id)
        #expect(library.sounds.isEmpty)
        #expect(library.sound(forHotKey: "1") == nil)

        library.moveSound(pad, toDeck: stream.id)
        #expect(library.sounds.map(\.id) == [pad.id])
        #expect(library.sounds[0].hotKey == "1")

        // A second deck with the same name gets a number.
        #expect(library.addDeck(named: "Stream").name == "Stream 2")

        let reloaded = SoundLibrary(store: store)
        #expect(reloaded.decks.map(\.name) == [main.name, "Stream", "Stream 2"])
    }

    @Test func removingADeckDeletesItsCopies() throws {
        let directory = try temporaryDirectory()
        let store = SoundLibraryStore(directoryURL: directory)
        let library = SoundLibrary(store: store)
        let main = library.activeDeck
        let stream = library.addDeck(named: "Stream")
        let item = try library.addSound(url: try makeAudioFile(named: "Horn.wav", in: directory))

        library.removeDeck(stream.id)
        #expect(library.activeDeckID == main.id)
        #expect(FileManager.default.fileExists(atPath: item.copyURL(in: store.soundsDirectoryURL).path) == false)

        // The last deck stays.
        library.removeDeck(main.id)
        #expect(library.decks.count == 1)
    }
}

@MainActor
struct ArchiveTests {
    @Test func exportThenImportMakesAnEqualDeck() throws {
        let directory = try temporaryDirectory()
        let store = SoundLibraryStore(directoryURL: directory)
        let library = SoundLibrary(store: store)
        let horn = try library.addSound(url: try makeAudioFile(named: "Horn.wav", in: directory))
        library.update(horn) {
            $0.name = "Air horn"
            $0.volume = 0.5
            $0.trimStart = 0.2
            $0.emoji = "📣"
        }
        let original = library.activeDeck

        let data = try library.exportArchive(of: original.id)
        let imported = try library.importArchive(data)

        #expect(library.activeDeckID == imported.id)
        #expect(imported.name == "\(original.name) 2")
        #expect(imported.sounds.count == original.sounds.count)
        // Bundled pads become copies, so the deck works with any version of the app.
        #expect(imported.sounds.allSatisfy { $0.isCopied })
        #expect(Set(imported.sounds.map(\.id)).isDisjoint(with: original.sounds.map(\.id)))
        let copy = try #require(imported.sounds.first { $0.name == "Air horn" })
        #expect(copy.volume == 0.5)
        #expect(copy.trimStart == 0.2)
        #expect(copy.emoji == "📣")
        #expect(copy.hotKey == library.sound(withID: horn.id)?.hotKey)
        let audio = try Data(contentsOf: try #require(library.resolve(copy)?.url))
        #expect(audio == Data("RIFF test audio".utf8))
    }

    @Test func importKeepsFilesInsideTheLibrary() throws {
        let directory = try temporaryDirectory()
        let store = SoundLibraryStore(directoryURL: directory)
        let library = SoundLibrary(store: store)
        let entry = DeckArchive.Entry(
            name: "Bad", fileName: "../../escape.wav", volume: 1, loops: false,
            trimStart: 0, trimEnd: nil, tint: .none, emoji: nil, hotKey: nil, audio: Data("x".utf8)
        )
        let archive = DeckArchive(format: DeckArchive.formatName, version: 1, name: "Shared", sounds: [entry])
        let deck = try library.importArchive(try JSONEncoder().encode(archive))
        let url = deck.sounds[0].copyURL(in: store.soundsDirectoryURL)
        #expect(url.deletingLastPathComponent().deletingLastPathComponent() == store.soundsDirectoryURL)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("escape.wav").path) == false)
    }

    @Test func otherJSONIsRefused() throws {
        let library = SoundLibrary(store: SoundLibraryStore(directoryURL: try temporaryDirectory()))
        #expect(throws: DeckArchiveError.self) { try library.importArchive(Data("{\"a\": 1}".utf8)) }
    }
}

struct TrimWindowTests {
    private let rate = 48_000.0

    @Test func noTrimPlaysTheWholeFile() {
        let window = AudioEngine.trimWindow(trimStart: 0, trimEnd: nil, totalFrames: 96_000, sampleRate: rate)
        #expect(window.startFrame == 0)
        #expect(window.frameCount == 96_000)
        #expect(window.end == 2)
    }

    @Test func trimSelectsThePart() {
        let window = AudioEngine.trimWindow(trimStart: 0.5, trimEnd: 1.5, totalFrames: 96_000, sampleRate: rate)
        #expect(window.startFrame == 24_000)
        #expect(window.frameCount == 48_000)
    }

    @Test func trimPastTheEndIsClamped() {
        // The file became shorter after the trim was set.
        let window = AudioEngine.trimWindow(trimStart: 1, trimEnd: 10, totalFrames: 96_000, sampleRate: rate)
        #expect(window.end == 2)
        #expect(window.startFrame + AVAudioFramePosition(window.frameCount) <= 96_000)
    }

    @Test func emptyOrReversedTrimHasNoFrames() {
        #expect(AudioEngine.trimWindow(trimStart: 5, trimEnd: nil, totalFrames: 96_000, sampleRate: rate).frameCount == 0)
        #expect(AudioEngine.trimWindow(trimStart: 1.5, trimEnd: 0.5, totalFrames: 96_000, sampleRate: rate).frameCount == 0)
        #expect(AudioEngine.trimWindow(trimStart: -1, trimEnd: 0, totalFrames: 96_000, sampleRate: rate).frameCount == 0)
    }
}

@MainActor
struct HotKeyTests {
    @Test func keyCodesCoverDigitsAndLetters() {
        let keys = (0...9).map(String.init) + "abcdefghijklmnopqrstuvwxyz".map(String.init)
        let codes = keys.compactMap { GlobalHotKeys.keyCode(for: $0) }
        #expect(codes.count == keys.count)
        #expect(Set(codes).count == keys.count)
        #expect(GlobalHotKeys.keyCode(for: "A") == GlobalHotKeys.keyCode(for: "a"))
        #expect(GlobalHotKeys.keyCode(for: "?") == nil)
    }
}

@MainActor
struct HotKeyBinderTests {
    @Test func registersAgainOnlyWhenTheKeysChange() throws {
        let library = SoundLibrary(store: SoundLibraryStore(directoryURL: try temporaryDirectory()))
        var calls: [[HotKeyBinder.Key]] = []
        let binder = HotKeyBinder(library: library) { calls.append($0) }
        #expect(calls.count == 1)
        #expect(calls[0].count == library.sounds.filter { $0.hotKey != nil }.count)

        let pad = library.sounds[0]
        library.update(pad) { $0.volume = 0.3 }
        library.rename(pad, to: "Other name")
        #expect(calls.count == 1)

        library.update(pad) { $0.hotKey = nil }
        #expect(calls.count == 2)

        library.addDeck(named: "Empty")
        #expect(calls.count == 3)
        #expect(calls[2].isEmpty)

        binder.refresh()
        #expect(calls.count == 4)
    }
}

struct LibraryFileSafetyTests {
    @Test func oneBadPadDoesNotLoseTheDeck() throws {
        let directory = try temporaryDirectory()
        let json = """
        {"version": 2, "decks": [{"id": "0E2699C1-F84B-4FFD-B2C3-15D1E1954DA4", "name": "Main", "sounds": [
          {"id": "1332466E-3960-45EE-A086-05F7A2809008", "name": "Gong.wav", "isBundled": true, "tint": "chartreuse"},
          {"name": "No id", "isBundled": true},
          {"id": "EB02EBAF-461B-45B3-89AE-AA3BA2BBB5FE", "name": "Glass.wav", "isBundled": true}
        ]}]}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("library.json"))
        let store = SoundLibraryStore(directoryURL: directory)
        let state = try #require(store.load())

        // The unknown tint is not an error. Only the pad with no id is skipped.
        #expect(state.decks[0].sounds.map(\.name) == ["Gong.wav", "Glass.wav"])
        #expect(state.decks[0].sounds[0].tint == .none)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.contains { $0.hasPrefix("library-corrupt-") })
        #expect(store.isReadOnly == false)
    }

    @Test func unreadableFileIsKept() throws {
        let directory = try temporaryDirectory()
        try Data("not json".utf8).write(to: directory.appendingPathComponent("library.json"))
        let store = SoundLibraryStore(directoryURL: directory)
        #expect(store.load() == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let kept = try #require(files.first { $0.hasPrefix("library-corrupt-") })
        #expect(try Data(contentsOf: directory.appendingPathComponent(kept)) == Data("not json".utf8))
    }
}

extension LibraryFileSafetyTests {
    @Test func storeDoesNotSaveWhenItCannotKeepTheFile() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("library.json")
        try Data("not json".utf8).write(to: file)
        // A read-only directory makes the salvage fail.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        let store = SoundLibraryStore(directoryURL: directory)
        #expect(store.load() == nil)
        #expect(store.isReadOnly)
        let deck = Deck(name: "Main")
        store.save(.init(decks: [deck], activeDeckID: deck.id))
        #expect(try Data(contentsOf: file) == Data("not json".utf8))
    }
}
