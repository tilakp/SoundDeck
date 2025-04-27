import SwiftUI
import AVFoundation

struct WaveformView: View {
    let samples: [Float]
    let color: Color
    
    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let width = geometry.size.width
            let count = samples.count
            let step = max(1, count / Int(width))
            let points = stride(from: 0, to: count, by: step).map { i in
                CGPoint(
                    x: CGFloat(i) / CGFloat(count) * width,
                    y: height / 2 - CGFloat(samples[i]) * height / 2
                )
            }
            Path { path in
                guard points.count > 1 else { return }
                path.move(to: points[0])
                for pt in points.dropFirst() {
                    path.addLine(to: pt)
                }
            }
            .stroke(color, lineWidth: 2)
        }
    }
}

extension AVAsset {
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
            var samples = [Float]()
            while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
                let length = CMBlockBufferGetDataLength(block)
                var data = [Float](repeating: 0, count: length/MemoryLayout<Float>.size)
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data)
                samples.append(contentsOf: data)
            }
            assetReader.cancelReading()
            guard !samples.isEmpty else { completion(nil); return }
            // Downsample to sampleCount
            let downsampled = stride(from: 0, to: samples.count, by: samples.count / sampleCount).map { i in
                let chunk = samples[i..<min(i + samples.count / sampleCount, samples.count)]
                return chunk.max() ?? 0
            }
            let maxAbs = downsampled.map { abs($0) }.max() ?? 1
            completion(downsampled.map { $0 / maxAbs })
        }
    }
}
