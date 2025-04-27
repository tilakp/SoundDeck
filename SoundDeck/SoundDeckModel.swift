import Foundation

struct SoundItem: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let bookmarkData: Data?
    let isBundled: Bool
    
    var fileURL: URL? {
        if isBundled {
            // For bundled resources, resolve from main bundle
            let resourceURL = Bundle.main.resourceURL
            return resourceURL?.appendingPathComponent(name)
        } else if let bookmarkData = bookmarkData {
            var isStale = false
            do {
                let url = try URL(resolvingBookmarkData: bookmarkData, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
                print("[DEBUG] Resolved bookmark for \(name): \(url.path), stale: \(isStale)")
                return url
            } catch {
                print("[DEBUG] Failed to resolve bookmark for \(name): \(error)")
                return nil
            }
        } else {
            return nil
        }
    }
    
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
    
    func addSound(url: URL) {
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            print("[DEBUG] Created bookmark for: \(url.path)")
            let newSound = SoundItem(name: url.lastPathComponent, bookmarkData: bookmark)
            sounds.append(newSound)
            saveSounds()
        } catch {
            print("[DEBUG] Failed to create bookmark for \(url.path): \(error)")
        }
    }
    
    func removeSound(at offsets: IndexSet) {
        sounds.remove(atOffsets: offsets)
        saveSounds()
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
                let soundItem = SoundItem(name: file.lastPathComponent)
                sounds.append(soundItem)
            }
            saveSounds()
        } catch {
            print("[DEBUG] Could not load default sounds: \(error)")
        }
    }
}
