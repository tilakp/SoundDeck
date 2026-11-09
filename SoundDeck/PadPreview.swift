import AVFoundation
import SwiftUI

/// The small preview on a tile: a short amplitude envelope and the play length.
struct PadPreview: Equatable {
    /// Peaks from 0 to 1, one value for each bar.
    let envelope: [Float]
    /// The length of one play in seconds. It includes the trim and the speed.
    let duration: Double

    /// The number of bars on a tile.
    static let barCount = 32

    /// Reads the trimmed part of the file. The read reduces each block at once,
    /// so a long file does not fill the memory.
    nonisolated static func make(url: URL, trimStart: Double, trimEnd: Double?, speed: Double,
                                 bars: Int = barCount) throws -> PadPreview {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let window = AudioEngine.trimWindow(trimStart: trimStart, trimEnd: trimEnd,
                                            totalFrames: file.length, sampleRate: format.sampleRate)
        let frames = Int(window.frameCount)
        let duration = Double(frames) / format.sampleRate / max(speed, 0.01)
        guard frames > 0, bars > 0 else {
            return PadPreview(envelope: Array(repeating: 0, count: max(0, bars)), duration: duration)
        }
        file.framePosition = window.startFrame
        // A bucket has at least one frame. A zero stride causes a trap with a short clip.
        let bucket = max(1, Int((Double(frames) / Double(bars)).rounded(.up)))
        var peaks = [Float](repeating: 0, count: bars)
        let chunk: AVAudioFrameCount = 8192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            return PadPreview(envelope: peaks, duration: duration)
        }
        var read = 0
        while read < frames {
            let want = AVAudioFrameCount(min(Int(chunk), frames - read))
            try file.read(into: buffer, frameCount: want)
            let got = Int(buffer.frameLength)
            if got == 0 { break }
            for channel in 0..<Int(format.channelCount) {
                guard let data = buffer.floatChannelData?[channel] else { continue }
                for index in 0..<got {
                    let bar = min(bars - 1, (read + index) / bucket)
                    peaks[bar] = max(peaks[bar], abs(data[index]))
                }
            }
            read += got
        }
        let top = peaks.max() ?? 0
        return PadPreview(envelope: top > 0 ? peaks.map { $0 / top } : peaks, duration: duration)
    }

    /// "4.1s" under 10 seconds, else "1:23".
    static func format(duration: Double) -> String {
        guard duration.isFinite, duration >= 0 else { return "" }
        if duration < 9.95 { return String(format: "%.1fs", duration) }
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Holds the previews of the tiles. The library measures each pad one time.
/// A change to the trim, the speed or the file makes a new key, so the preview is made again.
@MainActor
final class PadPreviews: ObservableObject {
    struct Key: Hashable {
        let id: UUID
        let fileName: String
        let trimStart: Double
        let trimEnd: Double?
        let speed: Double

        init(_ sound: SoundItem) {
            id = sound.id
            fileName = sound.fileName
            trimStart = sound.trimStart
            trimEnd = sound.trimEnd
            speed = sound.speed
        }
    }

    @Published private(set) var previews: [Key: PadPreview] = [:]
    private var loading: Set<Key> = []

    func preview(for sound: SoundItem) -> PadPreview? {
        previews[Key(sound)]
    }

    /// Makes the preview in the background. It does nothing when the preview exists or loads.
    func load(_ sound: SoundItem, resolution: SoundResolution?) {
        let key = Key(sound)
        guard previews[key] == nil, !loading.contains(key), let resolution else { return }
        loading.insert(key)
        Task.detached(priority: .utility) { [weak self] in
            let didAccess = resolution.needsSecurityScope && resolution.url.startAccessingSecurityScopedResource()
            defer { if didAccess { resolution.url.stopAccessingSecurityScopedResource() } }
            let preview = try? PadPreview.make(url: resolution.url, trimStart: key.trimStart,
                                               trimEnd: key.trimEnd, speed: key.speed)
            await self?.finish(key, with: preview)
        }
    }

    private func finish(_ key: Key, with preview: PadPreview?) {
        loading.remove(key)
        if let preview { previews[key] = preview }
    }
}
