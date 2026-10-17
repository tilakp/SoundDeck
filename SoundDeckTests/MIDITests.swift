import Foundation
import Testing
@testable import SoundDeck

/// A MIDI 1.0 channel voice message in one UMP word, group 0.
private func ump(_ status: UInt8, _ data1: UInt8, _ data2: UInt8) -> UInt32 {
    0x2000_0000 | UInt32(status) << 16 | UInt32(data1) << 8 | UInt32(data2)
}

private func pad(_ trigger: MIDITrigger?) -> SoundItem {
    var item = SoundItem(name: "Pad.wav")
    item.midiTrigger = trigger
    return item
}

struct MIDIParserTests {
    @Test func parsesNoteOnNoteOffAndControlChange() {
        #expect(MIDIParser.message(status: 0x99, data1: 36, data2: 100)
                == .noteOn(channel: 10, note: 36, velocity: 100))
        #expect(MIDIParser.message(status: 0x80, data1: 60, data2: 64)
                == .noteOff(channel: 1, note: 60, velocity: 64))
        #expect(MIDIParser.message(status: 0xBF, data1: 7, data2: 127)
                == .controlChange(channel: 16, controller: 7, value: 127))
    }

    @Test func noteOnWithVelocityZeroIsNoteOff() {
        #expect(MIDIParser.message(status: 0x90, data1: 40, data2: 0)
                == .noteOff(channel: 1, note: 40, velocity: 0))
    }

    @Test func ignoresOtherMessages() {
        #expect(MIDIParser.message(status: 0xE0, data1: 0, data2: 64) == nil) // Pitch bend
        #expect(MIDIParser.message(status: 0xC0, data1: 5, data2: 0) == nil) // Program change
        #expect(MIDIParser.message(status: 0xF8, data1: 0, data2: 0) == nil) // Clock
    }

    @Test func parsesUMPWordsAndSkipsOtherTypes() {
        let words: [UInt32] = [
            0x1000_F800, // System real time, 1 word
            ump(0x91, 36, 90),
            0x4090_2400, 0xFFFF_0000, // MIDI 2.0 Note On, 2 words
            ump(0xB0, 64, 0),
        ]
        #expect(MIDIParser.messages(fromUMP: words) == [
            .noteOn(channel: 2, note: 36, velocity: 90),
            .controlChange(channel: 1, controller: 64, value: 0),
        ])
    }

    @Test func labels() {
        #expect(MIDITrigger(kind: .note, channel: 10, number: 36).label == "Note 36, ch 10")
        #expect(MIDITrigger(kind: .controlChange, channel: nil, number: 64).label == "CC 64, any ch")
    }
}

struct MIDIMatcherTests {
    @Test func noteOnPlaysAndNoteOffReleases() {
        let item = pad(MIDITrigger(kind: .note, channel: 10, number: 36))
        var matcher = MIDIMatcher()
        #expect(matcher.commands(for: .noteOn(channel: 10, note: 36, velocity: 1), sounds: [item], stopAll: nil)
                == [.play(item.id)])
        #expect(matcher.commands(for: .noteOff(channel: 10, note: 36, velocity: 0), sounds: [item], stopAll: nil)
                == [.release(item.id)])
    }

    @Test func channelMustMatchUnlessAny() {
        let fixed = pad(MIDITrigger(kind: .note, channel: 10, number: 36))
        let any = pad(MIDITrigger(kind: .note, channel: nil, number: 36))
        var matcher = MIDIMatcher()
        let commands = matcher.commands(for: .noteOn(channel: 1, note: 36, velocity: 100),
                                        sounds: [fixed, any], stopAll: nil)
        #expect(commands == [.play(any.id)])
    }

    @Test func noteDoesNotMatchControllerWithSameNumber() {
        let item = pad(MIDITrigger(kind: .controlChange, channel: nil, number: 36))
        var matcher = MIDIMatcher()
        #expect(matcher.commands(for: .noteOn(channel: 1, note: 36, velocity: 100), sounds: [item], stopAll: nil)
                .isEmpty)
    }

    @Test func controllerActsOnlyWhenItCrossesTheMiddle() {
        let item = pad(MIDITrigger(kind: .controlChange, channel: 1, number: 20))
        var matcher = MIDIMatcher()
        func send(_ value: Int) -> [MIDICommand] {
            matcher.commands(for: .controlChange(channel: 1, controller: 20, value: value), sounds: [item], stopAll: nil)
        }
        #expect(send(10).isEmpty)
        #expect(send(64) == [.play(item.id)])
        #expect(send(100).isEmpty)
        #expect(send(63) == [.release(item.id)])
        #expect(send(0).isEmpty)
        #expect(send(127) == [.play(item.id)])
    }

    @Test func stopAllActsOnPressOnly() {
        let stop = MIDITrigger(kind: .note, channel: nil, number: 0)
        var matcher = MIDIMatcher()
        #expect(matcher.commands(for: .noteOn(channel: 3, note: 0, velocity: 100), sounds: [], stopAll: stop)
                == [.stopAll])
        #expect(matcher.commands(for: .noteOff(channel: 3, note: 0, velocity: 0), sounds: [], stopAll: stop)
                .isEmpty)
    }

    @Test func padsWithoutMappingDoNothing() {
        var matcher = MIDIMatcher()
        #expect(matcher.commands(for: .noteOn(channel: 1, note: 36, velocity: 100), sounds: [pad(nil)], stopAll: nil)
                .isEmpty)
    }
}

@MainActor
struct MIDILearnTests {
    @Test func learnTakesTheNextNoteOnOrController() {
        let learn = MIDILearn()
        var learned: MIDITrigger?
        learn.begin(owner: "pad") { learned = $0 }
        #expect(!learn.capture(.noteOff(channel: 1, note: 5, velocity: 0)))
        #expect(learn.capture(.controlChange(channel: 2, controller: 7, value: 3)))
        #expect(learned == MIDITrigger(kind: .controlChange, channel: 2, number: 7))
        #expect(learn.owner == nil)
        #expect(!learn.capture(.noteOn(channel: 1, note: 1, velocity: 1)))
    }

    @Test func cancelOnlyCancelsTheSameOwner() {
        let learn = MIDILearn()
        learn.begin(owner: "a") { _ in }
        learn.cancel(owner: "b")
        #expect(learn.owner == "a")
        learn.cancel(owner: "a")
        #expect(learn.owner == nil)
    }
}

struct MIDIStorageTests {
    @Test func triggerRoundTripsThroughJSON() throws {
        let item = pad(MIDITrigger(kind: .note, channel: 10, number: 36))
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(SoundItem.self, from: data)
        #expect(decoded.midiTrigger == item.midiTrigger)
    }

    @Test func oldLibraryWithoutTriggerStillLoads() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pad(nil))) as! [String: Any]
        object.removeValue(forKey: "midiTrigger")
        let decoded = try JSONDecoder().decode(SoundItem.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.midiTrigger == nil)
    }

    @Test func unknownTriggerKindDoesNotRejectThePad() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pad(nil))) as! [String: Any]
        object["midiTrigger"] = ["kind": "pitchBend", "number": 1]
        let decoded = try JSONDecoder().decode(SoundItem.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.midiTrigger == nil)
    }
}
