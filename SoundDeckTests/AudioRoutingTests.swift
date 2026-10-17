import Foundation
import Testing
@testable import SoundDeck

struct OutputRouteTests {
    @Test func withAMonitorEachOutputHasItsRoute() {
        #expect(OutputRoute.route(for: .both, monitorIsActive: true) == OutputRoute(live: true, monitor: true))
        #expect(OutputRoute.route(for: .live, monitorIsActive: true) == OutputRoute(live: true, monitor: false))
        #expect(OutputRoute.route(for: .monitor, monitorIsActive: true) == OutputRoute(live: false, monitor: true))
    }

    @Test func withoutAMonitorPadsPlayOnLive() {
        #expect(OutputRoute.route(for: .both, monitorIsActive: false) == OutputRoute(live: true, monitor: false))
        #expect(OutputRoute.route(for: .live, monitorIsActive: false) == OutputRoute(live: true, monitor: false))
    }

    @Test func meOnlyWithoutAMonitorDoesNotGoToTheCall() {
        let route = OutputRoute.route(for: .monitor, monitorIsActive: false)
        #expect(route.isEmpty)
    }

    @Test func meOnlyHasItsLabel() {
        #expect(PadOutput.monitor.label == "Me only")
    }
}

struct PadOutputCodingTests {
    @Test func olderPadDecodesAsBoth() throws {
        let encoded = try JSONEncoder().encode(SoundItem(name: "Gong.wav"))
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "output")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SoundItem.self, from: data)
        #expect(decoded.output == .both)
    }

    @Test func unknownOutputDecodesAsBoth() throws {
        let encoded = try JSONEncoder().encode(SoundItem(name: "Gong.wav"))
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["output"] = "speakers"
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(SoundItem.self, from: data).output == .both)
    }

    @Test func outputSurvivesARoundTrip() throws {
        var sound = SoundItem(name: "Gong.wav")
        sound.output = .monitor
        let decoded = try JSONDecoder().decode(SoundItem.self, from: try JSONEncoder().encode(sound))
        #expect(decoded.output == .monitor)
    }
}

struct AudioRoutingSettingsTests {
    private func temporaryDefaults() throws -> UserDefaults {
        let name = "SoundDeckRoutingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsAreOff() throws {
        let settings = AudioRoutingSettings.load(from: try temporaryDefaults())
        #expect(settings.monitorDeviceUID == nil)
        #expect(settings.micEnabled == false)
        #expect(settings.micDeviceUID == nil)
        #expect(settings.micGainDecibels == 0)
        #expect(settings.micMuted == false)
    }

    @Test func settingsSurviveASaveAndALoad() throws {
        let defaults = try temporaryDefaults()
        var settings = AudioRoutingSettings()
        settings.monitorDeviceUID = "Headphones-UID"
        settings.monitorVolume = 0.4
        settings.micEnabled = true
        settings.micDeviceUID = "USB-Mic"
        settings.micGainDecibels = -6
        settings.micMuted = true
        settings.save(to: defaults)
        #expect(AudioRoutingSettings.load(from: defaults) == settings)
    }

