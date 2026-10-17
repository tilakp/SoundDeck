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
///     AVAudioPlayerNode ──▶ AVAudioMixerNode ──▶ mainMixerNode ──▶ liveBus ──▶ limiter ──▶ outputNode
///                            (per-voice gain,      (master gain)        ▲          (peak)      (routable)
///                             loudness, fade)                           │
///     AVAudioSourceNode (microphone) ──▶ AVAudioMixerNode (mic gain) ───┘
///
/// A voice that also plays on the Monitor device gets a second branch in `MonitorOutput`.
/// The microphone goes only to Live.
@MainActor
final class AudioEngine: ObservableObject {

    /// The nodes of one voice in one engine: Live or Monitor.
    private struct Branch {
        let engine: AVAudioEngine
        let player: AVAudioPlayerNode
        let mixer: AVAudioMixerNode
        /// The time-pitch node, when the pad changes its pitch or speed.
        let timePitch: AVAudioUnitTimePitch?
        /// The EQ node, when the pad has an EQ that is not flat.
        let eq: AVAudioUnitEQ?
        /// Each branch reads its own file object. Two engines read on two audio threads.
        let file: AVAudioFile

        func detach() {
            engine.detach(player)
            engine.detach(mixer)
            if let timePitch { engine.detach(timePitch) }
            if let eq { engine.detach(eq) }
        }
    }

    /// One sounding instance. A single `SoundItem` can have several at once.
    private final class Voice {
        let id = UUID()
        let soundID: UUID
        /// One branch for each output. The first branch sets the playhead.
        let branches: [Branch]
        /// The branches that did not play to the end. The voice retires at 0.
        var pendingBranches: Int
        let scopedURL: URL?
        let duration: Double
        let startOffset: Double
        /// The gain that moves the pad to the target loudness. The user volume multiplies it.
        let loudnessGain: Float
        var volume: Float
        let ducksOthers: Bool
        let chokeGroup: Int?
        let fadeOut: Double
        var envelope: VoiceEnvelope
        var startedAt: TimeInterval

        init(sound: SoundItem, branches: [Branch], scopedURL: URL?, duration: Double, startOffset: Double) {
            self.soundID = sound.id
            self.branches = branches
            self.pendingBranches = branches.count
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
            let gain = volume * loudnessGain * envelope.gain
            for branch in branches { branch.mixer.outputVolume = gain }
        }
    }

    enum PlaybackError: LocalizedError {
        case unresolved(name: String)
        case unreadable(path: String)
        case decodeFailed(underlying: Error)
        case engineFailed(underlying: Error)
        case emptyTrim(name: String)
        case noMonitor(name: String)

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
            case .noMonitor(let name):
                return "“\(name)” plays on Me only, but no Monitor device is available. Set one in Settings, Audio."
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
    /// The last error of each pad that failed. A successful play of that pad clears it.
    /// The views mark a failed pad in place, so a live show gets no modal alert.
    @Published private(set) var padErrors: [UUID: String] = [:]
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

    /// The Monitor device and the microphone pass-through. Settings, Audio changes them.
    @Published private(set) var routing = AudioRoutingSettings()
    @Published private(set) var inputDevices: [AudioDevice] = []
    /// True while the microphone goes into the Live output.
    @Published private(set) var isMicLive = false
    /// The last error of the microphone pass-through.
    @Published private(set) var micError: String?

    /// The level of the other pads while a pad with `ducksOthers` plays. 0.25 is -12 dB.
    static let duckLevel: Float = 0.25

    private static let masterVolumeKey = "SoundDeckMasterVolume"
    private static let outputDeviceKey = "SoundDeckOutputDeviceUID"

