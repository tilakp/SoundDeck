import Foundation

/// The MIDI input that plays a pad: a note or a control change (CC).
struct MIDITrigger: Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case note
        case controlChange
    }

    var kind: Kind
    /// 1 to 16. Nil means any channel.
    var channel: Int?
    /// 0 to 127.
    var number: Int

    /// For example "Note 36, ch 10" or "CC 64, any ch".
    var label: String {
        let name = kind == .note ? "Note" : "CC"
        let channelText = channel.map { "ch \($0)" } ?? "any ch"
        return "\(name) \(number), \(channelText)"
    }

    /// Gives true if the message comes from this input.
    func matches(_ message: MIDIMessage) -> Bool {
        guard let input = message.input else { return false }
        guard input.kind == kind, input.number == number else { return false }
        return channel == nil || channel == input.channel
    }
}

/// A MIDI 1.0 channel voice message. The parser ignores all other message types.
enum MIDIMessage: Equatable {
    /// Channel 1 to 16. A Note On with velocity 0 is a `noteOff`.
    case noteOn(channel: Int, note: Int, velocity: Int)
    case noteOff(channel: Int, note: Int, velocity: Int)
    case controlChange(channel: Int, controller: Int, value: Int)

    /// The kind, channel and number of the message.
    var input: MIDITrigger? {
        switch self {
        case .noteOn(let channel, let note, _), .noteOff(let channel, let note, _):
            return MIDITrigger(kind: .note, channel: channel, number: note)
        case .controlChange(let channel, let controller, _):
            return MIDITrigger(kind: .controlChange, channel: channel, number: controller)
        }
    }

    /// For example "Note On 36 vel 100, ch 10".
    var label: String {
        switch self {
        case .noteOn(let channel, let note, let velocity):
            return "Note On \(note) vel \(velocity), ch \(channel)"
        case .noteOff(let channel, let note, _):
            return "Note Off \(note), ch \(channel)"
        case .controlChange(let channel, let controller, let value):
            return "CC \(controller) value \(value), ch \(channel)"
        }
    }
}

enum MIDIParser {
    /// Parses one channel voice message from its status byte and two data bytes.
    /// Gives nil for a message that is not Note On, Note Off or Control Change.
    static func message(status: UInt8, data1: UInt8, data2: UInt8) -> MIDIMessage? {
        let channel = Int(status & 0x0F) + 1
        let number = Int(data1 & 0x7F)
        let value = Int(data2 & 0x7F)
        switch status & 0xF0 {
        case 0x80:
            return .noteOff(channel: channel, note: number, velocity: value)
        case 0x90:
            if value == 0 { return .noteOff(channel: channel, note: number, velocity: 0) }
            return .noteOn(channel: channel, note: number, velocity: value)
        case 0xB0:
            return .controlChange(channel: channel, controller: number, value: value)
        default:
            return nil
        }
    }

    /// Parses Universal MIDI Packet words. Only message type 2 (MIDI 1.0 channel voice) gives messages.
    /// The parser uses the message type to skip packets of other types and sizes.
    static func messages(fromUMP words: [UInt32]) -> [MIDIMessage] {
        var result: [MIDIMessage] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            let type = Int(word >> 28)
            if type == 0x2, let message = message(
                status: UInt8(word >> 16 & 0xFF),
                data1: UInt8(word >> 8 & 0xFF),
                data2: UInt8(word & 0xFF)) {
                result.append(message)
            }
            index += wordCount(ofType: type)
        }
        return result
    }

    /// The size of a Universal MIDI Packet, in 32-bit words, from its message type.
    static func wordCount(ofType type: Int) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4
        }
    }
}

/// What a MIDI message does to the deck.
enum MIDICommand: Equatable {
    case play(UUID)
    case release(UUID)
    case stopAll
}

/// Converts a message and the mappings into commands.
///
/// A Control Change is "down" at value 64 or more. The matcher acts only when a
/// controller goes from up to down, or from down to up. A knob that sends many values
/// therefore triggers one time, not one time for each value.
struct MIDIMatcher {
    /// The controllers that are down now.
    private(set) var downControllers: Set<MIDITrigger> = []

    /// Gives true for a press, false for a release, and nil for no change.
    mutating func edge(of message: MIDIMessage) -> Bool? {
        switch message {
        case .noteOn: return true
        case .noteOff: return false
        case .controlChange(_, _, let value):
            guard let key = message.input else { return nil }
            let isDown = value >= 64
            let wasDown = downControllers.contains(key)
            guard isDown != wasDown else { return nil }
            if isDown { downControllers.insert(key) } else { downControllers.remove(key) }
            return isDown
        }
    }

    /// `sounds` are the pads of the active deck. `stopAll` is the global Stop All mapping.
    mutating func commands(for message: MIDIMessage, sounds: [SoundItem], stopAll: MIDITrigger?) -> [MIDICommand] {
        guard let isPress = edge(of: message) else { return [] }
        var result: [MIDICommand] = []
        if isPress, let stopAll, stopAll.matches(message) { result.append(.stopAll) }
        for sound in sounds {
            guard let trigger = sound.midiTrigger, trigger.matches(message) else { continue }
            result.append(isPress ? .play(sound.id) : .release(sound.id))
        }
        return result
    }
}
