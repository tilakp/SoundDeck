import AVFoundation
import CoreAudio
import Foundation

/// Playback for the whole deck.
///
/// Replaces the original single `AVAudioPlayer`, which could only hold one sound at a
/// time. Every new trigger cut off the previous one. An `AVAudioEngine` graph gives
/// each trigger its own voice, so sounds layer, and adds three things the old player
/// could not do at all: per-sound gain, a fade-out instead of a hard cut, and
/// choosing which output device the deck plays into.
///
/// Graph shape, one branch per active voice:
///
///     AVAudioPlayerNode ──▶ AVAudioMixerNode ──▶ mainMixerNode ──▶ outputNode
///                            (per-voice gain,      (master gain)     (routable)
///                             fade envelope)
@MainActor
final class AudioEngine: ObservableObject {

    /// One sounding instance. A single `SoundItem` can have several at once.
    private final class Voice {
        let id = UUID()
        let soundID: UUID
        let player: AVAudioPlayerNode
        let mixer: AVAudioMixerNode
        let scopedURL: URL?
        let duration: Double
        let startOffset: Double
        var startedAt: TimeInterval
        var fadeTimer: Timer?

        init(soundID: UUID, player: AVAudioPlayerNode, mixer: AVAudioMixerNode,
             scopedURL: URL?, duration: Double, startOffset: Double) {
            self.soundID = soundID
            self.player = player
            self.mixer = mixer
            self.scopedURL = scopedURL
            self.duration = duration
            self.startOffset = startOffset
            self.startedAt = CACurrentMediaTime()
        }
    }

