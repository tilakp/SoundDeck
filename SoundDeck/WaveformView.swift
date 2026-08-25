import AVFoundation
import SwiftUI

/// Mirrored bar waveform with a playhead.
///
/// The original drew a single polyline of raw sample values, which read as noise at
/// this height. Mirroring an amplitude envelope around the centre line and drawing it
/// as discrete bars is both more legible and closer to how audio tools present it.
/// Bars behind the playhead are tinted; bars ahead stay dim, so progress is readable
/// at a glance.
struct WaveformView: View {
    let samples: [Float]
    /// 0...1 playback position.
    var progress: Double = 0
    var tint: Color = Theme.accent

    private let barWidth: CGFloat = 2.5
    private let barGap: CGFloat = 1.5

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let slot = barWidth + barGap
            let barCount = max(1, Int(size.width / slot))
            let envelope = Self.resample(samples, to: barCount)
            let playedCount = Int(Double(barCount) * progress.clamped(to: 0...1))

            HStack(alignment: .center, spacing: barGap) {
                ForEach(0..<envelope.count, id: \.self) { index in
                    let amplitude = CGFloat(envelope[index])
                    // Floor keeps silent passages visible as a hairline rather than gaps.
                    let height = max(2, amplitude * size.height)
                    Capsule()
                        .fill(index < playedCount ? tint : Color.white.opacity(0.16))
                        .frame(width: barWidth, height: height)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .center)
            .animation(.linear(duration: 0.08), value: playedCount)
        }
    }

    /// Buckets an arbitrary-length envelope down to exactly `count` bars.
    private static func resample(_ samples: [Float], to count: Int) -> [Float] {
        guard !samples.isEmpty, count > 0 else { return Array(repeating: 0, count: max(0, count)) }
        guard samples.count > count else {
            return samples + Array(repeating: 0, count: count - samples.count)
        }
        let bucket = Double(samples.count) / Double(count)
        return (0..<count).map { index in
            let start = Int(Double(index) * bucket)
            let end = min(samples.count, max(start + 1, Int(Double(index + 1) * bucket)))
            return samples[start..<end].max() ?? 0
        }
    }
}

/// Placeholder shown when nothing is playing, so the panel does not collapse.
struct WaveformPlaceholder: View {
    var body: some View {
        GeometryReader { geometry in
            let slot: CGFloat = 4
            let count = max(1, Int(geometry.size.width / slot))
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<count, id: \.self) { index in
                    // Static pseudo-random envelope; deterministic so it does not
                    // flicker on every re-render.
                    let seeded = sin(Double(index) * 0.7) * cos(Double(index) * 0.23)
                    let height = 2 + abs(seeded) * 10
                    Capsule()
                        .fill(Color.white.opacity(0.07))
                        .frame(width: 2.5, height: height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension AVAsset {
    /// Decodes an amplitude envelope for display, downsampled to `sampleCount` points.
    func waveformSamples(sampleCount: Int = 500, completion: @escaping ([Float]?) -> Void) {
        Task {
            let tracks = try? await self.loadTracks(withMediaType: .audio)
            guard let track = tracks?.first else { completion(nil); return }
            let assetReader: AVAssetReader
            do {
                assetReader = try AVAssetReader(asset: self)
            } catch {
                print("[Waveform] Failed to create AVAssetReader: \(error)")
                completion(nil)
                return
            }
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            assetReader.add(output)
            assetReader.startReading()

            // Reduce while reading rather than accumulating every frame: a few minutes
            // of 48kHz stereo is tens of millions of floats if buffered whole.
            var envelope = [Float]()
            var runningPeak: Float = 0
            var framesInBucket = 0
            // Coarse bucket sized for a typical clip; exact width does not matter
            // because the view resamples again to fit.
            let bucketFrames = 512

            while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
                let length = CMBlockBufferGetDataLength(block)
                var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data)
                for value in data {
                    runningPeak = max(runningPeak, abs(value))
                    framesInBucket += 1
                    if framesInBucket >= bucketFrames {
                        envelope.append(runningPeak)
                        runningPeak = 0
                        framesInBucket = 0
                    }
                }
                CMSampleBufferInvalidate(buffer)
            }
            if framesInBucket > 0 { envelope.append(runningPeak) }
            assetReader.cancelReading()

            guard let peak = envelope.max(), peak > 0 else { completion(nil); return }
            completion(envelope.map { $0 / peak })
        }
    }
}
