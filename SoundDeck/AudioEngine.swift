import AVFoundation
import AppKit
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
///     AVAudioPlayerNode ──▶ AVAudioMixerNode ──▶ mainMixerNode ──▶ limiter ──▶ outputNode
///                            (per-voice gain,      (master gain)     (peak)      (routable)
///                             loudness, fade)
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
        /// The time-pitch node, when the pad changes its pitch or speed.
        let timePitch: AVAudioUnitTimePitch?
        /// The gain that moves the pad to the target loudness. The user volume multiplies it.
        let loudnessGain: Float
        var volume: Float
        let ducksOthers: Bool
        let chokeGroup: Int?
        let fadeOut: Double
        var envelope: VoiceEnvelope
        var startedAt: TimeInterval

        init(sound: SoundItem, player: AVAudioPlayerNode, mixer: AVAudioMixerNode, timePitch: AVAudioUnitTimePitch?,
             scopedURL: URL?, duration: Double, startOffset: Double) {
            self.soundID = sound.id
            self.player = player
            self.mixer = mixer
            self.timePitch = timePitch
            self.scopedURL = scopedURL
            self.duration = duration
            self.startOffset = startOffset
            self.loudnessGain = sound.loudnessGain
            self.volume = sound.volume
            self.ducksOthers = sound.ducksOthers
            self.chokeGroup = sound.chokeGroup
            self.fadeOut = sound.fadeOut
            self.envelope = VoiceEnvelope(fadeIn: sound.fadeIn)
            self.startedAt = CACurrentMediaTime()
        }

        /// A mixer volume above 1 boosts the signal. The limiter catches the peaks of several voices.
        func applyGain() {
            mixer.outputVolume = volume * loudnessGain * envelope.gain
        }
    }

    enum PlaybackError: LocalizedError {
        case unresolved(name: String)
        case unreadable(path: String)
        case decodeFailed(underlying: Error)
        case engineFailed(underlying: Error)
        case emptyTrim(name: String)

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
            case .emptyTrim(let name):
                return "The trim of “\(name)” has no length. Open Edit and reset the trim."
            }
        }
    }

    // MARK: Published state

    /// Sounds with at least one voice currently sounding.
    @Published private(set) var playingIDs: Set<UUID> = []
    @Published private(set) var lastPlayedID: UUID?
    /// The playhead updates 30 times each second. It is in a separate object, so that
    /// only the monitor waveform draws again, not every view that observes the engine.
    let playhead = Playhead()
    /// The last error from `triggerReportingErrors`. A successful play clears it.
    @Published private(set) var lastError: String?
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

    /// The level of the other pads while a pad with `ducksOthers` plays. 0.25 is -12 dB.
    static let duckLevel: Float = 0.25

    private static let masterVolumeKey = "SoundDeckMasterVolume"
    private static let outputDeviceKey = "SoundDeckOutputDeviceUID"

    private let engine = AVAudioEngine()
    /// Apple's peak limiter. Several loud voices together do not clip.
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    ))
    private var voices: [UUID: Voice] = [:]
    private var progressTimer: Timer?
    /// Runs while a fade or a duck change runs.
    private var envelopeTimer: Timer?
    private var lastEnvelopeStep: CFTimeInterval = 0
    private var waveformToken = UUID()
    /// The envelope of each sound that played. Thus a trigger does not decode the file again.
    private var waveformCache: [UUID: [Float]] = [:]

    init() {
        if let stored = UserDefaults.standard.object(forKey: Self.masterVolumeKey) as? Float {
            masterVolume = stored
        }
        engine.mainMixerNode.outputVolume = masterVolume
        engine.attach(limiter)
        connectOutputChain()
        selectedDeviceUID = UserDefaults.standard.string(forKey: Self.outputDeviceKey)
        refreshDevices()
        applyOutputDevice()

        // The engine stops when the output device changes or the Mac sleeps.
        // For example, this occurs when AirPods connect. Clear the voices and route again.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
        // A device was added or removed, or the system default changed.
        AudioDeviceList.observeChanges { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshDevices()
                self?.applyOutputDevice()
            }
        }
    }

    private func handleConfigurationChange() {
        print("[DEBUG] Audio configuration changed")
        // The engine stopped, so its voices cannot continue.
        for voice in Array(voices.values) { retire(voice) }
        refreshDevices()
        applyOutputDevice()
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
        engine.attach(player)
        engine.attach(mixer)
        // Only a pad that changes its pitch or speed gets the time-pitch node.
        var timePitch: AVAudioUnitTimePitch?
        if sound.pitch != 0 || sound.speed != 1 {
            let unit = AVAudioUnitTimePitch()
            unit.pitch = Float(sound.pitch * 100)
            unit.rate = Float(sound.speed)
            engine.attach(unit)
            engine.connect(player, to: unit, format: file.processingFormat)
            engine.connect(unit, to: mixer, format: file.processingFormat)
            timePitch = unit
        } else {
            engine.connect(player, to: mixer, format: file.processingFormat)
        }
        engine.connect(mixer, to: engine.mainMixerNode, format: file.processingFormat)
        let detachNodes = { [engine] in
            engine.detach(player)
            engine.detach(mixer)
            if let timePitch { engine.detach(timePitch) }
        }

        do {
            try startEngineIfNeeded()
        } catch {
            detachNodes()
            if didAccess { url.stopAccessingSecurityScopedResource() }
            throw PlaybackError.engineFailed(underlying: error)
        }

        let window = Self.trimWindow(
            trimStart: sound.trimStart,
            trimEnd: sound.trimEnd,
            totalFrames: file.length,
            sampleRate: file.processingFormat.sampleRate
        )
        let (start, end, startFrame, frameCount) = (window.start, window.end, window.startFrame, window.frameCount)

        guard frameCount > 0 else {
            detachNodes()
            if didAccess { url.stopAccessingSecurityScopedResource() }
            throw PlaybackError.emptyTrim(name: sound.name)
        }

        // A pad stops the other pads in its choke group.
        if let group = sound.chokeGroup {
            for other in Array(voices.values) where other.chokeGroup == group && other.soundID != sound.id {
                beginFadeOut(other)
            }
        }

        let voice = Voice(
            sound: sound,
            player: player,
            mixer: mixer,
            timePitch: timePitch,
            scopedURL: didAccess ? url : nil,
            // A faster pad ends sooner. The playhead uses this duration.
            duration: (end - start) / max(0.01, sound.speed),
            startOffset: start
        )
        voice.applyGain()

        schedule(file: file, on: voice, startFrame: startFrame, frameCount: frameCount, loops: sound.loops)

        player.play()
        voices[voice.id] = voice
        updateDucking()
        if voice.envelope.isMoving { startEnvelopeTimer() }
        playingIDs.insert(sound.id)
        lastPlayedID = sound.id
        focusedSoundID = sound.id
        lastError = nil
        startProgressTimer()
        loadWaveform(for: url, soundID: sound.id)
    }

    /// Plays a pad as its play mode says. Every trigger of a pad uses this function.
    /// The inspector preview uses `play`, so it always plays.
    func trigger(_ sound: SoundItem, in library: SoundLibrary) throws {
        switch sound.playMode {
        case .layer, .hold:
            try play(sound, in: library)
        case .restart:
            stop(sound)
            try play(sound, in: library)
        case .toggle:
            if voices.values.contains(where: { $0.soundID == sound.id && !$0.envelope.isStopping }) {
                stop(sound)
            } else {
                try play(sound, in: library)
            }
        }
    }

    /// The key or the mouse button came up. A Hold pad stops.
    func release(_ sound: SoundItem) {
        if sound.playMode == .hold { stop(sound) }
    }

    /// Triggers a pad and keeps an error in `lastError`. Use it where no alert can show,
    /// for example the menu bar deck and the global hotkeys.
    func triggerReportingErrors(_ sound: SoundItem, in library: SoundLibrary) {
        do {
            try trigger(sound, in: library)
        } catch {
            print("[DEBUG] Could not play \(sound.name): \(error)")
            lastError = error.localizedDescription
        }
    }

    struct TrimWindow: Equatable {
        /// Seconds from the start of the file.
        let start: Double
        let end: Double
        let startFrame: AVAudioFramePosition
        let frameCount: AVAudioFrameCount
    }

    /// The part of the file to play, clamped to the file so bad metadata cannot schedule past the end.
    nonisolated static func trimWindow(trimStart: Double, trimEnd: Double?,
                                       totalFrames: AVAudioFramePosition, sampleRate: Double) -> TrimWindow {
        let totalDuration = Double(totalFrames) / sampleRate
        let start = max(0, min(trimStart, totalDuration))
        let end = min(trimEnd ?? totalDuration, totalDuration)
        return TrimWindow(
            start: start,
            end: end,
            startFrame: AVAudioFramePosition(start * sampleRate),
            frameCount: AVAudioFrameCount(max(0, (end - start) * sampleRate))
        )
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
            at: nil,
            // `.dataConsumed` fires when the engine reads the data, about 0.9 s before playback.
            // A loop needs that early call for a gapless restart. A single play must wait for
            // playback. If not, `retire()` cuts the tail, and a short clip gives no sound.
            completionCallbackType: loops ? .dataConsumed : .dataPlayedBack
        ) { [weak self] _ in
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
            if fade {
                beginFadeOut(voice)
            } else {
                retire(voice)
            }
        }
    }

    func stopAll() { stop(nil, fade: true) }

    func replayLast(in library: SoundLibrary) throws {
        guard let lastPlayedID,
              let sound = library.sound(withID: lastPlayedID) else { return }
        try play(sound, in: library)
    }

    func isPlaying(_ sound: SoundItem) -> Bool { playingIDs.contains(sound.id) }

    /// Live gain change while a sound is playing.
    func setVolume(_ volume: Float, for soundID: UUID) {
        for voice in voices.values where voice.soundID == soundID {
            voice.volume = volume
            voice.applyGain()
        }
    }

    // MARK: - Voice lifecycle

    /// Starts the fade-out of a voice. The envelope timer retires it at the end.
    private func beginFadeOut(_ voice: Voice) {
        voice.envelope.stop(fadeOut: voice.fadeOut)
        if voice.envelope.isSilent {
            retire(voice)
            return
        }
        updateDucking()
        startEnvelopeTimer()
    }

    /// While a pad with `ducksOthers` plays, the other pads go down to `duckLevel`.
    private func updateDucking() {
        let isDucking = voices.values.contains { $0.ducksOthers && !$0.envelope.isStopping }
        for voice in voices.values where !voice.ducksOthers {
            voice.envelope.duckTarget = isDucking ? Self.duckLevel : 1
        }
        if voices.values.contains(where: { $0.envelope.isMoving }) { startEnvelopeTimer() }
    }

    private func startEnvelopeTimer() {
        guard envelopeTimer == nil else { return }
        lastEnvelopeStep = CACurrentMediaTime()
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.stepEnvelopes() }
        }
        // The common modes keep the timer running while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        envelopeTimer = timer
    }

    private func stopEnvelopeTimer() {
        envelopeTimer?.invalidate()
        envelopeTimer = nil
    }

    private func stepEnvelopes() {
        let now = CACurrentMediaTime()
        let elapsed = now - lastEnvelopeStep
        lastEnvelopeStep = now
        for voice in Array(voices.values) {
            voice.envelope.advance(by: elapsed)
            voice.applyGain()
            if voice.envelope.isSilent { retire(voice) }
        }
        if !voices.values.contains(where: { $0.envelope.isMoving }) { stopEnvelopeTimer() }
    }

    private func retire(_ voice: Voice) {
        voice.player.stop()
        engine.detach(voice.player)
        engine.detach(voice.mixer)
        if let timePitch = voice.timePitch { engine.detach(timePitch) }
        voice.scopedURL?.stopAccessingSecurityScopedResource()
        voices.removeValue(forKey: voice.id)

        // Only clear the badge once this sound's last voice is gone.
        if !voices.values.contains(where: { $0.soundID == voice.soundID }) {
            playingIDs.remove(voice.soundID)
        }
        updateDucking()
        if voices.isEmpty {
            stopEnvelopeTimer()
            stopProgressTimer()
            playhead.progress = 0
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
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
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
            playhead.progress = 0
            return
        }
        let elapsed = CACurrentMediaTime() - voice.startedAt
        playhead.progress = min(1, max(0, elapsed / voice.duration))
    }

    // MARK: - Waveform

    private func loadWaveform(for url: URL, soundID: UUID) {
        let token = UUID()
        waveformToken = token
        if let cached = waveformCache[soundID] {
            waveform = cached
            return
        }
        AVAsset(url: url).waveformSamples(sampleCount: 500) { [weak self] samples in
            Task { @MainActor in
                guard let self else { return }
                if let samples { self.waveformCache[soundID] = samples }
                guard self.waveformToken == token else { return }
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
        applyOutputDevice()
    }

    /// Routes the engine to the selected device. If that device is missing, it uses the
    /// system default and keeps the selection, so the deck goes back when the device returns.
    private func applyOutputDevice() {
        let preferred = selectedDeviceUID.flatMap { uid in outputDevices.first { $0.uid == uid }?.id }
        if selectedDeviceUID != nil, preferred == nil {
            print("[DEBUG] The selected output device is missing; using the system default")
        }
        guard var target = preferred ?? AudioDeviceList.defaultOutputDevice(),
              let audioUnit = engine.outputNode.audioUnit else { return }
        // Setting the device can post a configuration change. This check stops a loop.
        guard target != Self.currentDevice(of: audioUnit) else { return }

        // The device property can only be set while the engine is stopped.
        // A stopped engine cannot continue its voices, so retire them.
        for voice in Array(voices.values) { retire(voice) }
        engine.stop()
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
            return
        }
        connectOutputChain()
        print("[DEBUG] Output device is \(target)")
    }

    /// Connects the main mixer to the limiter, and the limiter to the output, at the rate of
    /// the device. A new device can have another sample rate or channel count. The output
    /// unit maps stereo to the first two channels of the device.
    private func connectOutputChain() {
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate,
                                         channels: min(2, max(1, hardware.channelCount))) else { return }
        engine.connect(engine.mainMixerNode, to: limiter, format: format)
        engine.connect(limiter, to: engine.outputNode, format: format)
    }

    private static func currentDevice(of audioUnit: AudioUnit) -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size)
        return status == noErr ? device : nil
    }

    var selectedDeviceName: String {
        guard let selectedDeviceUID,
              let device = outputDevices.first(where: { $0.uid == selectedDeviceUID }) else {
            return "System Default"
        }
        return device.name
    }
}

/// The position of the playhead, from 0 to 1, for the most recently started voice.
@MainActor
final class Playhead: ObservableObject {
    @Published var progress: Double = 0
}