    private let engine = AVAudioEngine()
    /// Apple's peak limiter. Several loud voices together do not clip.
    private let limiter = AudioEngine.makeLimiter()
    /// Mixes the deck and the microphone before the limiter.
    private let liveBus = AVAudioMixerNode()
    private let monitor = MonitorOutput()
    private let micInput = MicInput()
    /// The microphone nodes in the deck engine, while the pass-through runs.
    private var micSource: AVAudioSourceNode?
    private var micMixer: AVAudioMixerNode?
    /// The test host keeps the settings of the user and does not open devices.
    private let usesStoredRouting = !SoundDeckApp.isRunningTests
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
        engine.attach(liveBus)
        engine.attach(limiter)
        connectOutputChain()
        selectedDeviceUID = UserDefaults.standard.string(forKey: Self.outputDeviceKey)
        if usesStoredRouting { routing = AudioRoutingSettings.load(from: .standard) }
        monitor.volume = routing.monitorVolume
        refreshDevices()
        applyOutputDevice()
        applyMonitorDevice()
        if routing.micEnabled { enableMicAfterPermission() }

        monitor.onConfigurationChange = { [weak self] in self?.handleMonitorConfigurationChange() }
        micInput.onConfigurationChange = { [weak self] in
            guard let self else { return }
            print("[DEBUG] Microphone configuration changed")
            // A change of format stops the input engine. A notice without a stop needs no restart.
            // Thus a notice that the restart itself causes does not start a loop.
            self.applyMic(restart: !self.micInput.isRunning)
        }

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
                guard let self else { return }
                self.refreshDevices()
                self.applyOutputDevice()
                self.applyMonitorDevice()
                self.applyMic()
            }
        }
    }

    private func handleConfigurationChange() {
        print("[DEBUG] Audio configuration changed")
        // The engine stopped, so its voices cannot continue.
        for voice in Array(voices.values) { retire(voice) }
        refreshDevices()
        // A new rate on the same device also needs a new connection.
        engine.stop()
        applyOutputDevice()
        connectOutputChain()
        monitor.reset()
        applyMonitorDevice()
        applyMic(restart: true)
    }

    /// The monitor engine stopped. Its voices cannot continue.
    private func handleMonitorConfigurationChange() {
        print("[DEBUG] Monitor configuration changed")
        for voice in Array(voices.values) where voice.branches.contains(where: { $0.engine !== engine }) {
            retire(voice)
        }
        refreshDevices()
        monitor.reset()
        applyMonitorDevice()
    }

    // MARK: - Playback

    func play(_ sound: SoundItem, in library: SoundLibrary) throws {
        guard let resolution = library.resolve(sound) else {
            throw PlaybackError.unresolved(name: sound.name)
        }
        let route = OutputRoute.route(for: sound.output, monitorIsActive: monitor.isActive)
        guard !route.isEmpty else { throw PlaybackError.noMonitor(name: sound.name) }
        let url = resolution.url
        let didAccess = resolution.needsSecurityScope && url.startAccessingSecurityScopedResource()

        guard FileManager.default.isReadableFile(atPath: url.path) else {
            if didAccess { url.stopAccessingSecurityScopedResource() }
            throw PlaybackError.unreadable(path: url.path)
        }

        // Each output reads its own file object.
        var files: [AVAudioFile] = []
        do {
            for _ in 0..<((route.live ? 1 : 0) + (route.monitor ? 1 : 0)) {
                files.append(try AVAudioFile(forReading: url))
            }
        } catch {
            if didAccess { url.stopAccessingSecurityScopedResource() }
            throw PlaybackError.decodeFailed(underlying: error)
        }
        let file = files[0]

        var branches: [Branch] = []
        if route.live {
            branches.append(makeBranch(in: engine, file: files.removeFirst(), sound: sound))
        }
        if route.monitor, let monitorEngine = monitor.engine {
            branches.append(makeBranch(in: monitorEngine, file: files.removeFirst(), sound: sound))
        }
        let detachNodes = { for branch in branches { branch.detach() } }

        do {
            if route.live { try startEngineIfNeeded() }
            if route.monitor { try monitor.startIfNeeded() }
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
            branches: branches,
            scopedURL: didAccess ? url : nil,
            // A faster pad ends sooner. The playhead uses this duration.
            duration: (end - start) / max(0.01, sound.speed),
            startOffset: start
        )
        voice.applyGain()

        for index in branches.indices {
            schedule(branch: index, of: voice, startFrame: startFrame, frameCount: frameCount, loops: sound.loops)
        }
        startPlayers(of: voice)
        voices[voice.id] = voice
        updateDucking()
        if voice.envelope.isMoving { startEnvelopeTimer() }
        playingIDs.insert(sound.id)
        lastPlayedID = sound.id
        focusedSoundID = sound.id
        lastError = nil
        padErrors[sound.id] = nil
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
            recordFailure(error, for: sound)
        }
    }

    /// Keeps the error of a pad for the views. Every trigger path calls this on failure.
    func recordFailure(_ error: Error, for sound: SoundItem) {
        print("[DEBUG] Could not play \(sound.name): \(error)")
        lastError = error.localizedDescription
        padErrors[sound.id] = error.localizedDescription
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
    /// Each branch schedules its own loop, because two devices have two clocks.
    private func schedule(branch index: Int, of voice: Voice,
                          startFrame: AVAudioFramePosition, frameCount: AVAudioFrameCount,
                          loops: Bool) {
        let branch = voice.branches[index]
        branch.player.scheduleSegment(
            branch.file,
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
                    if index == 0 { live.startedAt = CACurrentMediaTime() }
                    self.schedule(branch: index, of: live, startFrame: startFrame, frameCount: frameCount, loops: true)
                } else {
                    // Wait for the last output, so that no output loses its tail.
                    live.pendingBranches -= 1
                    if live.pendingBranches <= 0 { self.retire(live) }
                }
            }
        }
    }

    /// Makes the nodes of one voice in `engine`. Only a pad that changes its pitch or speed
    /// gets the time-pitch node. Only a pad with an EQ that is not flat gets the EQ node.
    ///
    /// The chain is: player, time-pitch, EQ, voice mixer.
    private func makeBranch(in engine: AVAudioEngine, file: AVAudioFile, sound: SoundItem) -> Branch {
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        engine.attach(player)
        engine.attach(mixer)
        let format = file.processingFormat
        var chain: [AVAudioNode] = [player]
        var timePitch: AVAudioUnitTimePitch?
        if sound.pitch != 0 || sound.speed != 1 {
            let unit = AVAudioUnitTimePitch()
            unit.pitch = Float(sound.pitch * 100)
            unit.rate = Float(sound.speed)
            engine.attach(unit)
            chain.append(unit)
            timePitch = unit
        }
        var eqUnit: AVAudioUnitEQ?
        if let eq = PadEQ.effective(sound.eq) {
            let unit = eq.makeUnit()
            engine.attach(unit)
            chain.append(unit)
            eqUnit = unit
        }
        chain.append(mixer)
        for (source, destination) in zip(chain, chain.dropFirst()) {
            engine.connect(source, to: destination, format: format)
        }
        engine.connect(mixer, to: engine.mainMixerNode, format: format)
        return Branch(engine: engine, player: player, mixer: mixer, timePitch: timePitch, eq: eqUnit, file: file)
    }

    /// One branch starts at once. Two branches start at one host time. The output with
    /// less latency waits for the other, so both outputs sound at the same moment.
    private func startPlayers(of voice: Voice) {
        guard voice.branches.count > 1 else {
            voice.branches.first?.player.play()
            return
        }
        let latencies = voice.branches.map { $0.engine === engine ? engine.outputNode.presentationLatency : monitor.latency }
        let delays = RoutingMath.startDelays(latencies: latencies)
        // The lead gives both render threads time to see the start time.
        let base = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: Self.syncLead)
        for (branch, delay) in zip(voice.branches, delays) {
            branch.player.play(at: AVAudioTime(hostTime: base + AVAudioTime.hostTime(forSeconds: delay)))
        }
    }

    /// Seconds between the trigger and the start of a voice on two outputs.
    private static let syncLead = 0.015

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
        for branch in voice.branches {
            branch.player.stop()
            branch.detach()
        }
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
            playhead.padProgress = [:]
            waveform = nil
            focusedSoundID = nil
            pauseIfIdle()
        }
    }

    /// Idling the engines releases the output devices so other apps can change them.
    /// The microphone keeps the deck engine running.
    private func pauseIfIdle() {
        guard voices.isEmpty else { return }
        if micSource == nil { engine.pause() }
        monitor.pause()
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
        let progress = Self.padProgress(
            of: voices.values.map { (soundID: $0.soundID, startedAt: $0.startedAt, duration: $0.duration) },
            at: CACurrentMediaTime()
        )
        playhead.padProgress = progress
        playhead.progress = focusedSoundID.flatMap { progress[$0] } ?? 0
    }

    /// Gives the progress of each pad, from 0 to 1. The newest voice of a pad sets its value.
    /// A voice with no duration gives 0.
    nonisolated static func padProgress(
        of voices: [(soundID: UUID, startedAt: TimeInterval, duration: Double)],
        at now: TimeInterval
    ) -> [UUID: Double] {
        var newest: [UUID: (startedAt: TimeInterval, duration: Double)] = [:]
        for voice in voices where (newest[voice.soundID]?.startedAt ?? -.infinity) < voice.startedAt {
            newest[voice.soundID] = (voice.startedAt, voice.duration)
        }
        return newest.mapValues { voice in
            guard voice.duration > 0 else { return 0 }
            return min(1, max(0, (now - voice.startedAt) / voice.duration))
        }
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
        inputDevices = AudioDeviceList.inputDevices()
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
        // The microphone keeps the engine running.
        if micSource != nil { try? startEngineIfNeeded() }
    }

    /// Connects the main mixer and the microphone to the live bus, and the bus through the
    /// limiter to the output.
    private func connectOutputChain() {
        guard let format = Self.connectChain(of: engine, from: liveBus, through: limiter) else { return }
        engine.connect(engine.mainMixerNode, to: liveBus, fromBus: 0, toBus: 0, format: format)
        if let micMixer {
            engine.connect(micMixer, to: liveBus, fromBus: 0, toBus: 1, format: format)
        }
    }

    /// Connects `source` to `limiter`, and the limiter to the output, at the rate of the
    /// device. A new device can have another sample rate or channel count. The output unit
    /// maps stereo to the first two channels of the device. Gives the format.
    @discardableResult
    static func connectChain(of engine: AVAudioEngine, from source: AVAudioNode,
                             through limiter: AVAudioUnitEffect) -> AVAudioFormat? {
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate,
                                         channels: min(2, max(1, hardware.channelCount))) else { return nil }
        engine.connect(source, to: limiter, format: format)
        engine.connect(limiter, to: engine.outputNode, format: format)
        return format
    }

    static func makeLimiter() -> AVAudioUnitEffect {
        AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        ))
    }

    static func currentDevice(of audioUnit: AudioUnit) -> AudioDeviceID? {
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

    // MARK: - Monitor

    /// Nil turns the monitor off.
    func selectMonitorDevice(uid: String?) {
        routing.monitorDeviceUID = uid
        saveRouting()
        applyMonitorDevice()
    }

    func setMonitorVolume(_ volume: Float) {
        routing.monitorVolume = volume
        monitor.volume = volume
        saveRouting()
    }

    /// True when the monitor device is selected and present.
    var isMonitorActive: Bool { monitor.isActive }

    /// Routes the monitor to the selected device. A missing device turns the monitor off
    /// until the device returns. It does not use the system default, because that can be the call device.
    private func applyMonitorDevice() {
        let target = routing.monitorDeviceUID.flatMap { uid in outputDevices.first { $0.uid == uid }?.id }
        if routing.monitorDeviceUID != nil, target == nil {
            print("[DEBUG] The monitor device is missing; the monitor is off")
        }
        monitor.route(to: target) {
            // The device can only change while the monitor engine is stopped.
            for voice in Array(voices.values) where voice.branches.contains(where: { $0.engine !== engine }) {
                retire(voice)
            }
        }
        objectWillChange.send()
    }

    // MARK: - Microphone pass-through

    func setMicEnabled(_ enabled: Bool) {
        routing.micEnabled = enabled
        saveRouting()
        if enabled {
            enableMicAfterPermission()
        } else {
            applyMic()
        }
    }

    /// Nil uses the system default input.
    func selectMicDevice(uid: String?) {
        routing.micDeviceUID = uid
        saveRouting()
        applyMic()
    }

    func setMicGain(decibels: Double) {
        routing.micGainDecibels = decibels
        micMixer?.outputVolume = routing.micLinearGain
        saveRouting()
    }

    func setMicMuted(_ muted: Bool) {
        routing.micMuted = muted
        micMixer?.outputVolume = routing.micLinearGain
        saveRouting()
    }

    private func enableMicAfterPermission() {
        guard usesStoredRouting else { return }
        Task { @MainActor in
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                self.micError = Recorder.RecorderError.permissionDenied.localizedDescription
                self.routing.micEnabled = false
                self.saveRouting()
                return
            }
            self.applyMic()
        }
    }

    /// Starts, moves or stops the pass-through, as the settings say. `restart` starts it
    /// again on the same device, for example after a device change.
    private func applyMic(restart: Bool = false) {
        guard routing.micEnabled, usesStoredRouting,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            stopMic()
            return
        }
        let selected = routing.micDeviceUID.flatMap { uid in inputDevices.first { $0.uid == uid }?.id }
        guard let device = selected ?? AudioDeviceList.defaultInputDevice() else {
            stopMic()
            micError = MicInput.MicError.noInput.localizedDescription
            return
        }
        if !restart, micSource != nil, micInput.isRunning, micInput.deviceID == device { return }
        stopMic()
        do {
            try micInput.start(device: device)
            guard let buffer = micInput.buffer,
                  let format = AVAudioFormat(standardFormatWithSampleRate: micInput.sampleRate, channels: 1) else {
                throw MicInput.MicError.noInput
            }
            let source = Self.makeMicSource(reading: buffer, format: format)
            let mixer = AVAudioMixerNode()
            engine.attach(source)
            engine.attach(mixer)
            // The mixer converts the rate of the microphone to the rate of the output.
            engine.connect(source, to: mixer, format: format)
            mixer.outputVolume = routing.micLinearGain
            micSource = source
            micMixer = mixer
            connectOutputChain()
            try startEngineIfNeeded()
            isMicLive = true
            micError = nil
        } catch {
            print("[DEBUG] Microphone pass-through failed: \(error)")
            stopMic()
            micError = error.localizedDescription
        }
    }

    private func stopMic() {
        micInput.stop()
        if let micSource { engine.detach(micSource) }
        if let micMixer { engine.detach(micMixer) }
        micSource = nil
        micMixer = nil
        isMicLive = false
        pauseIfIdle()
    }

    /// The render block runs on the audio thread. It reads only the queue.
    nonisolated private static func makeMicSource(reading buffer: MicRingBuffer, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            for audio in buffers {
                guard let data = audio.mData else { continue }
                buffer.read(into: data.assumingMemoryBound(to: Float.self), count: Int(frameCount))
            }
            return noErr
        }
    }

    private func saveRouting() {
        guard usesStoredRouting else { return }
        routing.save(to: .standard)
    }

    var monitorDeviceName: String {
        guard let uid = routing.monitorDeviceUID else { return "None" }
        return outputDevices.first(where: { $0.uid == uid })?.name ?? "Missing device"
    }
}

/// The position of the playhead, from 0 to 1, for the most recently started voice.
@MainActor
final class Playhead: ObservableObject {
    @Published var progress: Double = 0
    /// The progress of each playing pad. The key is `SoundItem.id`.
    /// Only a small subview in each tile observes this value. Thus the grid does not draw again at each tick.
    @Published var padProgress: [UUID: Double] = [:]
}
