import Foundation

/// The outcome of turning a `SoundItem` back into a usable file URL.
///
/// Imported sounds are stored as bookmarks. macOS can mark a bookmark stale when the
/// underlying file moves or the OS updates; a stale bookmark still resolves, but only
/// once — it has to be rewritten or the next launch loses the file.
/// `refreshedBookmark` carries that new data back to the model.
struct SoundResolution {
    let url: URL
    let refreshedBookmark: Data?
    /// True when the URL's security scope must be opened before reading.
    let needsSecurityScope: Bool
}

struct SoundItem: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var bookmarkData: Data?
    let isBundled: Bool
    /// Whether `bookmarkData` was created with `.withSecurityScope`. Resolving a
    /// bookmark requires the same option it was created with, and this app falls back
    /// to plain bookmarks when scoped ones are unavailable — see `BookmarkFlavor`.
    var isSecurityScoped: Bool

    // For bundled
    init(name: String) {
        self.id = UUID()
        self.name = name
        self.bookmarkData = nil
        self.isBundled = true
        self.isSecurityScoped = false
    }

    // For imported
    init(name: String, bookmarkData: Data, isSecurityScoped: Bool) {
        self.id = UUID()
        self.name = name
        self.bookmarkData = bookmarkData
        self.isBundled = false
        self.isSecurityScoped = isSecurityScoped
    }

    // Decoded explicitly so sound lists saved before `isSecurityScoped` existed still
    // load; the synthesised initialiser would reject them for the missing key.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        isBundled = try container.decode(Bool.self, forKey: .isBundled)
        isSecurityScoped = try container.decodeIfPresent(Bool.self, forKey: .isSecurityScoped) ?? false
    }

    func resolve() -> SoundResolution? {
        if isBundled {
            guard let resourceURL = Bundle.main.resourceURL else { return nil }
            return SoundResolution(
                url: resourceURL.appendingPathComponent(name),
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
            // Rewriting a scoped bookmark requires the security scope to be open.
            let didAccess = isSecurityScoped && url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            let refreshed = try? BookmarkFlavor.makeBookmark(for: url, scoped: isSecurityScoped)
            return SoundResolution(
                url: url,
                refreshedBookmark: refreshed,
                needsSecurityScope: isSecurityScoped
            )
        } catch {
            print("[DEBUG] Failed to resolve bookmark for \(name): \(error)")
            return nil
        }
    }
}

/// Chooses between security-scoped and plain bookmarks at runtime.
///
/// Security-scoped bookmarks are the right tool for a sandboxed app, but creating one
/// binds it to the app's code-signing identity. An ad-hoc signed build (no Developer
/// Team ID) has no stable identity to bind to, and creation fails with
/// NSCocoaErrorDomain 256 even when the file is perfectly readable. Rather than
/// hardcode either behaviour, try the scoped form first and fall back to a plain
/// bookmark — which is sufficient for an unsandboxed app and keeps imported sounds
/// working across launches.
enum BookmarkFlavor {
    struct Result {
        let data: Data
        let isSecurityScoped: Bool
    }

    static func makeBookmark(for url: URL, scoped: Bool) throws -> Data {
        try url.bookmarkData(
            options: scoped ? [.withSecurityScope] : [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func create(for url: URL) throws -> Result {
        do {
            let data = try makeBookmark(for: url, scoped: true)
            return Result(data: data, isSecurityScoped: true)
        } catch {
            let ns = error as NSError
            print("[DEBUG] Security-scoped bookmark unavailable (\(ns.domain) \(ns.code)); using a plain bookmark")
            let data = try makeBookmark(for: url, scoped: false)
            return Result(data: data, isSecurityScoped: false)
        }
    }
}

enum SoundImportError: LocalizedError {
    case bookmarkFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .bookmarkFailed(let underlying):
            let ns = underlying as NSError
            return "Could not keep access to that file: \(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
        }
    }
}

class SoundDeckModel: ObservableObject {
    @Published var sounds: [SoundItem] = []

    private let saveKey = "SoundDeckSounds"

    init() {
        loadSounds()
        if sounds.isEmpty {
            loadDefaultSounds()
        }
    }

    /// The single entry point for adding a user-selected file. The file importer in
    /// ContentView used to duplicate this logic; it now calls through here.
    func addSound(url: URL) throws {
        // The picker hands back a URL whose scope must be open to bookmark it.
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try BookmarkFlavor.create(for: url)
            guard !sounds.contains(where: { $0.name == url.lastPathComponent && !$0.isBundled }) else {
                print("[DEBUG] Skipping duplicate import: \(url.lastPathComponent)")
                return
            }
            print("[DEBUG] Created bookmark for: \(url.path) (scoped: \(bookmark.isSecurityScoped))")
            sounds.append(SoundItem(
                name: url.lastPathComponent,
                bookmarkData: bookmark.data,
                isSecurityScoped: bookmark.isSecurityScoped
            ))
            saveSounds()
        } catch {
            print("[DEBUG] Failed to create bookmark for \(url.path): \(error)")
            throw SoundImportError.bookmarkFailed(underlying: error)
        }
    }

    func remove(_ sound: SoundItem) {
        sounds.removeAll { $0.id == sound.id }
        saveSounds()
    }

    func removeSound(at offsets: IndexSet) {
        sounds.remove(atOffsets: offsets)
        saveSounds()
    }

    /// Resolves a sound to a URL, persisting a refreshed bookmark if macOS handed one
    /// back. Callers still own opening the security scope around actual reads.
    func resolve(_ sound: SoundItem) -> SoundResolution? {
        guard let resolution = sound.resolve() else { return nil }
        if let refreshed = resolution.refreshedBookmark,
           let index = sounds.firstIndex(where: { $0.id == sound.id }) {
            sounds[index].bookmarkData = refreshed
            saveSounds()
        }
        return resolution
    }

    func saveSounds() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(sounds) {
            UserDefaults.standard.set(data, forKey: saveKey)
            print("[DEBUG] Saved \(sounds.count) sounds to UserDefaults")
        }
    }

    private func loadSounds() {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let saved = try? decoder.decode([SoundItem].self, from: data) {
            sounds = saved
            print("[DEBUG] Loaded \(sounds.count) sounds from UserDefaults")
        } else {
            print("[DEBUG] No sounds loaded from UserDefaults")
        }
    }

    private func loadDefaultSounds() {
        let fileManager = FileManager.default
        guard let resourceURL = Bundle.main.resourceURL else { return }
        do {
            let files = try fileManager.contentsOfDirectory(at: resourceURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            for file in files where file.isFileURL && (file.pathExtension.lowercased() == "wav" || file.pathExtension.lowercased() == "aiff") {
                sounds.append(SoundItem(name: file.lastPathComponent))
            }
            saveSounds()
        } catch {
            print("[DEBUG] Could not load default sounds: \(error)")
        }
    }
}
