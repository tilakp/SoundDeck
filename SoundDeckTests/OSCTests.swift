import Foundation
import Testing
@testable import SoundDeck

/// Encodes a string with a zero byte and padding to 4 bytes.
private func oscString(_ text: String) -> [UInt8] {
    var bytes = Array(text.utf8) + [0]
    while bytes.count % 4 != 0 { bytes.append(0) }
    return bytes
}

private func bigEndian(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

/// Builds a message from typed arguments.
private func oscMessage(_ address: String, _ arguments: [OSCArgument] = []) -> [UInt8] {
    var tags = ","
    var data: [UInt8] = []
    for argument in arguments {
        switch argument {
        case .int(let value):
            tags += "i"
            data += bigEndian(UInt32(bitPattern: value))
        case .float(let value):
            tags += "f"
            data += bigEndian(value.bitPattern)
        case .string(let value):
            tags += "s"
            data += oscString(value)
        }
    }
    return oscString(address) + oscString(tags) + data
}

private func oscBundle(_ elements: [[UInt8]]) -> [UInt8] {
    var bytes = oscString("#bundle") + [0, 0, 0, 0, 0, 0, 0, 1]
    for element in elements {
        bytes += bigEndian(UInt32(element.count)) + element
    }
    return bytes
}

private func parse(_ bytes: [UInt8]) -> [OSCMessage] {
    OSCParser.messages(in: Data(bytes))
}

struct OSCParserTests {
    @Test func parsesHandBuiltBytes() {
        // "/a" + 2 zero bytes, ",isf" + 4 zero bytes, int 7, float 1.0, "hi" + 2 zero bytes.
        let bytes: [UInt8] = [
            0x2F, 0x61, 0, 0,
            0x2C, 0x69, 0x73, 0x66, 0, 0, 0, 0,
            0, 0, 0, 7,
            0x68, 0x69, 0, 0,
            0x3F, 0x80, 0, 0,
        ]
        #expect(parse(bytes) == [OSCMessage(address: "/a", arguments: [.int(7), .string("hi"), .float(1)])])
    }

    @Test func padsStringsOfEveryLength() {
        for name in ["", "a", "ab", "abc", "abcd", "abcde"] {
            let bytes = oscMessage("/sounddeck/play", [.string(name), .int(-3)])
            #expect(parse(bytes) == [OSCMessage(address: "/sounddeck/play", arguments: [.string(name), .int(-3)])])
        }
    }

    @Test func acceptsAMessageWithoutTypeTags() {
        #expect(parse(oscString("/sounddeck/stop")) == [OSCMessage(address: "/sounddeck/stop", arguments: [])])
    }

    @Test func parsesBundlesAndNestedBundles() {
        let play = oscMessage("/sounddeck/play", [.string("Gong")])
        let stop = oscMessage("/sounddeck/stop")
        let bytes = oscBundle([play, oscBundle([stop])])
        #expect(parse(bytes).map(\.address) == ["/sounddeck/play", "/sounddeck/stop"])
    }

    @Test func rejectsMalformedPacketsWithoutATrap() {
        let good = oscMessage("/sounddeck/play", [.string("Gong"), .float(1)])
        // Each prefix of a good message is incomplete.
        for count in 0..<good.count {
            _ = parse(Array(good.prefix(count)))
        }
        #expect(parse([]) == [])
        #expect(parse([0x2F, 0x61]) == [])                                  // No zero byte.
        #expect(parse(oscString("noslash") + oscString(",")) == [])         // Address without a slash.
        #expect(parse(oscString("/a") + oscString("x")) == [])              // Tags without a comma.
        #expect(parse(oscString("/a") + oscString(",b") + [0, 0, 0, 1]) == []) // Unknown tag.
        #expect(parse(oscString("/a") + oscString(",i") + [0, 0]) == [])    // Short int.
        #expect(parse(oscString("/a") + oscString(",s") + [0x41, 0x42]) == []) // String without a zero byte.

        // A bundle element with a size larger than the packet.
        let message = oscMessage("/a")
        var bundle = oscBundle([message])
        bundle.replaceSubrange(16..<20, with: bigEndian(UInt32.max))
        #expect(parse(bundle) == [])
        // A bundle with a short time tag.
        #expect(parse(oscString("#bundle") + [0, 0]) == [])
        // A bundle element with a size that is not a multiple of 4.
        #expect(parse(oscString("#bundle") + [0, 0, 0, 0, 0, 0, 0, 0] + bigEndian(3) + [0x2F, 0, 0]) == [])

        // Random bytes.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let count = Int.random(in: 0..<64, using: &generator)
            var bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
            if Bool.random(using: &generator) { bytes = oscString("#bundle") + bytes }
            _ = parse(bytes)
        }
    }

    @Test func limitsTheDepthOfBundles() {
        var bytes = oscMessage("/a")
        for _ in 0..<20 { bytes = oscBundle([bytes]) }
        #expect(parse(bytes) == [])
    }
}

struct OSCCommandTests {
    private func command(_ address: String, _ arguments: [OSCArgument] = []) -> OSCCommand? {
        OSCCommand.command(for: OSCMessage(address: address, arguments: arguments))
    }

    @Test func mapsPlay() {
        #expect(command("/sounddeck/play", [.string("Gong")]) == .play("Gong"))
        #expect(command("/sounddeck/play") == nil)
        #expect(command("/sounddeck/play/Gong") == .play("Gong"))
        #expect(command("/sounddeck/play/Sad%20trombone") == .play("Sad trombone"))
    }

    @Test func buttonPressPlaysAndButtonReleaseReleases() {
        #expect(command("/sounddeck/play/Gong", [.float(1)]) == .play("Gong"))
        #expect(command("/sounddeck/play/Gong", [.float(0)]) == .release("Gong"))
        #expect(command("/sounddeck/play/Gong", [.int(1)]) == .play("Gong"))
        #expect(command("/sounddeck/play/Gong", [.int(0)]) == .release("Gong"))
    }

    @Test func mapsReleaseStopAndDeck() {
        #expect(command("/sounddeck/release", [.string("Gong")]) == .release("Gong"))
        #expect(command("/sounddeck/release/Gong") == .release("Gong"))
        #expect(command("/sounddeck/stop") == .stop(nil))
        #expect(command("/sounddeck/stop", [.float(1)]) == .stop(nil))
        #expect(command("/sounddeck/stop", [.string("Gong")]) == .stop("Gong"))
        #expect(command("/sounddeck/stop/Gong") == .stop("Gong"))
        #expect(command("/sounddeck/deck", [.string("Stream")]) == .deck("Stream"))
        #expect(command("/sounddeck/deck/Stream") == .deck("Stream"))
    }

    @Test func ignoresButtonReleaseOnOtherAddresses() {
        #expect(command("/sounddeck/stop", [.float(0)]) == nil)
        #expect(command("/sounddeck/deck/Stream", [.float(0)]) == nil)
        #expect(command("/sounddeck/release/Gong", [.int(0)]) == nil)
    }

    @Test func ignoresOtherAddresses() {
        #expect(command("/other/play", [.string("Gong")]) == nil)
        #expect(command("/sounddeck") == nil)
        #expect(command("/sounddeck/jump", [.string("Gong")]) == nil)
        #expect(command("/sounddeck/play/") == nil)
        #expect(command("/sounddeck/play/a/b") == nil)
        #expect(command("/sounddeck/deck") == nil)
    }
}
