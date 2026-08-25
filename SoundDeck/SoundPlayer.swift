import AVFoundation
import Foundation

/// Owns audio playback and the state that depends on it.
///
/// This used to live as `@State` inside ContentView, which meant nothing observed
/// `AVAudioPlayer` finishing — a sound that played to its natural end left the UI
/// stuck showing it as playing until Stop was pressed. Holding the player in an
/// observable object lets the delegate callback clear that state.
///
/// Identity is tracked by `SoundItem.id`, not by filename: two files with the same
/// name previously highlighted each other.
@MainActor
final class SoundPlayer: NSObject, ObservableObject {
    @Published private(set) var playingID: UUID?
    @Published private(set) var lastPlayedID: UUID?
    @Published private(set) var waveformSamples: [Float]?

    private var player: AVAudioPlayer?
    /// The security scope currently held open for `player`. Imported files stay
    /// accessible only while their scope is open, so it is released on stop rather
    /// than immediately after loading.
    private var scopedURL: URL?
    /// Guards against a stale async waveform result overwriting a newer one.
    private var waveformToken = UUID()

    enum PlaybackError: LocalizedError {
        case unresolved(name: String)
        case unreadable(path: String)
        case decodeFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .unresolved(let name):
                return "Could not locate “\(name)”. It may have been moved or deleted."
            case .unreadable(let path):
                return "No permission to read the file at \(path)."
            case .decodeFailed(let underlying):
                return "Could not play that sound: \(underlying.localizedDescription)"
            }
        }
    }

    func play(_ sound: SoundItem, in model: SoundDeckModel) throws {
        guard let url = model.resolve(sound) else {
            throw PlaybackError.unresolved(name: sound.name)
        }

        stop()

        let didAccess = url.startAccessingSecurityScopedResource()
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            if didAccess { url.stopAccessingSecurityScopedResource() }
            throw PlaybackError.unreadable(path: url.path)
        }

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            newPlayer.play()
            player = newPlayer
            scopedURL = didAccess ? url : nil
            playingID = sound.id
            lastPlayedID = sound.id
            print("[DEBUG] Playback started for: \(url.lastPathComponent)")
        } catch {
            if didAccess { url.stopAccessingSecurityScopedResource() }
            throw PlaybackError.decodeFailed(underlying: error)
        }

        loadWaveform(for: url)
    }

    func stop() {
        player?.stop()
        player = nil
        releaseScope()
        playingID = nil
        waveformSamples = nil
        waveformToken = UUID()
    }

    func replayLast(in model: SoundDeckModel) throws {
        guard let lastPlayedID,
              let sound = model.sounds.first(where: { $0.id == lastPlayedID }) else { return }
        try play(sound, in: model)
    }

    private func releaseScope() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    private func loadWaveform(for url: URL) {
        let token = UUID()
        waveformToken = token
        AVAsset(url: url).waveformSamples(sampleCount: 500) { [weak self] samples in
            Task { @MainActor in
                guard let self, self.waveformToken == token else { return }
                self.waveformSamples = samples
            }
        }
    }
}

extension SoundPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            // Ignore a callback from a player we already replaced.
            guard self.player === player else { return }
            self.stop()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("[DEBUG] Decode error during playback: \(String(describing: error))")
        Task { @MainActor in
            guard self.player === player else { return }
            self.stop()
        }
    }
}
