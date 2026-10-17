import AVFoundation
import Foundation

/// The three-band EQ of one pad: a low shelf, a mid peak and a high shelf.
///
/// A flat EQ has all gains at 0 dB. The engine adds no node for a flat EQ, so it costs no CPU.
struct PadEQ: Codable, Equatable {
    static let gainRange: ClosedRange<Double> = -12...12
    static let midFrequencyRange: ClosedRange<Double> = 300...5000
    static let lowFrequency = 120.0
    static let highFrequency = 8000.0
    static let defaultMidFrequency = 1000.0
    /// The Q of the mid peak.
    static let midQ = 0.7

    /// dB. The gain of the low shelf at 120 Hz.
    var low: Double {
        didSet { low = Self.clampGain(low) }
    }
    /// dB. The gain of the mid peak at `midFrequency`.
    var mid: Double {
        didSet { mid = Self.clampGain(mid) }
    }
    /// Hz. The centre of the mid peak.
    var midFrequency: Double {
        didSet { midFrequency = Self.clampFrequency(midFrequency) }
    }
    /// dB. The gain of the high shelf at 8 kHz.
    var high: Double {
        didSet { high = Self.clampGain(high) }
    }

    init(low: Double = 0, mid: Double = 0, midFrequency: Double = PadEQ.defaultMidFrequency, high: Double = 0) {
        self.low = Self.clampGain(low)
        self.mid = Self.clampGain(mid)
        self.midFrequency = Self.clampFrequency(midFrequency)
        self.high = Self.clampGain(high)
    }

    /// A missing or incorrect value is not an error. The band gets its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            low: (try? c.decodeIfPresent(Double.self, forKey: .low)) ?? 0,
            mid: (try? c.decodeIfPresent(Double.self, forKey: .mid)) ?? 0,
            midFrequency: (try? c.decodeIfPresent(Double.self, forKey: .midFrequency)) ?? Self.defaultMidFrequency,
            high: (try? c.decodeIfPresent(Double.self, forKey: .high)) ?? 0
        )
    }

    var isFlat: Bool { low == 0 && mid == 0 && high == 0 }

    /// The EQ that the engine uses. Nil when there is no EQ or the EQ is flat.
    static func effective(_ eq: PadEQ?) -> PadEQ? {
        guard let eq, !eq.isFlat else { return nil }
        return eq
    }

    static func clampGain(_ value: Double) -> Double {
        value.isFinite ? min(max(value, gainRange.lowerBound), gainRange.upperBound) : 0
    }

    static func clampFrequency(_ value: Double) -> Double {
        guard value.isFinite else { return defaultMidFrequency }
        return min(max(value, midFrequencyRange.lowerBound), midFrequencyRange.upperBound)
    }

    // MARK: Band parameters

    /// The values for one `AVAudioUnitEQFilterParameters`.
    struct Band: Equatable {
        var filterType: AVAudioUnitEQFilterType
        var frequency: Float
        var gain: Float
        /// Octaves. Only the parametric band uses it.
        var bandwidth: Float
        /// A band at 0 dB is bypassed.
        var bypass: Bool
    }

    /// Converts a Q value to a bandwidth in octaves.
    static func octaves(forQ q: Double) -> Double {
        2 / log(2) * asinh(1 / (2 * q))
    }

    /// The three bands in order: low shelf, mid peak, high shelf.
    var bands: [Band] {
        let midWidth = Float(Self.octaves(forQ: Self.midQ))
        let lowBand = Band(filterType: .lowShelf, frequency: Float(Self.lowFrequency),
                           gain: Float(low), bandwidth: 1, bypass: low == 0)
        let midBand = Band(filterType: .parametric, frequency: Float(midFrequency),
                           gain: Float(mid), bandwidth: midWidth, bypass: mid == 0)
        let highBand = Band(filterType: .highShelf, frequency: Float(Self.highFrequency),
                            gain: Float(high), bandwidth: 1, bypass: high == 0)
        return [lowBand, midBand, highBand]
    }

    /// Makes a unit with the three bands of this EQ.
    func makeUnit() -> AVAudioUnitEQ {
        let unit = AVAudioUnitEQ(numberOfBands: 3)
        unit.globalGain = 0
        for (parameters, band) in zip(unit.bands, bands) {
            parameters.filterType = band.filterType
            parameters.frequency = band.frequency
            parameters.gain = band.gain
            parameters.bandwidth = band.bandwidth
            parameters.bypass = band.bypass
        }
        return unit
    }
}

// MARK: Log scale for the frequency slider

extension PadEQ {
    /// Gives 0 at 300 Hz and 1 at 5 kHz, on a log scale.
    static func position(forMidFrequency frequency: Double) -> Double {
        let low = log(midFrequencyRange.lowerBound)
        let high = log(midFrequencyRange.upperBound)
        return (log(clampFrequency(frequency)) - low) / (high - low)
    }

    /// The inverse of `position(forMidFrequency:)`. The result is a whole number of hertz.
    static func midFrequency(atPosition position: Double) -> Double {
        let low = log(midFrequencyRange.lowerBound)
        let high = log(midFrequencyRange.upperBound)
        let clamped = min(max(position, 0), 1)
        return clampFrequency(exp(low + clamped * (high - low)).rounded())
    }
}
