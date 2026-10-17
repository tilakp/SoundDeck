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

struct PadEQModelTests {
    @Test func defaultIsFlat() {
        #expect(PadEQ().isFlat)
        #expect(PadEQ.effective(nil) == nil)
        #expect(PadEQ.effective(PadEQ(midFrequency: 2000)) == nil)
    }

    @Test func anyGainMakesItNotFlat() {
        #expect(!PadEQ(low: 1).isFlat)
        #expect(!PadEQ(mid: -3).isFlat)
        #expect(!PadEQ(high: 0.5).isFlat)
        #expect(PadEQ.effective(PadEQ(high: 6)) == PadEQ(high: 6))
    }

    @Test func gainsAndFrequencyAreClamped() {
        let eq = PadEQ(low: -40, mid: 30, midFrequency: 50, high: .infinity)
        #expect(eq.low == -12)
        #expect(eq.mid == 12)
        #expect(eq.midFrequency == 300)
        #expect(eq.high == 0)
        var edited = PadEQ()
        edited.high = 99
        edited.midFrequency = 20000
        #expect(edited.high == 12)
        #expect(edited.midFrequency == 5000)
    }

    @Test func bandsMapToTheUnitParameters() {
        let bands = PadEQ(low: 3, mid: -6, midFrequency: 2500, high: 0).bands
        #expect(bands.count == 3)
        #expect(bands[0].filterType == .lowShelf)
        #expect(bands[0].frequency == 120)
        #expect(bands[0].gain == 3)
        #expect(!bands[0].bypass)
        #expect(bands[1].filterType == .parametric)
        #expect(bands[1].frequency == 2500)
        #expect(bands[1].gain == -6)
        // Q 0.7 is about 1.92 octaves.
        #expect(abs(bands[1].bandwidth - 1.92) < 0.01)
        #expect(bands[2].filterType == .highShelf)
        #expect(bands[2].frequency == 8000)
        #expect(bands[2].bypass)
    }

    @Test func unitGetsTheBands() {
        let eq = PadEQ(low: -4, mid: 5, midFrequency: 700, high: 9)
        let unit = eq.makeUnit()
        #expect(unit.bands.count == 3)
        #expect(unit.globalGain == 0)
        for (parameters, band) in zip(unit.bands, eq.bands) {
            #expect(parameters.filterType == band.filterType)
            #expect(parameters.frequency == band.frequency)
            #expect(parameters.gain == band.gain)
            #expect(parameters.bypass == band.bypass)
        }
    }

    @Test func frequencySliderIsLogarithmic() {
        #expect(PadEQ.position(forMidFrequency: 300) == 0)
        #expect(abs(PadEQ.position(forMidFrequency: 5000) - 1) < 1e-9)
        #expect(PadEQ.midFrequency(atPosition: 0) == 300)
        #expect(PadEQ.midFrequency(atPosition: 1) == 5000)
        #expect(PadEQ.midFrequency(atPosition: 2) == 5000)
        let middle = PadEQ.midFrequency(atPosition: 0.5)
        // The geometric mean of 300 and 5000 is about 1225 Hz.
        #expect(abs(middle - 1225) <= 1)
        #expect(abs(PadEQ.midFrequency(atPosition: PadEQ.position(forMidFrequency: 1000)) - 1000) <= 1)
    }
}

struct PadEQCodingTests {
    @Test func olderPadHasNoEQ() throws {
        let old = #"{"id": "\#(UUID().uuidString)", "name": "Old", "isBundled": false}"#
        let decoded = try JSONDecoder().decode(SoundItem.self, from: Data(old.utf8))
        #expect(decoded.eq == nil)
    }

    @Test func padRoundTripKeepsTheEQ() throws {
        var item = SoundItem(name: "Gong.wav")
        item.eq = PadEQ(low: 2, mid: -3, midFrequency: 1800, high: 4)
        let decoded = try JSONDecoder().decode(SoundItem.self, from: try JSONEncoder().encode(item))
        #expect(decoded.eq == item.eq)
    }

