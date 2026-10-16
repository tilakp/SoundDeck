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

/// What a trigger does to a pad.
enum PlayMode: String, Codable, CaseIterable, Identifiable {
    /// Each trigger adds a voice. Voices play at the same time.
    case layer
    /// A trigger stops the voices of the pad and plays it from the start.
    case restart
    /// A trigger plays the pad. The next trigger stops it.
    case toggle
    /// The pad plays while the key or the mouse button is down.
    case hold

    var id: String { rawValue }

    var label: String {
        switch self {
        case .layer: return "Play over"
        case .restart: return "Restart"
        case .toggle: return "Toggle"
        case .hold: return "Hold"
        }
    }

    /// The badge on the pad. The default mode has no badge.
    var symbol: String? {
        switch self {
        case .layer: return nil
        case .restart: return "arrow.counterclockwise"
        case .toggle: return "power"
        case .hold: return "hand.point.up.left"
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

    // MARK: Loudness
    /// Integrated loudness in LUFS. Nil before the measurement and for a silent file.
    var measuredLoudness: Double?
    /// The sample peak. Nil until the library measures the file.
    var measuredPeak: Float?
    /// When true, the engine moves the pad to the target loudness.
    var matchesLoudness: Bool

    var isMeasured: Bool { measuredPeak != nil }

    // MARK: Play behavior
    var playMode: PlayMode
    /// 1 to 4. A pad stops the other pads in its group. Nil means no group.
    var chokeGroup: Int?
    /// While this pad plays, the other pads go down by `AudioEngine.duckLevel`.
    var ducksOthers: Bool
    /// Seconds.
    var fadeIn: Double
    /// Seconds. A short fade prevents a click when a pad stops.
    var fadeOut: Double
    /// Semitones, from -12 to 12.
    var pitch: Double
    /// Playback rate, from 0.5 to 2.
    var speed: Double

    static let defaultFadeOut = 0.12

    /// The gain that `matchesLoudness` adds. The user volume multiplies it.
    var loudnessGain: Float {
        matchesLoudness ? Loudness.gain(lufs: measuredLoudness, peak: measuredPeak) : 1
    }

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
        // The extension is noise on a pad: "Gong.wav" shows as "Gong".
        self.name = Self.displayName(forFileName: name)
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
        self.measuredLoudness = nil
        self.measuredPeak = nil
        self.matchesLoudness = true
        self.playMode = .layer
        self.chokeGroup = nil
        self.ducksOthers = false
        self.fadeIn = 0
        self.fadeOut = Self.defaultFadeOut
        self.pitch = 0
        self.speed = 1
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
        // A tint from a newer build is not an error. The pad gets no tint.
        tint = (try? c.decodeIfPresent(SoundTint.self, forKey: .tint)) ?? .none
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
        hotKey = try c.decodeIfPresent(String.self, forKey: .hotKey)
        measuredLoudness = try c.decodeIfPresent(Double.self, forKey: .measuredLoudness)
        measuredPeak = try c.decodeIfPresent(Float.self, forKey: .measuredPeak)
        matchesLoudness = try c.decodeIfPresent(Bool.self, forKey: .matchesLoudness) ?? true
        playMode = (try? c.decodeIfPresent(PlayMode.self, forKey: .playMode)) ?? .layer
        chokeGroup = try c.decodeIfPresent(Int.self, forKey: .chokeGroup)
        ducksOthers = try c.decodeIfPresent(Bool.self, forKey: .ducksOthers) ?? false
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? Self.defaultFadeOut
        pitch = try c.decodeIfPresent(Double.self, forKey: .pitch) ?? 0
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
    }

    /// Initial for the button badge when no emoji is set.
    var initials: String {
        let letters = name.drop { !$0.isLetter && !$0.isNumber }
        return letters.isEmpty ? "♪" : String(letters.prefix(1)).uppercased()
    }

    /// The file name without its extension. A name that is only an extension stays as it is.
    static func displayName(forFileName fileName: String) -> String {
        let stripped = (fileName as NSString).deletingPathExtension
        return stripped.isEmpty ? fileName : stripped
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
