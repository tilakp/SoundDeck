import Foundation

/// A named set of pads, for example "Podcast" or "Stream".
/// The keys 1 to 0 and the global hotkeys play the pads of the active deck only.
struct Deck: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var sounds: [SoundItem]
    /// How the window shows the pads of this deck.
    var layout: DeckLayout = .grid
    /// The standby cue of the cue list. The value `sounds.count` means "End".
    /// This is runtime state. The library file does not keep it.
    var cueIndex = 0

    private enum CodingKeys: String, CodingKey {
        case id, name, sounds, layout
    }

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
        sounds = (try c.decodeIfPresent([Lossy<SoundItem>].self, forKey: .sounds) ?? []).compactMap(\.value)
        // A layout from a newer build is not an error. The deck shows the grid.
        layout = (try? c.decodeIfPresent(DeckLayout.self, forKey: .layout)) ?? .grid
    }
}

/// The two views of a deck: a grid of pads, or an ordered cue list with a Go control.
enum DeckLayout: String, Codable, CaseIterable, Identifiable {
    case grid, cueList

    var id: String { rawValue }

    var label: String {
        switch self {
        case .grid: return "Grid"
        case .cueList: return "List"
        }
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
