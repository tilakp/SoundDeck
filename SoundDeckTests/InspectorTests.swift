import Carbon.HIToolbox
import Foundation
import Testing
@testable import SoundDeck

struct KeyRecordingTests {
    @Test func normalizesToLowercase() {
        #expect(KeyRecording.normalized("A") == "a")
        #expect(KeyRecording.normalized("z") == "z")
        #expect(KeyRecording.normalized("7") == "7")
    }

    @Test func rejectsOtherCharacters() {
        for characters in [nil, "", "ab", "!", " ", "å", "é", "-", "\r", "\t"] as [String?] {
            #expect(KeyRecording.normalized(characters) == nil)
        }
    }

    @MainActor
    @Test func allowedCharactersMatchGlobalHotKeys() {
        for character in KeyRecording.allowedCharacters {
            #expect(GlobalHotKeys.keyCode(for: String(character)) != nil)
        }
        #expect(KeyRecording.allowedCharacters.count == 36)
    }

    @Test func actions() {
        let letter = KeyRecording.action(keyCode: UInt16(kVK_ANSI_Q), characters: "Q", commandOrControl: false)
        #expect(letter == .record("q"))
        let digit = KeyRecording.action(keyCode: UInt16(kVK_ANSI_0), characters: "0", commandOrControl: false)
        #expect(digit == .record("0"))
        #expect(KeyRecording.action(keyCode: UInt16(kVK_Escape), characters: "\u{1b}", commandOrControl: false) == .cancel)
        #expect(KeyRecording.action(keyCode: UInt16(kVK_Delete), characters: "\u{7f}", commandOrControl: false) == .clear)
        #expect(KeyRecording.action(keyCode: UInt16(kVK_ForwardDelete), characters: nil, commandOrControl: false) == .clear)
        #expect(KeyRecording.action(keyCode: UInt16(kVK_Return), characters: "\r", commandOrControl: false) == .ignore)
        #expect(KeyRecording.action(keyCode: UInt16(kVK_ANSI_W), characters: "w", commandOrControl: true) == .passThrough)
    }

    @Test func ownerIsAnotherPadWithTheKey() {
        var first = SoundItem(name: "Gong.wav")
        first.hotKey = "G"
        var second = SoundItem(name: "Horn.wav")
        second.hotKey = "1"
        let sounds = [first, second]

        #expect(KeyRecording.owner(of: "g", excluding: second.id, in: sounds)?.id == first.id)
        #expect(KeyRecording.owner(of: "g", excluding: first.id, in: sounds) == nil)
        #expect(KeyRecording.owner(of: "x", excluding: second.id, in: sounds) == nil)
        #expect(KeyRecording.owner(of: "", excluding: second.id, in: sounds) == nil)
    }
}

@MainActor
struct InspectorShapeTests {
    @Test func defaultsKeepShapeClosed() {
        let sound = SoundItem(name: "Gong.wav")
        let custom = SoundInspector.hasCustomShape(
            fadeIn: sound.fadeIn, fadeOut: sound.fadeOut, pitch: sound.pitch, speed: sound.speed
        )
        #expect(!custom)
    }

    @Test func anyChangeOpensShape() {
        let fadeOut = SoundItem.defaultFadeOut
        #expect(SoundInspector.hasCustomShape(fadeIn: 0.1, fadeOut: fadeOut, pitch: 0, speed: 1))
        #expect(SoundInspector.hasCustomShape(fadeIn: 0, fadeOut: 0.5, pitch: 0, speed: 1))
        #expect(SoundInspector.hasCustomShape(fadeIn: 0, fadeOut: fadeOut, pitch: -3, speed: 1))
        #expect(SoundInspector.hasCustomShape(fadeIn: 0, fadeOut: fadeOut, pitch: 0, speed: 1.5))
    }
}
