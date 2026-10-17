import AVFoundation
import Foundation
import Testing
@testable import SoundDeck

struct SpeechPadNameTests {
    @Test func usesTheFirstFourWords() {
        #expect(SpeechPad.defaultName(for: "I will be right back") == "I will be right")
    }

    @Test func shortTextKeepsAllWords() {
        #expect(SpeechPad.defaultName(for: "  Hello  there \n") == "Hello there")
    }

    @Test func collapsesNewlinesAndRuns() {
        #expect(SpeechPad.defaultName(for: "One\n\ntwo\tthree   four five") == "One two three four")
    }

    @Test func limitsTheLengthTo32Characters() {
        let name = SpeechPad.defaultName(for: "Supercalifragilistic expialidocious extraordinarily long")
        #expect(name.count <= 32)
        #expect(name == "Supercalifragilistic expialidoci")
    }

    @Test func doesNotEndWithASpaceAfterTheCut() {
        // The cut at 32 characters falls just after a space.
        let name = SpeechPad.defaultName(for: "abcdefghijklmnopqrstuvwxyz12345 next")
        #expect(name == "abcdefghijklmnopqrstuvwxyz12345")
    }

    @Test func emptyTextGivesAFallback() {
        #expect(SpeechPad.defaultName(for: "") == "Speech")
        #expect(SpeechPad.defaultName(for: " \n ") == "Speech")
    }
}

struct SpeechVoiceGroupTests {
    private let locale = Locale(identifier: "en_US")

    private func voice(_ id: String, _ name: String, _ language: String, _ quality: SpeechVoiceOption.Quality = .standard) -> SpeechVoiceOption {
        SpeechVoiceOption(id: id, name: name, language: language, quality: quality)
    }

    private var voices: [SpeechVoiceOption] {
        [
            voice("fr.thomas", "Thomas", "fr-FR"),
            voice("en.zoe", "Zoe", "en-US", .premium),
            voice("de.anna", "Anna", "de-DE"),
            voice("en.alex", "Alex", "en-US"),
            voice("en.samantha", "Samantha", "en-US"),
            voice("en.ava", "Ava", "en-US", .enhanced),
            voice("fr.amelie", "Amélie", "fr-FR", .enhanced),
        ]
    }

    @Test func defaultLanguageComesFirstAndOthersSortByTitle() {
        let groups = SpeechPad.groups(voices, defaultVoiceID: "fr.thomas", locale: locale)
        #expect(groups.map(\.language) == ["fr-FR", "en-US", "de-DE"])
        #expect(groups.map(\.title) == ["French (France)", "English (United States)", "German (Germany)"])
    }

    @Test func defaultVoiceFirstThenQualityThenName() {
        let groups = SpeechPad.groups(voices, defaultVoiceID: "en.samantha", locale: locale)
        #expect(groups.first?.language == "en-US")
        #expect(groups.first?.voices.map(\.id) == ["en.samantha", "en.zoe", "en.ava", "en.alex"])
    }

    @Test func unknownDefaultSortsAllGroupsByTitle() {
        let groups = SpeechPad.groups(voices, defaultVoiceID: nil, locale: locale)
        #expect(groups.map(\.language) == ["en-US", "fr-FR", "de-DE"])
        let french = groups.first { $0.language == "fr-FR" }
        #expect(french?.voices.map(\.id) == ["fr.amelie", "fr.thomas"])
    }

    @Test func labelShowsBetterQuality() {
        #expect(voice("a", "Ava", "en-US").label == "Ava")
        #expect(voice("a", "Ava", "en-US", .enhanced).label == "Ava (Enhanced)")
        #expect(voice("a", "Ava", "en-US", .premium).label == "Ava (Premium)")
    }

    @Test func noVoicesGiveNoGroups() {
        #expect(SpeechPad.groups([], defaultVoiceID: nil, locale: locale).isEmpty)
    }
}

struct SpeechRenderTests {
    private static var hasVoice: Bool { !AVSpeechSynthesisVoice.speechVoices().isEmpty }

    @Test(.enabled(if: hasVoice, "No system voice is available"), .timeLimit(.minutes(1)))
    func rendersAShortPhraseToAFileWithFrames() async throws {
        let utterance = SpeechPad.utterance("Hello", voiceID: nil, rate: 0.5, pitch: 1)
        let url = try await SpeechRenderer().render(utterance)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(url.pathExtension == "caf")
        let file = try AVAudioFile(forReading: url)
        #expect(file.length > 0)
    }
}
