import AVFoundation
import CoreAudio
import Foundation

/// The second output of the deck, for example headphones.
///
/// It has its own `AVAudioEngine`, because one engine plays on one device. A voice that
/// plays on the monitor gets a second player in this engine. A voice that plays only on
/// Live gets no node here, so a silent path costs no CPU. The graph is:
///
///     AVAudioPlayerNode ──▶ AVAudioMixerNode ──▶ mainMixerNode ──▶ limiter ──▶ outputNode
///                            (voice gain)          (monitor volume)  (peak)      (monitor device)
///
/// The microphone does not go to the monitor. Thus the user does not hear a late copy of their voice.
@MainActor
final class MonitorOutput {
    /// Created when the user first selects a monitor device. Before that, no engine holds a device.
    private(set) var engine: AVAudioEngine?
    private let limiter = AudioEngine.makeLimiter()
    /// The device that the engine uses. Nil means no monitor.
    private(set) var deviceID: AudioDeviceID?
    /// Called when the monitor engine stops because of a device change.
    var onConfigurationChange: (() -> Void)?

    var volume: Float = 0.8 {
        didSet { engine?.mainMixerNode.outputVolume = volume }
    }

    var isActive: Bool { deviceID != nil && engine != nil }

    /// The time from the render to the speaker, in seconds.
    var latency: Double { engine?.outputNode.presentationLatency ?? 0 }

    /// Routes the monitor to `device`. Nil turns the monitor off. If the route changes,
    /// the function first calls `beforeChange`, so that the caller can retire the monitor voices.
    func route(to device: AudioDeviceID?, beforeChange: () -> Void) {
        guard let device else {
            guard deviceID != nil else { return }
            beforeChange()
            engine?.stop()
            deviceID = nil
            print("[DEBUG] Monitor is off")
            return
        }
        let engine = engine ?? makeEngine()
        guard let unit = engine.outputNode.audioUnit else { return }
        // Setting the device can post a configuration change. This check stops a loop.
        guard device != deviceID || device != AudioEngine.currentDevice(of: unit) else { return }
        beforeChange()
        engine.stop()
        var target = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                          0, &target, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            print("[DEBUG] Could not set monitor device (OSStatus \(status))")
            deviceID = nil
            return
        }
        deviceID = device
        connectOutputChain()
        print("[DEBUG] Monitor device is \(device)")
    }

    /// Stops the engine and connects it again at the rate of the device.
    func reset() {
        guard let engine else { return }
        engine.stop()
        connectOutputChain()
    }

    func startIfNeeded() throws {
        guard let engine, !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    /// Releases the device while no voice plays.
    func pause() {
        engine?.pause()
    }

    private func makeEngine() -> AVAudioEngine {
        let engine = AVAudioEngine()
        engine.attach(limiter)
        engine.mainMixerNode.outputVolume = volume
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onConfigurationChange?() }
        }
        self.engine = engine
        return engine
    }

    private func connectOutputChain() {
        guard let engine else { return }
        AudioEngine.connectChain(of: engine, from: engine.mainMixerNode, through: limiter)
    }
}
