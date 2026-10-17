import AVFoundation
import CoreAudio
import Foundation
import os

/// A mono sample queue between two audio threads: the microphone writes, the deck reads.
///
/// The two devices have different clocks. Thus the queue keeps a small cushion. After an
/// underrun, the reader gives silence until the cushion is full again. When the queue
/// holds too much, the writer drops the oldest samples. Thus the delay stays short.
final class MicRingBuffer: @unchecked Sendable {
    let capacity: Int
    /// The reader waits for this number of samples after a start or an underrun.
    let cushion: Int
    /// More than this number of samples drops the oldest samples down to `cushion`.
    let maximumFill: Int

    private let storage: UnsafeMutablePointer<Float>
    private let lock: os_unfair_lock_t
    // Totals since the start. The difference is the fill.
    private var written = 0
    private var read = 0
    private var isPriming = true

    init(capacity: Int, cushion: Int, maximumFill: Int) {
        self.capacity = max(1, capacity)
        self.maximumFill = min(self.capacity, max(1, maximumFill))
        self.cushion = min(self.maximumFill, max(0, cushion))
        storage = .allocate(capacity: self.capacity)
        storage.initialize(repeating: 0, count: self.capacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    /// A cushion of 20 ms and a limit of 80 ms at `sampleRate`.
    convenience init(sampleRate: Double) {
        let rate = max(1, Int(sampleRate))
        self.init(capacity: rate, cushion: rate / 50, maximumFill: rate * 2 / 25)
    }

    deinit {
        storage.deallocate()
        lock.deallocate()
    }

    var fill: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return written - read
    }

    /// Writes `count` samples. `stride` skips the other channels of interleaved audio.
    func write(_ samples: UnsafePointer<Float>, count: Int, stride: Int = 1) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        for index in 0..<max(0, count) {
            storage[(written + index) % capacity] = samples[index * stride]
        }
        written += max(0, count)
        if written - read > maximumFill {
            read = written - cushion
        }
    }

    /// Fills `count` samples. Gives the number of real samples. The rest is silence.
    @discardableResult
    func read(into output: UnsafeMutablePointer<Float>, count: Int) -> Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let available = written - read
        if isPriming && available < cushion {
            output.update(repeating: 0, count: count)
            return 0
        }
        isPriming = false
        let taken = min(count, available)
        for index in 0..<taken {
            output[index] = storage[(read + index) % capacity]
        }
        read += taken
        if taken < count {
            (output + taken).update(repeating: 0, count: count - taken)
            isPriming = true
        }
        return taken
    }
}

/// Captures the microphone in its own `AVAudioEngine` and writes it to a `MicRingBuffer`.
///
/// The deck engine reads the queue with an `AVAudioSourceNode`. A separate engine lets
/// the input device be different from the output device, without an aggregate device.
/// The graph is:
///
///     inputNode ──▶ AVAudioSinkNode (channel 1 to the queue)
@MainActor
final class MicInput {
    private(set) var buffer: MicRingBuffer?
    private(set) var sampleRate: Double = 0
    /// The device that the engine uses. Nil when the input is stopped.
    private(set) var deviceID: AudioDeviceID?
    /// Called when the input engine stops because of a device change.
    var onConfigurationChange: (() -> Void)?

    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?

    var isRunning: Bool { engine?.isRunning ?? false }

    enum MicError: LocalizedError {
        case noInput
        case deviceFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noInput:
                return "There is no input device. Connect a microphone and try again."
            case .deviceFailed(let status):
                return "Could not use that input device (error \(status))."
            }
        }
    }

    /// Starts the input on `device`. It stops an input that runs.
    func start(device: AudioDeviceID) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let unit = input.audioUnit {
            var target = device
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                              0, &target, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw MicError.deviceFailed(status) }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0, format.commonFormat == .pcmFormatFloat32 else {
            throw MicError.noInput
        }

        let buffer = MicRingBuffer(sampleRate: format.sampleRate)
        let sink = Self.makeSink(writing: buffer, stride: format.isInterleaved ? Int(format.channelCount) : 1)
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        engine.prepare()
        try engine.start()

        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onConfigurationChange?() }
        }
        self.engine = engine
        self.buffer = buffer
        self.sampleRate = format.sampleRate
        self.deviceID = device
        print("[DEBUG] Microphone input \(device) at \(format.sampleRate) Hz")
    }

    /// The block runs on the audio thread. It uses only the queue. It keeps the first channel.
    nonisolated private static func makeSink(writing buffer: MicRingBuffer, stride: Int) -> AVAudioSinkNode {
        AVAudioSinkNode { _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
            guard let first = buffers.first, let data = first.mData else { return noErr }
            buffer.write(data.assumingMemoryBound(to: Float.self), count: Int(frameCount), stride: stride)
            return noErr
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.stop()
        engine = nil
        buffer = nil
        deviceID = nil
    }
}
