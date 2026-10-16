import Foundation

/// The fade and duck state of one voice.
///
/// It is a pure value, so the tests can step it. The engine calls `advance` about
/// 100 times each second while a fade or a duck change runs. The voice gain is the
/// user volume times the loudness gain times `gain`.
struct VoiceEnvelope: Equatable {
    /// The fade level, from 0 to 1.
    private(set) var fade: Float
    /// The change of `fade` each second. It is negative while the voice fades out.
    private(set) var fadeRate: Float
    /// The duck level, from `AudioEngine.duckLevel` to 1.
    private(set) var duck: Float = 1
    var duckTarget: Float = 1
    private(set) var isStopping = false

    /// Seconds for a full change of the duck level.
    static let duckTime: Float = 0.15

    init(fadeIn: Double) {
        fade = fadeIn > 0 ? 0 : 1
        fadeRate = fadeIn > 0 ? Float(1 / fadeIn) : 0
    }

    var gain: Float { fade * duck }

    /// True while a fade or a duck change runs.
    var isMoving: Bool { fadeRate != 0 || duck != duckTarget }

    /// True when the fade-out is complete. The engine then retires the voice.
    var isSilent: Bool { isStopping && fade <= 0 }

    /// Starts the fade-out. A fade-out of 0 stops at once.
    mutating func stop(fadeOut: Double) {
        isStopping = true
        if fadeOut > 0 {
            fadeRate = -1 / Float(fadeOut)
        } else {
            fade = 0
            fadeRate = 0
        }
    }

    mutating func advance(by seconds: Double) {
        let step = Float(seconds)
        if fadeRate != 0 {
            fade = min(1, max(0, fade + fadeRate * step))
            if fade == 0 || fade == 1 { fadeRate = 0 }
        }
        if duck != duckTarget {
            let change = step / Self.duckTime
            duck = duck < duckTarget ? min(duckTarget, duck + change) : max(duckTarget, duck - change)
        }
    }
}
