import AVFoundation
import Foundation

/// Measures loudness with ITU-R BS.1770: K-weighting, 400 ms blocks with 75% overlap,
/// an absolute gate at -70 LUFS and a relative gate at -10 LU.
///
/// The engine plays a mono file on both channels. Thus a mono file counts as dual mono.
/// This adds 3 dB to its measurement.
enum Loudness {
    struct Measurement: Equatable {
        /// Integrated loudness in LUFS. Nil for a silent file.
        let lufs: Double?
        /// The largest absolute sample value, from 0 to 1 or more.
        let peak: Float
    }

    /// The level for all pads. Voice chat is usually near this level.
    static let target = -18.0
    /// A quiet recording gets no more boost than this. More boost makes its noise loud.
    static let maxBoost = 12.0
    /// The gain does not push a sample peak above this level.
    static let peakCeiling = -1.0

    /// The linear gain that moves a pad to `target`. It is 1 when there is no measurement.
    static func gain(lufs: Double?, peak: Float?) -> Float {
        guard let lufs, let peak, peak > 0 else { return 1 }
        let peakLimit = peakCeiling - 20 * log10(Double(peak))
        let decibels = min(target - lufs, maxBoost, peakLimit)
        return Float(pow(10, decibels / 20))
    }

    static func measure(url: URL) throws -> Measurement {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let sampleRate = format.sampleRate
        let chunk: AVAudioFrameCount = 32_768
        guard channels > 0, sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            return Measurement(lufs: nil, peak: 0)
        }

        var filters = (0..<channels).map { _ in KWeighting(sampleRate: sampleRate) }
        // The energy of each 100 ms segment, summed over the channels.
        let segmentLength = max(1, Int(sampleRate / 10))
        var segments: [Double] = []
        var segmentEnergy = 0.0
        var segmentFill = 0
        var totalEnergy = 0.0
        var totalFrames = 0
        var peak: Float = 0

        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for frame in 0..<frames {
                var energy = 0.0
                for channel in 0..<channels {
                    let sample = data[channel][frame]
                    peak = max(peak, abs(sample))
                    let weighted = filters[channel].process(Double(sample))
                    energy += weighted * weighted
                }
                segmentEnergy += energy
                totalEnergy += energy
                segmentFill += 1
                if segmentFill == segmentLength {
                    segments.append(segmentEnergy)
                    segmentEnergy = 0
                    segmentFill = 0
                }
            }
            totalFrames += frames
        }

        let monoAdjustment = channels == 1 ? 10 * log10(2.0) : 0
        // Four segments make one 400 ms block. A clip that is shorter than one block is one block.
        var blocks: [Double] = []
        if segments.count >= 4 {
            for start in 0...(segments.count - 4) {
                blocks.append(segments[start..<start + 4].reduce(0, +) / Double(4 * segmentLength))
            }
        } else if totalFrames > 0 {
            blocks = [totalEnergy / Double(totalFrames)]
        }
        let lufs = gatedLoudness(blocks).map { $0 + monoAdjustment }
        return Measurement(lufs: lufs, peak: peak)
    }

    /// Applies the two gates to the mean square of each block.
    static func gatedLoudness(_ blocks: [Double]) -> Double? {
        func loudness(_ meanSquare: Double) -> Double { -0.691 + 10 * log10(meanSquare) }
        let absolute = blocks.filter { $0 > 0 && loudness($0) > -70 }
        guard !absolute.isEmpty else { return nil }
        let relativeGate = loudness(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { loudness($0) > relativeGate }
        guard !gated.isEmpty else { return nil }
        return loudness(gated.reduce(0, +) / Double(gated.count))
    }

    /// The two-stage K-weighting filter. The coefficients follow libebur128, so any sample rate works.
    private struct KWeighting {
        private var shelf: Biquad
        private var highPass: Biquad

        init(sampleRate: Double) {
            // Stage 1: a high shelf of about +4 dB above 1.5 kHz.
            var f0 = 1681.974450955533
            let gain = 3.999843853973347
            var q = 0.7071752369554196
            var k = tan(Double.pi * f0 / sampleRate)
            let vh = pow(10, gain / 20)
            let vb = pow(vh, 0.4996667741545416)
            var a0 = 1 + k / q + k * k
            shelf = Biquad(
                b0: (vh + vb * k / q + k * k) / a0,
                b1: 2 * (k * k - vh) / a0,
                b2: (vh - vb * k / q + k * k) / a0,
                a1: 2 * (k * k - 1) / a0,
                a2: (1 - k / q + k * k) / a0
            )
            // Stage 2: a high pass at about 38 Hz.
            f0 = 38.13547087602444
            q = 0.5003270373238773
            k = tan(Double.pi * f0 / sampleRate)
            a0 = 1 + k / q + k * k
            highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        }

        mutating func process(_ x: Double) -> Double {
            highPass.process(shelf.process(x))
        }
    }

    private struct Biquad {
        let b0, b1, b2, a1, a2: Double
        private var z1 = 0.0
        private var z2 = 0.0

        init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
            (self.b0, self.b1, self.b2, self.a1, self.a2) = (b0, b1, b2, a1, a2)
        }

        // Transposed direct form II.
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }
}
