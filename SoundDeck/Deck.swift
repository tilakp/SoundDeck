import Foundation

/// A named set of pads, for example "Podcast" or "Stream".
/// The keys 1 to 0 and the global hotkeys play the pads of the active deck only.
struct Deck: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var sounds: [SoundItem]
    /// A locked deck refuses changes to its pads and to the deck. Its pads still play.
    var isLocked: Bool

    init(name: String, sounds: [SoundItem] = [], isLocked: Bool = false) {
        self.id = UUID()
        self.name = name
        self.sounds = sounds
        self.isLocked = isLocked
    }

    // Decode leniently, as `SoundItem` does.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Deck"
        sounds = (try c.decodeIfPresent([Lossy<SoundItem>].self, forKey: .sounds) ?? []).compactMap(\.value)
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
    }
}

/// Decodes one item of an array. A bad item gives nil, and the other items still load.
/// The store keeps a backup of the file when it skips an item.
struct Lossy<Value: Codable>: Codable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}
