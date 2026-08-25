import Foundation

/// The outcome of turning a `SoundItem` back into a usable file URL.
///
/// Imported sounds are stored as security-scoped bookmarks, which macOS can mark
/// stale when the underlying file moves or the OS updates. A stale bookmark still
/// resolves, but only once — it has to be rewritten or the next launch loses the
/// file. `refreshedBookmark` carries that new data back to the model.
struct SoundResolution {
    let url: URL
    let refreshedBookmark: Data?
}

struct SoundItem: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var bookmarkData: Data?
    let isBundled: Bool

    // For bundled
    init(name: String) {
        self.id = UUID()
        self.name = name
        self.bookmarkData = nil
        self.isBundled = true
    }

    // For imported
    init(name: String, bookmarkData: Data) {
        self.id = UUID()
        self.name = name
        self.bookmarkData = bookmarkData
        self.isBundled = false
    }

    func resolve() -> SoundResolution? {
        if isBundled {
            guard let resourceURL = Bundle.main.resourceURL else { return nil }
            return SoundResolution(url: resourceURL.appendingPathComponent(name), refreshedBookmark: nil)
        }
        guard let bookmarkData else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard isStale else {
                return SoundResolution(url: url, refreshedBookmark: nil)
            }
            // Rewriting a stale bookmark requires the security scope to be open.
            print("[DEBUG] Bookmark for \(name) is stale; refreshing")
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            let refreshed = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return SoundResolution(url: url, refreshedBookmark: refreshed)
        } catch {
            print("[DEBUG] Failed to resolve bookmark for \(name): \(error)")
            return nil
        }
    }
}

enum SoundImportError: LocalizedError {
    case bookmarkFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .bookmarkFailed(let underlying):
            return "Could not keep access to that file: \(underlying.localizedDescription)"
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
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            print("[DEBUG] Created bookmark for: \(url.path)")
            sounds.append(SoundItem(name: url.lastPathComponent, bookmarkData: bookmark))
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

    /// Resolves a sound to a URL, persisting a refreshed bookmark if macOS handed
    /// one back. Callers still own opening the security scope around actual reads.
    func resolve(_ sound: SoundItem) -> URL? {
        guard let resolution = sound.resolve() else { return nil }
        if let refreshed = resolution.refreshedBookmark,
           let index = sounds.firstIndex(where: { $0.id == sound.id }) {
            sounds[index].bookmarkData = refreshed
            saveSounds()
        }
        return resolution.url
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
