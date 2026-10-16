import Foundation

/// One argument of an OSC message.
enum OSCArgument: Equatable {
    case int(Int32)
    case float(Float)
    case string(String)

    /// The value as a number, or nil for a string.
    var number: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .float(let value): return Double(value)
        case .string: return nil
        }
    }

    /// The value as text, or nil for a number.
    var text: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

/// One OSC 1.0 message: an address pattern and its arguments.
struct OSCMessage: Equatable {
    let address: String
    let arguments: [OSCArgument]
}

/// A parser for OSC 1.0 packets. It has no state and no side effects.
///
/// The parser reads the type tags `i`, `f` and `s`. A message with a different tag is
/// not valid, because the parser cannot know the size of its data. A malformed packet
/// gives no messages. The parser never traps on bad input.
enum OSCParser {
    /// The maximum depth of bundles in bundles.
    static let maximumBundleDepth = 8

    /// Returns the messages in a packet. A bundle gives the messages of all its elements,
    /// in order. The parser ignores the time tag and runs each message at once.
    static func messages(in data: Data) -> [OSCMessage] {
        messages(in: [UInt8](data), depth: 0)
    }

    static func messages(in bytes: [UInt8], depth: Int) -> [OSCMessage] {
        guard depth <= maximumBundleDepth, let first = bytes.first else { return [] }
        if first == UInt8(ascii: "#") { return bundleMessages(in: bytes, depth: depth) }
        if let message = message(in: bytes) { return [message] }
        return []
    }

    /// Parses one message. Returns nil when the message is malformed.
    static func message(in bytes: [UInt8]) -> OSCMessage? {
        var reader = Reader(bytes: bytes)
        guard let address = reader.string(), address.hasPrefix("/") else { return nil }
        // An old sender can omit the type tag string. Then the message has no arguments.
        guard !reader.isAtEnd else { return OSCMessage(address: address, arguments: []) }
        guard let tags = reader.string(), tags.hasPrefix(",") else { return nil }
        var arguments: [OSCArgument] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "i":
                guard let value = reader.uint32() else { return nil }
                arguments.append(.int(Int32(bitPattern: value)))
            case "f":
                guard let value = reader.uint32() else { return nil }
                arguments.append(.float(Float(bitPattern: value)))
            case "s":
                guard let value = reader.string() else { return nil }
                arguments.append(.string(value))
            default:
                return nil
            }
        }
        return OSCMessage(address: address, arguments: arguments)
    }

    /// Parses a bundle: `#bundle`, an 8-byte time tag, then elements with a 4-byte size each.
    private static func bundleMessages(in bytes: [UInt8], depth: Int) -> [OSCMessage] {
        var reader = Reader(bytes: bytes)
        guard reader.string() == "#bundle", reader.skip(8) else { return [] }
        var result: [OSCMessage] = []
        while !reader.isAtEnd {
            guard let size = reader.uint32(), size % 4 == 0,
                  let element = reader.take(Int(size)) else { return result }
            result += messages(in: element, depth: depth + 1)
        }
        return result
    }

    /// Reads big-endian values and padded strings. Each read checks the bounds.
    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        var isAtEnd: Bool { offset >= bytes.count }

        mutating func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, count <= bytes.count - offset else { return nil }
            defer { offset += count }
            return Array(bytes[offset..<offset + count])
        }

        mutating func skip(_ count: Int) -> Bool {
            take(count) != nil
        }

        mutating func uint32() -> UInt32? {
            guard let word = take(4) else { return nil }
            return word.reduce(0) { ($0 << 8) | UInt32($1) }
        }

        /// Reads a string that ends with a zero byte and pads to a multiple of 4 bytes.
        mutating func string() -> String? {
            guard let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            let text = String(decoding: bytes[offset..<end], as: UTF8.self)
            let padded = (end - offset) / 4 * 4 + 4
            guard skip(padded) else { return nil }
            return text
        }
    }
}

/// A deck command that an OSC message asks for.
enum OSCCommand: Equatable {
    case play(String)
    case release(String)
    /// Stops one pad, or all pads when the value is nil.
    case stop(String?)
    case deck(String)

    /// The root of all Sound Deck addresses.
    static let root = "/sounddeck/"

    /// Maps a message to a command. Returns nil when the message is not for Sound Deck.
    ///
    /// The pad or deck comes from the first string argument, or from the address part
    /// after the verb (`/sounddeck/play/Gong`). The address part can use percent escapes.
    /// A control surface button sends 1 on press and 0 on release. On `/sounddeck/play/<pad>`,
    /// a number that is not 0 plays the pad and 0 releases it. On the other addresses,
    /// the parser ignores a 0, so that a button release does not run the command again.
    static func command(for message: OSCMessage) -> OSCCommand? {
        guard message.address.hasPrefix(root) else { return nil }
        let parts = message.address.dropFirst(root.count).split(separator: "/", omittingEmptySubsequences: false)
        guard let verb = parts.first, parts.count <= 2 else { return nil }
        var target: String?
        if parts.count == 2 {
            target = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            if target?.isEmpty == true { return nil }
        }
        let first = message.arguments.first
        let pressed = first?.number.map { $0 != 0 } ?? true

        if verb == "play", let target {
            return pressed ? .play(target) : .release(target)
        }
        guard pressed else { return nil }
        let name = target ?? first?.text
        switch verb {
        case "play": return name.map { .play($0) }
        case "release": return name.map { .release($0) }
        case "stop": return .stop(name)
        case "deck": return name.map { .deck($0) }
        default: return nil
        }
    }
}
