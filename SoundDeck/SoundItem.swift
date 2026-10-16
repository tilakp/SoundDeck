import Foundation

/// The outcome of turning a `SoundItem` back into a usable file URL.
struct SoundResolution {
    let url: URL
    let refreshedBookmark: Data?
    /// True when the URL's security scope must be opened before reading.
    let needsSecurityScope: Bool
}

/// A colour tag, stored as a stable name rather than a raw value so the palette can
/// be restyled without rewriting saved libraries.
enum SoundTint: String, Codable, CaseIterable, Identifiable {
    case none, amber, rose, violet, teal, lime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        default: return rawValue.capitalized
        }
    }
}

struct SoundItem: Identifiable, Codable, Equatable {
    let id: UUID
    /// Display name. Defaults to the file name but is renamable.
    var name: String
    /// The name of the file. A rename does not change it. A bundled sound and a copied
    /// sound use it to find their file.
    var fileName: String
    var bookmarkData: Data?
    let isBundled: Bool
    /// True when the file is a copy in the library directory, at `<id>/<fileName>`.
    var isCopied: Bool
    /// Whether `bookmarkData` was created with `.withSecurityScope`. A bookmark must
    /// be resolved with the same option it was created with.
    var isSecurityScoped: Bool

    // MARK: Per-sound settings
    var volume: Float
    var loops: Bool
    /// Trim window, in seconds. `trimEnd == nil` means "play to the end".
    var trimStart: Double
    var trimEnd: Double?
    var tint: SoundTint
    var emoji: String?
    /// Single character used as this sound's keyboard trigger.
    var hotKey: String?

    // For bundled
    init(name: String) {
        self.init(name: name, isBundled: true)
    }

    // For a copy in the library directory
    init(copiedFileName fileName: String) {
        self.init(name: fileName, isBundled: false)
        self.isCopied = true
    }

    // For imported
    init(name: String, bookmarkData: Data, isSecurityScoped: Bool) {
        self.init(name: name, isBundled: false)
        self.bookmarkData = bookmarkData
        self.isSecurityScoped = isSecurityScoped
    }

    private init(name: String, isBundled: Bool) {
        self.id = UUID()
        self.name = name
        self.fileName = name
        self.bookmarkData = nil
        self.isBundled = isBundled
        self.isCopied = false
        self.isSecurityScoped = false
        self.volume = 1
        self.loops = false
        self.trimStart = 0
        self.trimEnd = nil
        self.tint = .none
        self.emoji = nil
        self.hotKey = nil
    }

    // Every added field is decoded leniently. Libraries written by earlier builds must
    // keep loading. A strict decoder deletes the whole deck of the user.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? name
        bookmarkData = try c.decodeIfPresent(Data.self, forKey: .bookmarkData)
        isBundled = try c.decode(Bool.self, forKey: .isBundled)
        isCopied = try c.decodeIfPresent(Bool.self, forKey: .isCopied) ?? false
        isSecurityScoped = try c.decodeIfPresent(Bool.self, forKey: .isSecurityScoped) ?? false
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        loops = try c.decodeIfPresent(Bool.self, forKey: .loops) ?? false
        trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? 0
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd)
        tint = try c.decodeIfPresent(SoundTint.self, forKey: .tint) ?? .none
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
        hotKey = try c.decodeIfPresent(String.self, forKey: .hotKey)
    }

    /// Initial for the button badge when no emoji is set.
    var initials: String {
        let letters = name.drop { !$0.isLetter && !$0.isNumber }
        return letters.isEmpty ? "♪" : String(letters.prefix(1)).uppercased()
    }

    /// The location of the copy, if `isCopied` is true.
    func copyURL(in directory: URL) -> URL {
        directory
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// `copies` is the directory that holds the copied sounds.
    func resolve(copies: URL) -> SoundResolution? {
        if isCopied {
            return SoundResolution(url: copyURL(in: copies), refreshedBookmark: nil, needsSecurityScope: false)
        }
        if isBundled {
            guard let resourceURL = Bundle.main.resourceURL else { return nil }
            return SoundResolution(
                url: resourceURL.appendingPathComponent(fileName),
                refreshedBookmark: nil,
                needsSecurityScope: false
            )
        }
        guard let bookmarkData else { return nil }
        let options: URL.BookmarkResolutionOptions = isSecurityScoped ? [.withSecurityScope] : []
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard isStale else {
                return SoundResolution(url: url, refreshedBookmark: nil, needsSecurityScope: isSecurityScoped)
            }
            print("[DEBUG] Bookmark for \(name) is stale; refreshing")
            let didAccess = isSecurityScoped && url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            let refreshed = try? BookmarkFlavor.makeBookmark(for: url, scoped: isSecurityScoped)
            return SoundResolution(url: url, refreshedBookmark: refreshed, needsSecurityScope: isSecurityScoped)
        } catch {
            print("[DEBUG] Failed to resolve bookmark for \(name): \(error)")
            return nil
        }
    }
}

/// Refreshes the bookmarks of pads from earlier builds. New imports are copies and have no bookmark.
/// A bookmark must be made again with the same option that made it.
enum BookmarkFlavor {
    static func makeBookmark(for url: URL, scoped: Bool) throws -> Data {
        try url.bookmarkData(
            options: scoped ? [.withSecurityScope] : [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}
