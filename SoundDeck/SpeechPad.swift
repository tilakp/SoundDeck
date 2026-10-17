import AVFoundation
import Foundation

/// One system voice, as the speech pad sheet shows it.
///
/// The type copies the fields of `AVSpeechSynthesisVoice`. The tests can then make voices without the system list.
struct SpeechVoiceOption: Identifiable, Hashable {
    enum Quality: Int, Comparable {
        case standard, enhanced, premium

        static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    let name: String
    let language: String
    let quality: Quality

    init(id: String, name: String, language: String, quality: Quality) {
        self.id = id
        self.name = name
        self.language = language
        self.quality = quality
    }

    init(_ voice: AVSpeechSynthesisVoice) {
        let quality: Quality
        switch voice.quality {
        case .premium: quality = .premium
        case .enhanced: quality = .enhanced
        default: quality = .standard
        }
        self.init(id: voice.identifier, name: voice.name, language: voice.language, quality: quality)
    }

    /// The name, with the quality when it is better than the standard quality.
    var label: String {
        switch quality {
        case .standard: return name
        case .enhanced: return "\(name) (Enhanced)"
        case .premium: return "\(name) (Premium)"
        }
    }
}

/// The voices of one language.
struct SpeechVoiceGroup: Identifiable, Equatable {
    let language: String
    let title: String
    let voices: [SpeechVoiceOption]

    var id: String { language }
}

enum SpeechPad {
    /// The maximum length of the phrase, in characters.
    static let maxTextLength = 500

    /// The pad name for a phrase: the first four words, at most 32 characters.
    static func defaultName(for text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard !words.isEmpty else { return "Speech" }
        let joined = words.prefix(4).joined(separator: " ")
        return String(joined.prefix(32)).trimmingCharacters(in: .whitespaces)
    }

    /// Groups the voices by language.
    ///
    /// The language of the default voice comes first. The other languages follow in the order of their titles.
    /// In each group, the default voice comes first. Better quality comes next, then the name.
    static func groups(
        _ voices: [SpeechVoiceOption],
        defaultVoiceID: String?,
        locale: Locale = .current
    ) -> [SpeechVoiceGroup] {
        let defaultLanguage = voices.first(where: { $0.id == defaultVoiceID })?.language
        let byLanguage = Dictionary(grouping: voices, by: \.language)

        var groups: [SpeechVoiceGroup] = []
        for (language, members) in byLanguage {
            let sorted = members.sorted { lhs, rhs in
                voiceOrder(lhs, rhs, defaultVoiceID: defaultVoiceID)
            }
            let title = locale.localizedString(forIdentifier: language) ?? language
            groups.append(SpeechVoiceGroup(language: language, title: title, voices: sorted))
        }
        groups.sort { lhs, rhs in
            if (lhs.language == defaultLanguage) != (rhs.language == defaultLanguage) {
                return lhs.language == defaultLanguage
            }
            if lhs.title != rhs.title {
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return lhs.language < rhs.language
        }
        return groups
    }

    private static func voiceOrder(_ lhs: SpeechVoiceOption, _ rhs: SpeechVoiceOption, defaultVoiceID: String?) -> Bool {
        if (lhs.id == defaultVoiceID) != (rhs.id == defaultVoiceID) {
            return lhs.id == defaultVoiceID
        }
        if lhs.quality != rhs.quality {
            return lhs.quality > rhs.quality
        }
        if lhs.name != rhs.name {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    /// The system voices, grouped. The default voice of the current language comes first.
    static func systemGroups() -> (groups: [SpeechVoiceGroup], defaultVoiceID: String?) {
        let voices = AVSpeechSynthesisVoice.speechVoices().map(SpeechVoiceOption.init)
        let defaultID = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())?.identifier
        return (groups(voices, defaultVoiceID: defaultID), defaultID)
    }

    /// Makes an utterance. The rate is in 0...1, where 0.5 is the normal rate. The pitch is in 0.5...2.
    static func utterance(_ text: String, voiceID: String?, rate: Float, pitch: Float) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        if let voiceID, let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
            utterance.voice = voice
        }
        let span = AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate
        utterance.rate = AVSpeechUtteranceMinimumSpeechRate + span * min(max(rate, 0), 1)
        utterance.pitchMultiplier = min(max(pitch, 0.5), 2)
        return utterance
    }
}

enum SpeechRenderError: LocalizedError {
    case noAudio
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noAudio: return "The voice gave no audio. Try a different voice."
        case .cancelled: return "The speech render was cancelled."
        }
    }
}

/// Renders an utterance to a CAF file in the temporary directory.
///
/// `AVSpeechSynthesizer` renders on its own queue and sends PCM buffers to the callback.
/// An empty buffer ends the stream. The renderer then closes the file and returns its URL.
final class SpeechRenderer: @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var file: AVAudioFile?
    private var url: URL?

    func render(_ utterance: AVSpeechUtterance) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            synthesizer.write(utterance) { [self] buffer in
                receive(buffer)
            }
        }
    }

    /// Stops the render and deletes the partial file.
    func cancel() {
        synthesizer.stopSpeaking(at: .immediate)
        finish(.failure(SpeechRenderError.cancelled))
    }

    private func receive(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        guard pcm.frameLength > 0 else {
            finish(nil)
            return
        }
        lock.lock()
        var failure: Error?
        if continuation != nil {
            do {
                try write(pcm)
            } catch {
                failure = error
            }
        }
        lock.unlock()
        if let failure { finish(.failure(failure)) }
    }

    /// Writes one buffer. The first buffer creates the file in its own format. Call this with the lock held.
    private func write(_ pcm: AVAudioPCMBuffer) throws {
        if file == nil {
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent("Speech-\(UUID().uuidString.prefix(8)).caf")
            let format = pcm.format
            file = try AVAudioFile(
                forWriting: target,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            url = target
        }
        try file?.write(from: pcm)
    }

    /// Resumes the caller one time. A nil result means that the stream ended normally.
    private func finish(_ result: Result<URL, Error>?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let url = self.url
        // Releasing the file closes it.
        file = nil
        self.url = nil
        lock.unlock()
        guard let continuation else { return }

        let outcome: Result<URL, Error>
        if let result {
            outcome = result
        } else if let url {
            outcome = .success(url)
        } else {
            outcome = .failure(SpeechRenderError.noAudio)
        }
        if case .failure = outcome, let url {
            try? FileManager.default.removeItem(at: url)
        }
        continuation.resume(with: outcome)
    }
}
