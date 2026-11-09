import AVFoundation
import AppKit
import Foundation
import Testing
@testable import SoundDeck

/// Writes a mono file: `silence` seconds of silence, then `tone` seconds at full level.
private func makeFile(silence: Double, tone: Double, sampleRate: Double = 8000) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PadPreviewTests-\(UUID().uuidString).caf")
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let silent = Int(silence * sampleRate), loud = Int(tone * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(silent + loud))!
    buffer.frameLength = buffer.frameCapacity
    let data = buffer.floatChannelData![0]
    for index in 0..<(silent + loud) { data[index] = index < silent ? 0 : (index % 2 == 0 ? 0.5 : -0.5) }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
}

struct PadPreviewTests {
    @Test func envelopeFollowsTheFile() throws {
        let url = try makeFile(silence: 1, tone: 1)
        let preview = try PadPreview.make(url: url, trimStart: 0, trimEnd: nil, speed: 1, bars: 4)
        #expect(preview.envelope == [0, 0, 1, 1])
        #expect(abs(preview.duration - 2) < 0.001)
    }

    @Test func previewUsesTheTrimAndTheSpeed() throws {
        let url = try makeFile(silence: 1, tone: 1)
        let trimmed = try PadPreview.make(url: url, trimStart: 1, trimEnd: nil, speed: 1, bars: 4)
        #expect(trimmed.envelope == [1, 1, 1, 1])
        #expect(abs(trimmed.duration - 1) < 0.001)
        let fast = try PadPreview.make(url: url, trimStart: 0, trimEnd: nil, speed: 2, bars: 4)
        #expect(abs(fast.duration - 1) < 0.001)
    }

    @Test func clipShorterThanTheBarsDoesNotTrap() throws {
        let url = try makeFile(silence: 0, tone: 0.001)
        let preview = try PadPreview.make(url: url, trimStart: 0, trimEnd: nil, speed: 1, bars: 32)
        #expect(preview.envelope.count == 32)
        let empty = try PadPreview.make(url: url, trimStart: 5, trimEnd: nil, speed: 1, bars: 32)
        #expect(empty.envelope == Array(repeating: 0, count: 32))
        #expect(empty.duration == 0)
    }

    @Test func formatsTheDuration() {
        #expect(PadPreview.format(duration: 0.94) == "0.9s")
        #expect(PadPreview.format(duration: 4.06) == "4.1s")
        #expect(PadPreview.format(duration: 9.96) == "0:10")
        #expect(PadPreview.format(duration: 83) == "1:23")
        #expect(PadPreview.format(duration: .nan) == "")
    }
}

struct PadSymbolTests {
    @Test func everySymbolExists() {
        for choice in PadSymbols.choices {
            #expect(NSImage(systemSymbolName: choice.symbol, accessibilityDescription: nil) != nil, "\(choice.symbol)")
        }
    }

    @Test func bundledSymbolsAreChoices() {
        let choices = Set(PadSymbols.choices.map(\.symbol))
        for (file, symbol) in PadSymbols.bundled {
            #expect(choices.contains(symbol), "\(file)")
        }
        #expect(SoundItem(name: "Gong.wav").symbol == "flag.checkered")
        #expect(SoundItem(copiedFileName: "mine.wav").symbol == nil)
    }

    @MainActor
    @Test func version5LibraryGetsBundledSymbols() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundDeckTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var gong = SoundItem(name: "Gong.wav")
        gong.symbol = nil
        var chime = SoundItem(name: "Chime.wav")
        chime.symbol = nil
        chime.emoji = "🎸"
        let deck = Deck(name: "Main", sounds: [gong, chime])
        let store = SoundLibraryStore(directoryURL: directory)
        store.save(.init(decks: [deck], activeDeckID: deck.id, version: 5))
        // The save always writes the current version. Write version 5 by hand.
        let file = directory.appendingPathComponent("library.json")
        let text = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "\"version\" : \(SoundLibraryStore.currentVersion)", with: "\"version\" : 5")
        try text.write(to: file, atomically: true, encoding: .utf8)

        let library = SoundLibrary(store: store)
        #expect(library.sound(withID: gong.id)?.symbol == "flag.checkered")
        // An emoji that the user chose stays.
        #expect(library.sound(withID: chime.id)?.symbol == nil)
        #expect(library.sound(withID: chime.id)?.emoji == "🎸")
    }
}
