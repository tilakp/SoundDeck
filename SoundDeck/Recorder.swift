import AVFoundation
import Foundation

/// Records a new sound from the default input device to an AAC file.
///
/// The recorder has its own `AVAudioEngine`, so a recording does not change the
/// playback graph. The graph is:
///
///     inputNode ──▶ AVAudioMixerNode ──▶ mainMixerNode (muted) ──▶ outputNode
///                   (tap: write and meter)
///
/// The mixer converts an input with more than two channels, for example an aggregate
/// device, to stereo. The muted main mixer keeps the microphone out of the speakers.
@MainActor
final class Recorder: ObservableObject {
    enum RecorderError: LocalizedError {
        case permissionDenied
        case noInput

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Sound Deck cannot use the microphone. Allow it in System Settings, Privacy & Security, Microphone."
            case .noInput:
                return "There is no input device. Connect a microphone and try again."
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// The peak of the last buffer, from 0 to 1.
    @Published private(set) var level: Float = 0
    /// The finished recording. It stays in the temporary directory until the library takes it.
    @Published private(set) var recordingURL: URL?

    private var engine: AVAudioEngine?

    func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RecorderError.permissionDenied }
        discard()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0,
              let recordFormat = AVAudioFormat(
                  standardFormatWithSampleRate: inputFormat.sampleRate,
                  channels: min(inputFormat.channelCount, 2)
              ) else {
            throw RecorderError.noInput
        }

        let mixer = AVAudioMixerNode()
        engine.attach(mixer)
        engine.connect(input, to: mixer, format: inputFormat)
        engine.connect(mixer, to: engine.mainMixerNode, format: recordFormat)
        engine.mainMixerNode.outputVolume = 0

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Recording-\(UUID().uuidString.prefix(8)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: recordFormat.sampleRate,
            AVNumberOfChannelsKey: recordFormat.channelCount,
            AVEncoderBitRateKey: 192_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let sampleRate = recordFormat.sampleRate
        var frames: AVAudioFramePosition = 0

        // The tap runs on an audio thread. It writes the file there, then sends the meter values to the main thread.
        mixer.installTap(onBus: 0, bufferSize: 4096, format: recordFormat) { [weak self] buffer, _ in
            do {
                try file.write(from: buffer)
            } catch {
                print("[DEBUG] Could not write the recording: \(error)")
            }
            frames += AVAudioFramePosition(buffer.frameLength)
            let peak = Self.peak(of: buffer)
            let seconds = Double(frames) / sampleRate
            DispatchQueue.main.async {
                guard let self, self.isRecording else { return }
                self.level = peak
                self.elapsed = seconds
            }
        }

        try engine.start()
        self.engine = engine
        recordingURL = url
        elapsed = 0
        isRecording = true
    }

    /// Stops the recording. The file closes when the engine and the tap release it.
    func stop() {
        guard let engine else { return }
        for node in engine.attachedNodes {
            if let mixer = node as? AVAudioMixerNode, mixer !== engine.mainMixerNode {
                mixer.removeTap(onBus: 0)
            }
        }
        engine.stop()
        self.engine = nil
        isRecording = false
        level = 0
    }

    /// Stops and deletes the recording.
    func discard() {
        stop()
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
        elapsed = 0
    }

    /// The library moved the file. The recorder must not delete it.
    func release() {
        recordingURL = nil
        elapsed = 0
    }

    nonisolated private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(channels[channel][frame]))
            }
        }
        return min(1, peak)
    }
}
