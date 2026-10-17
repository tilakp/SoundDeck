import Foundation
import UniformTypeIdentifiers

/// One deck in one file: the settings and the audio of each pad.
///
/// The file is JSON, and the audio is Base64 text. It is larger than a ZIP file, but
/// it needs no extra library. A soundboard deck is usually a few megabytes.
struct DeckArchive: Codable {
    static let fileExtension = "sounddeck"
    static let formatName = "SoundDeck.deck"
    static let currentVersion = 1

    static var contentType: UTType {
        UTType(filenameExtension: fileExtension, conformingTo: .json) ?? .json
    }

    struct Entry: Codable {
        var name: String
        var fileName: String
        var volume: Float
        var loops: Bool
        var trimStart: Double
        var trimEnd: Double?
        var tint: SoundTint
        var emoji: String?
        var hotKey: String?
        /// Nil in files from version 2.1 of the application.
        var matchesLoudness: Bool?
        var playMode: PlayMode?
        var chokeGroup: Int?
        var ducksOthers: Bool?
        var fadeIn: Double?
        var fadeOut: Double?
        var pitch: Double?
        var speed: Double?
        var credit: String?
        var audio: Data
    }

    var format: String
    var version: Int
    var name: String
    var sounds: [Entry]
}

enum DeckArchiveError: LocalizedError {
    case notADeck
    case missingAudio(name: String)

    var errorDescription: String? {
        switch self {
        case .notADeck:
            return "That file is not a Sound Deck deck."
        case .missingAudio(let name):
            return "Could not read the audio of “\(name)”. Remove the pad or add the file again, then export again."
        }
    }
}

extension SoundLibrary {
    /// Makes the file for a deck. Every pad must have a readable audio file.
    func exportArchive(of deckID: UUID) throws -> Data {
        guard let deck = decks.first(where: { $0.id == deckID }) else { throw DeckArchiveError.notADeck }
        let entries = try deck.sounds.map { sound in
            guard let resolution = resolve(sound) else { throw DeckArchiveError.missingAudio(name: sound.name) }
            let url = resolution.url
            let didAccess = resolution.needsSecurityScope && url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            guard let audio = try? Data(contentsOf: url) else { throw DeckArchiveError.missingAudio(name: sound.name) }
            return DeckArchive.Entry(
                name: sound.name,
                fileName: url.lastPathComponent,
                volume: sound.volume,
                loops: sound.loops,
                trimStart: sound.trimStart,
                trimEnd: sound.trimEnd,
                tint: sound.tint,
                emoji: sound.emoji,
                hotKey: sound.hotKey,
                matchesLoudness: sound.matchesLoudness,
                playMode: sound.playMode,
                chokeGroup: sound.chokeGroup,
                ducksOthers: sound.ducksOthers,
                fadeIn: sound.fadeIn,
                fadeOut: sound.fadeOut,
                pitch: sound.pitch,
                speed: sound.speed,
                credit: sound.credit,
                audio: audio
            )
        }
        let archive = DeckArchive(
            format: DeckArchive.formatName,
            version: DeckArchive.currentVersion,
            name: deck.name,
            sounds: entries
        )
        return try JSONEncoder().encode(archive)
    }

    /// Adds the deck in the file as a new deck, and makes it the active deck.
    /// Each pad gets a new id, so the same file can be imported more than one time.
    @discardableResult
    func importArchive(_ data: Data) throws -> Deck {
        guard let archive = try? JSONDecoder().decode(DeckArchive.self, from: data),
              archive.format == DeckArchive.formatName else {
            throw DeckArchiveError.notADeck
        }
        var files: [UUID: Data] = [:]
        let sounds = archive.sounds.map { entry in
            // The file can come from another person. Keep the copy in the directory of its pad.
            let fileName = (entry.fileName as NSString).lastPathComponent
            let isSafe = !fileName.isEmpty && fileName != "." && fileName != ".."
            var item = SoundItem(copiedFileName: isSafe ? fileName : "Sound")
            item.name = entry.name
            item.volume = entry.volume
            item.loops = entry.loops
            item.trimStart = entry.trimStart
            item.trimEnd = entry.trimEnd
            item.tint = entry.tint
            item.emoji = entry.emoji
            item.hotKey = entry.hotKey
            item.matchesLoudness = entry.matchesLoudness ?? true
            item.playMode = entry.playMode ?? .layer
            item.chokeGroup = entry.chokeGroup
            item.ducksOthers = entry.ducksOthers ?? false
            item.fadeIn = entry.fadeIn ?? 0
            item.fadeOut = entry.fadeOut ?? SoundItem.defaultFadeOut
            item.pitch = entry.pitch ?? 0
            item.speed = entry.speed ?? 1
            item.credit = entry.credit
            files[item.id] = entry.audio
            return item
        }
        try addDeck(Deck(name: archive.name, sounds: sounds), files: files)
        return activeDeck
    }
}