    @Test func partialOrBadEQDecodesLeniently() throws {
        let partial = try JSONDecoder().decode(PadEQ.self, from: Data(#"{"high": 40}"#.utf8))
        #expect(partial == PadEQ(high: 12))
        let wrongType = try JSONDecoder().decode(PadEQ.self, from: Data(#"{"low": "loud", "mid": 2}"#.utf8))
        #expect(wrongType == PadEQ(mid: 2))
    }

    @Test func badEQOnAPadIsNotAnError() throws {
        let json = #"{"id": "\#(UUID().uuidString)", "name": "Odd", "isBundled": false, "eq": "bright"}"#
        let decoded = try JSONDecoder().decode(SoundItem.self, from: Data(json.utf8))
        #expect(decoded.eq == nil)
    }

    @Test func archiveEntryWithoutEQDecodes() throws {
        let entry = DeckArchive.Entry(
            name: "A", fileName: "a.wav", volume: 1, loops: false, trimStart: 0, trimEnd: nil,
            tint: .none, emoji: nil, hotKey: nil, audio: Data("x".utf8)
        )
        let copy = try JSONDecoder().decode(DeckArchive.Entry.self, from: try JSONEncoder().encode(entry))
        #expect(copy.eq == nil)
    }
}

@MainActor
struct PadEQArchiveTests {
    @Test func eqSurvivesExportAndImport() throws {
        let library = SoundLibrary(store: SoundLibraryStore(directoryURL: try temporaryDirectory()))
        let pad = library.sounds[0]
        let eq = PadEQ(low: -6, mid: 3, midFrequency: 2200, high: 12)
        library.update(pad) { $0.eq = eq }
        let imported = try library.importArchive(try library.exportArchive(of: library.activeDeck.id))
        let copy = try #require(imported.sounds.first { $0.name == pad.name })
        #expect(copy.eq == eq)
        let other = try #require(imported.sounds.first { $0.name != pad.name })
        #expect(other.eq == nil)
    }
}

/// Renders audio offline through the EQ unit. No audio hardware is necessary.
struct PadEQRenderTests {
    private static let sampleRate = 48_000.0
    private static let frames: AVAudioFrameCount = 24_000

    /// The RMS level of a 10 kHz sine after the EQ. Nil EQ means a direct connection.
    private func renderedLevel(eq: PadEQ?) throws -> Float {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.frames))
        input.frameLength = Self.frames
        let samples = try #require(input.floatChannelData?[0])
        for index in 0..<Int(Self.frames) {
            samples[index] = 0.1 * Float(sin(2 * Double.pi * 10_000 * Double(index) / Self.sampleRate))
        }

        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let player = AVAudioPlayerNode()
        engine.attach(player)
        if let eq {
            let unit = eq.makeUnit()
            engine.attach(unit)
            engine.connect(player, to: unit, format: format)
            engine.connect(unit, to: engine.mainMixerNode, format: format)
        } else {
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        try engine.start()
        defer { engine.stop() }
        player.scheduleBuffer(input)
        player.play()

        let output = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                   frameCapacity: engine.manualRenderingMaximumFrameCount))
        var sum: Double = 0
        var count = 0
        var rendered: AVAudioFrameCount = 0
        while rendered < Self.frames {
            let status = try engine.renderOffline(min(4096, Self.frames - rendered), to: output)
            #expect(status == .success)
            let channel = try #require(output.floatChannelData?[0])
            // Skip the first block, so that the filter has settled.
            if rendered >= 4096 {
                for index in 0..<Int(output.frameLength) {
                    sum += Double(channel[index] * channel[index])
                    count += 1
                }
            }
            rendered += output.frameLength
        }
        return Float(sqrt(sum / Double(max(count, 1))))
    }

    @Test func highShelfRaisesATenKilohertzSine() throws {
        let flat = try renderedLevel(eq: nil)
        let boosted = try renderedLevel(eq: PadEQ(high: 12))
        #expect(flat > 0.01)
        // A +12 dB shelf at 8 kHz gives at least +6 dB at 10 kHz.
        #expect(boosted > flat * 2)
    }

    @Test func lowShelfCutDoesNotRaiseATenKilohertzSine() throws {
        let flat = try renderedLevel(eq: nil)
        let cut = try renderedLevel(eq: PadEQ(low: -12))
        #expect(abs(20 * log10(cut / flat)) < 1)
    }
}
