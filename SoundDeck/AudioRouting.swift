import AVFoundation
import Foundation

/// The outputs that a pad plays on when a Monitor device is set.
///
/// "Live" is the deck output, for example BlackHole into a call. "Monitor" is a second
/// device, for example headphones. "Me only" lets the user audition a pad that the call
/// does not hear.
enum PadOutput: String, Codable, CaseIterable, Identifiable {
    case both
    case live
    case monitor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .both: return "Both"
        case .live: return "Live"
        case .monitor: return "Me only"
        }
    }
}

/// The outputs that one voice plays on.
struct OutputRoute: Equatable {
    var live: Bool
    var monitor: Bool

    var isEmpty: Bool { !live && !monitor }

    /// Without a monitor, each pad plays on Live. A "Me only" pad then plays nowhere,
    /// because the call must not hear it.
    static func route(for output: PadOutput, monitorIsActive: Bool) -> OutputRoute {
        guard monitorIsActive else { return OutputRoute(live: output != .monitor, monitor: false) }
        switch output {
        case .both: return OutputRoute(live: true, monitor: true)
        case .live: return OutputRoute(live: true, monitor: false)
        case .monitor: return OutputRoute(live: false, monitor: true)
        }
    }
}

/// The settings of the Audio tab. They are in `UserDefaults` as one JSON value.
struct AudioRoutingSettings: Codable, Equatable {
    /// Nil means no monitor.
    var monitorDeviceUID: String?
    var monitorVolume: Float = 0.8
    var micEnabled = false
    /// Nil means the system default input.
    var micDeviceUID: String?
    var micGainDecibels: Double = 0
    var micMuted = false

    static let defaultsKey = "SoundDeckAudioRouting"
    static let micGainRange: ClosedRange<Double> = -24...12

    init() {}

    // A new field must not make an older value unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        monitorDeviceUID = try c.decodeIfPresent(String.self, forKey: .monitorDeviceUID)
        monitorVolume = try c.decodeIfPresent(Float.self, forKey: .monitorVolume) ?? 0.8
        micEnabled = try c.decodeIfPresent(Bool.self, forKey: .micEnabled) ?? false
        micDeviceUID = try c.decodeIfPresent(String.self, forKey: .micDeviceUID)
        micGainDecibels = try c.decodeIfPresent(Double.self, forKey: .micGainDecibels) ?? 0
        micMuted = try c.decodeIfPresent(Bool.self, forKey: .micMuted) ?? false
    }

    static func load(from defaults: UserDefaults) -> AudioRoutingSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(AudioRoutingSettings.self, from: data) else {
            return AudioRoutingSettings()
        }
        return settings
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// The linear gain of the microphone. A muted microphone gives 0.
    var micLinearGain: Float {
        micMuted ? 0 : RoutingMath.linearGain(decibels: micGainDecibels, in: Self.micGainRange)
    }
}

enum RoutingMath {
    /// Converts decibels to a linear gain. The value is first clamped to `range`.
    static func linearGain(decibels: Double, in range: ClosedRange<Double>) -> Float {
        let clamped = min(range.upperBound, max(range.lowerBound, decibels))
        return Float(pow(10, clamped / 20))
    }

    /// The delay before each output starts, in seconds. An output with less latency
    /// waits for the slowest output, so that the sound comes out of all at the same time.
    static func startDelays(latencies: [Double]) -> [Double] {
        let clamped = latencies.map { max(0, $0) }
        let slowest = clamped.max() ?? 0
        return clamped.map { slowest - $0 }
    }
}
