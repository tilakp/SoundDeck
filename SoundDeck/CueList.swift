import Foundation

/// The rules of the cue list. A standby index points to the next cue.
/// The index `count` is "End": all cues played, and Go does nothing.
enum CueList {
    /// The result of one Go.
    struct Step: Equatable {
        /// The index of the cue to play. Nil at the end of the list.
        let play: Int?
        /// The new standby index.
        let standby: Int
    }

    /// Keeps a standby index in `0...count`.
    static func clamp(_ index: Int, count: Int) -> Int {
        min(max(0, index), max(0, count))
    }

    /// Moves the standby by `step` rows. The arrows can reach "End" but not go past it.
    static func move(_ index: Int, by step: Int, count: Int) -> Int {
        clamp(clamp(index, count: count) + step, count: count)
    }

    /// Plays the standby cue and puts the standby on the next row.
    static func go(standby: Int, count: Int) -> Step {
        let index = clamp(standby, count: count)
        guard index < count else { return Step(play: nil, standby: count) }
        return Step(play: index, standby: index + 1)
    }

    /// The play time of a cue, in seconds, after the trim and the speed.
    /// `fileDuration` is the length of the file.
    static func duration(fileDuration: Double, trimStart: Double, trimEnd: Double?, speed: Double) -> Double {
        let end = min(trimEnd ?? fileDuration, fileDuration)
        let start = min(max(0, trimStart), end)
        return (end - start) / max(0.01, speed)
    }

    /// A duration as "m:ss", for example "1:05".
    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