    @Test func missingFieldsGetTheirDefaults() throws {
        let defaults = try temporaryDefaults()
        defaults.set(Data(#"{"monitorDeviceUID":"X"}"#.utf8), forKey: AudioRoutingSettings.defaultsKey)
        let settings = AudioRoutingSettings.load(from: defaults)
        #expect(settings.monitorDeviceUID == "X")
        #expect(settings.monitorVolume == 0.8)
        #expect(settings.micEnabled == false)
    }

    @Test func unreadableValueGivesTheDefaults() throws {
        let defaults = try temporaryDefaults()
        defaults.set(Data("not json".utf8), forKey: AudioRoutingSettings.defaultsKey)
        #expect(AudioRoutingSettings.load(from: defaults) == AudioRoutingSettings())
    }
}

struct RoutingGainTests {
    @Test func zeroDecibelsIsUnity() {
        #expect(RoutingMath.linearGain(decibels: 0, in: -24...12) == 1)
    }

    @Test func sixDecibelsIsAboutDouble() {
        #expect(abs(RoutingMath.linearGain(decibels: 6, in: -24...12) - 1.995) < 0.001)
        #expect(abs(RoutingMath.linearGain(decibels: -6, in: -24...12) - 0.501) < 0.001)
    }

    @Test func gainIsClampedToTheRange() {
        #expect(RoutingMath.linearGain(decibels: 40, in: -24...12) == RoutingMath.linearGain(decibels: 12, in: -24...12))
        #expect(RoutingMath.linearGain(decibels: -90, in: -24...12) == RoutingMath.linearGain(decibels: -24, in: -24...12))
    }

    @Test func muteGivesSilence() {
        var settings = AudioRoutingSettings()
        settings.micGainDecibels = 6
        #expect(settings.micLinearGain > 1)
        settings.micMuted = true
        #expect(settings.micLinearGain == 0)
    }

    @Test func fasterOutputWaitsForTheSlowerOutput() {
        let delays = RoutingMath.startDelays(latencies: [0.002, 0.012])
        #expect(abs(delays[0] - 0.010) < 1e-9)
        #expect(delays[1] == 0)
    }

    @Test func negativeLatencyCountsAsZero() {
        #expect(RoutingMath.startDelays(latencies: [-1, 0.005]) == [0.005, 0])
        #expect(RoutingMath.startDelays(latencies: []) == [])
    }
}

struct MicRingBufferTests {
    private func write(_ values: [Float], to buffer: MicRingBuffer) {
        values.withUnsafeBufferPointer { buffer.write($0.baseAddress!, count: $0.count) }
    }

    private func read(_ count: Int, from buffer: MicRingBuffer) -> [Float] {
        var output = [Float](repeating: -1, count: count)
        output.withUnsafeMutableBufferPointer { _ = buffer.read(into: $0.baseAddress!, count: count) }
        return output
    }

    @Test func readerWaitsForTheCushion() {
        let buffer = MicRingBuffer(capacity: 16, cushion: 4, maximumFill: 8)
        write([1, 2, 3], to: buffer)
        #expect(read(2, from: buffer) == [0, 0])
        write([4], to: buffer)
        #expect(read(2, from: buffer) == [1, 2])
    }

    @Test func underrunGivesSilenceAndPrimesAgain() {
        let buffer = MicRingBuffer(capacity: 16, cushion: 2, maximumFill: 8)
        write([1, 2, 3], to: buffer)
        #expect(read(4, from: buffer) == [1, 2, 3, 0])
        write([4], to: buffer)
        #expect(read(1, from: buffer) == [0])
        write([5], to: buffer)
        #expect(read(2, from: buffer) == [4, 5])
    }

    @Test func overflowKeepsOnlyTheNewestSamples() {
        let buffer = MicRingBuffer(capacity: 16, cushion: 2, maximumFill: 4)
        write([1, 2, 3, 4, 5], to: buffer)
        #expect(buffer.fill == 2)
        #expect(read(2, from: buffer) == [4, 5])
    }

    @Test func strideKeepsTheFirstChannel() {
        let buffer = MicRingBuffer(capacity: 16, cushion: 0, maximumFill: 8)
        let interleaved: [Float] = [1, 10, 2, 20, 3, 30]
        interleaved.withUnsafeBufferPointer { buffer.write($0.baseAddress!, count: 3, stride: 2) }
        #expect(read(3, from: buffer) == [1, 2, 3])
    }

    @Test func storageWrapsAround() {
        let buffer = MicRingBuffer(capacity: 4, cushion: 0, maximumFill: 4)
        write([1, 2, 3], to: buffer)
        #expect(read(3, from: buffer) == [1, 2, 3])
        write([4, 5, 6], to: buffer)
        #expect(read(3, from: buffer) == [4, 5, 6])
    }
}

struct DeckArchiveOutputTests {
    @Test func entryWithoutOutputDecodes() throws {
        let json = #"{"name":"A","fileName":"a.wav","volume":1,"loops":false,"trimStart":0,"tint":"none","audio":""}"#
        let entry = try JSONDecoder().decode(DeckArchive.Entry.self, from: Data(json.utf8))
        #expect(entry.output == nil)
    }
}
