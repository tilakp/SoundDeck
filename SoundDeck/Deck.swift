import Foundation

/// A named set of pads, for example "Podcast" or "Stream".
/// The keys 1 to 0 and the global hotkeys play the pads of the active deck only.
struct Deck: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var sounds: [SoundItem]

    init(name: String, sounds: [SoundItem] = []) {
        self.id = UUID()
        self.name = name
        self.sounds = sounds
    }

    // Decode leniently, as `SoundItem` does.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Deck"
        sounds = try c.decodeIfPresent([SoundItem].self, forKey: .sounds) ?? []
    }
}