    enum PlaybackError: LocalizedError {
        case unresolved(name: String)
        case unreadable(path: String)
        case decodeFailed(underlying: Error)
        case engineFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .unresolved(let name):
                return "Could not locate “\(name)”. It may have been moved or deleted."
            case .unreadable(let path):
                return "No permission to read the file at \(path)."
            case .decodeFailed(let underlying):
                return "Could not play that sound: \(underlying.localizedDescription)"
            case .engineFailed(let underlying):
                return "Audio engine could not start: \(underlying.localizedDescription)"
            }
        }
    }

    // MARK: Published state

    /// Sounds with at least one voice currently sounding.
    @Published private(set) var playingIDs: Set<UUID> = []
    @Published private(set) var lastPlayedID: UUID?
    /// 0...1 progress of the most recently started voice, for the waveform playhead.
    @Published private(set) var progress: Double = 0
    @Published private(set) var focusedSoundID: UUID?
    @Published private(set) var waveform: [Float]?

    @Published var masterVolume: Float = 0.9 {
        didSet {
            engine.mainMixerNode.outputVolume = masterVolume
            UserDefaults.standard.set(masterVolume, forKey: Self.masterVolumeKey)
        }
    }

    @Published private(set) var outputDevices: [AudioDevice] = []
    /// `nil` means "follow the system default output".
    @Published private(set) var selectedDeviceUID: String?

    /// Seconds to ramp down over when stopping. A hard cut on a resonant sample
    /// clicks audibly; a short ramp does not.
    var fadeOutDuration: Double = 0.12

    private static let masterVolumeKey = "SoundDeckMasterVolume"
    private static let outputDeviceKey = "SoundDeckOutputDeviceUID"

    private let engine = AVAudioEngine()
    private var voices: [UUID: Voice] = [:]
    private var progressTimer: Timer?
    private var waveformToken = UUID()

    init() {
        if let stored = UserDefaults.standard.object(forKey: Self.masterVolumeKey) as? Float {
            masterVolume = stored
        }
        engine.mainMixerNode.outputVolume = masterVolume
        refreshDevices()
        if let savedUID = UserDefaults.standard.string(forKey: Self.outputDeviceKey) {
            selectOutputDevice(uid: savedUID)
        }
    }

    // MARK: - Playback

    func play(_ sound: SoundItem, in library: SoundLibrary) throws {
        guard let resolution = library.resolve(sound) else {
            throw PlaybackError.unresolved(name: sound.name)
        }
        let url = resolution.url
        let didAccess = resolution.needsSecurityScope && url.startAccessingSecurityScopedResource()

        guard FileManager.default.isReadableFile(atPath: url.path) else {
            if didAccess { url.stopAccessingSecurityScopedResource() }
            throw PlaybackError.unreadable(path: url.path)
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            if didAccess { url.stopAccessingSecurityScopedResource() }
            throw PlaybackError.decodeFailed(underlying: error)
        }

        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        mixer.outputVolume = sound.volume
        engine.attach(player)
        engine.attach(mixer)
        engine.connect(player, to: mixer, format: file.processingFormat)
        engine.connect(mixer, to: engine.mainMixerNode, format: file.processingFormat)

        do {
            try startEngineIfNeeded()
        } catch {
            engine.detach(player)
            engine.detach(mixer)
            if didAccess { url.stopAccessingSecurityScopedResource() }
            throw PlaybackError.engineFailed(underlying: error)
        }

        // Trim window, clamped to the file so bad metadata cannot schedule past the end.
        let sampleRate = file.processingFormat.sampleRate
        let totalFrames = file.length
        let totalDuration = Double(totalFrames) / sampleRate
        let start = max(0, min(sound.trimStart, totalDuration))
        let end = min(sound.trimEnd ?? totalDuration, totalDuration)
        let startFrame = AVAudioFramePosition(start * sampleRate)
        let frameCount = AVAudioFrameCount(max(0, (end - start) * sampleRate))

        guard frameCount > 0 else {
            engine.detach(player)
            engine.detach(mixer)
            if didAccess { url.stopAccessingSecurityScopedResource() }
            return
        }

        let voice = Voice(
            soundID: sound.id,
            player: player,
            mixer: mixer,
            scopedURL: didAccess ? url : nil,
            duration: end - start,
            startOffset: start
        )

        schedule(file: file, on: voice, startFrame: startFrame, frameCount: frameCount, loops: sound.loops)

        player.play()
        voices[voice.id] = voice
        playingIDs.insert(sound.id)
        lastPlayedID = sound.id
        focusedSoundID = sound.id
        startProgressTimer()
        loadWaveform(for: url)
    }

    /// Re-schedules on completion when looping, so a loop survives arbitrary lengths
    /// without pre-buffering the whole file repeatedly.
    private func schedule(file: AVAudioFile, on voice: Voice,
                          startFrame: AVAudioFramePosition, frameCount: AVAudioFrameCount,
                          loops: Bool) {
        voice.player.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil
        ) { [weak self] in
            // Completion arrives on an audio thread.
            Task { @MainActor in
                guard let self, let live = self.voices[voice.id] else { return }
                if loops {
                    live.startedAt = CACurrentMediaTime()
                    self.schedule(file: file, on: live, startFrame: startFrame, frameCount: frameCount, loops: true)
                } else {
                    self.retire(live)
                }
            }
        }
    }

    /// Stops one sound's voices, or everything when `sound` is nil.
    func stop(_ sound: SoundItem? = nil, fade: Bool = true) {
        let targets = voices.values.filter { sound == nil || $0.soundID == sound!.id }
        guard !targets.isEmpty else { return }
        for voice in targets {
            if fade && fadeOutDuration > 0 {
                fadeOut(voice)
            } else {
                retire(voice)
            }
        }
    }

    func stopAll() { stop(nil, fade: true) }

    func replayLast(in library: SoundLibrary) throws {
        guard let lastPlayedID,
              let sound = library.sounds.first(where: { $0.id == lastPlayedID }) else { return }
        try play(sound, in: library)
    }

    func isPlaying(_ sound: SoundItem) -> Bool { playingIDs.contains(sound.id) }

    /// Live gain change while a sound is playing.
    func setVolume(_ volume: Float, for soundID: UUID) {
        for voice in voices.values where voice.soundID == soundID {
            voice.mixer.outputVolume = volume
        }
    }

    // MARK: - Voice lifecycle

    private func fadeOut(_ voice: Voice) {
        voice.fadeTimer?.invalidate()
        let steps = 12
        let interval = fadeOutDuration / Double(steps)
        let startVolume = voice.mixer.outputVolume
        var step = 0
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            step += 1
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                guard self.voices[voice.id] != nil else { timer.invalidate(); return }
                if step >= steps {
                    timer.invalidate()
                    self.retire(voice)
                } else {
                    voice.mixer.outputVolume = startVolume * Float(1 - Double(step) / Double(steps))
                }
            }
        }
        voice.fadeTimer = timer
    }

    private func retire(_ voice: Voice) {
        voice.fadeTimer?.invalidate()
        voice.player.stop()
        engine.detach(voice.player)
        engine.detach(voice.mixer)
        voice.scopedURL?.stopAccessingSecurityScopedResource()
        voices.removeValue(forKey: voice.id)

        // Only clear the badge once this sound's last voice is gone.
        if !voices.values.contains(where: { $0.soundID == voice.soundID }) {
            playingIDs.remove(voice.soundID)
        }
        if voices.isEmpty {
            stopProgressTimer()
            progress = 0
            waveform = nil
            focusedSoundID = nil
            // Idling the engine releases the output device so other apps can change it.
            engine.pause()
        }
    }

    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    // MARK: - Progress

    private func startProgressTimer() {
        guard progressTimer == nil else { return }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func tick() {
        guard let focusedSoundID,
              let voice = voices.values.filter({ $0.soundID == focusedSoundID })
                  .max(by: { $0.startedAt < $1.startedAt }),
              voice.duration > 0 else {
            progress = 0
            return
        }
        let elapsed = CACurrentMediaTime() - voice.startedAt
        progress = min(1, max(0, elapsed / voice.duration))
    }

    // MARK: - Waveform

    private func loadWaveform(for url: URL) {
        let token = UUID()
        waveformToken = token
        AVAsset(url: url).waveformSamples(sampleCount: 500) { [weak self] samples in
            Task { @MainActor in
                guard let self, self.waveformToken == token else { return }
                self.waveform = samples
            }
        }
    }

    // MARK: - Output routing

    func refreshDevices() {
        outputDevices = AudioDeviceList.outputDevices()
    }

    /// Passing nil returns the deck to the system default output.
    func selectOutputDevice(uid: String?) {
        selectedDeviceUID = uid
        UserDefaults.standard.set(uid, forKey: Self.outputDeviceKey)

        let deviceID: AudioDeviceID?
        if let uid {
            deviceID = outputDevices.first(where: { $0.uid == uid })?.id
        } else {
            deviceID = AudioDeviceList.defaultOutputDevice()
        }
        guard var target = deviceID else { return }

        // The device property can only be set while the engine is stopped.
        let wasRunning = engine.isRunning
        engine.stop()
        guard let audioUnit = engine.outputNode.audioUnit else { return }
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &target,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            print("[DEBUG] Could not set output device (OSStatus \(status))")
        }
        if wasRunning { try? startEngineIfNeeded() }
    }

    var selectedDeviceName: String {
        guard let selectedDeviceUID,
              let device = outputDevices.first(where: { $0.uid == selectedDeviceUID }) else {
            return "System Default"
        }
        return device.name
    }
}
