import Foundation
import Testing
@testable import SoundDeck

// MARK: Per-pad progress

@Test func padProgressUsesTheNewestVoiceOfEachPad() {
    let pad = UUID()
    let other = UUID()
    let progress = AudioEngine.padProgress(of: [
        (soundID: pad, startedAt: 100, duration: 10),
        (soundID: pad, startedAt: 104, duration: 10),
        (soundID: other, startedAt: 103, duration: 4),
    ], at: 105)
    #expect(progress[pad] == 0.1)
    #expect(progress[other] == 0.5)
    #expect(progress.count == 2)
}

@Test func padProgressStaysBetweenZeroAndOne() {
    let early = UUID()
    let late = UUID()
    let progress = AudioEngine.padProgress(of: [
        (soundID: early, startedAt: 110, duration: 10),
        (soundID: late, startedAt: 100, duration: 2),
    ], at: 105)
    #expect(progress[early] == 0)
    #expect(progress[late] == 1)
}

@Test func padProgressIsZeroForAVoiceWithNoDuration() {
    let pad = UUID()
    let progress = AudioEngine.padProgress(of: [(soundID: pad, startedAt: 100, duration: 0)], at: 105)
    #expect(progress[pad] == 0)
}

@Test func padProgressIsEmptyWithNoVoices() {
    #expect(AudioEngine.padProgress(of: [], at: 5).isEmpty)
}

// MARK: Grid focus

@Test func gridNavigationMovesInRowsAndColumns() {
    // Seven pads in three columns: rows 0 1 2 / 3 4 5 / 6.
    #expect(PadGridNavigation.neighbour(of: 4, count: 7, columns: 3, direction: .left) == 3)
    #expect(PadGridNavigation.neighbour(of: 4, count: 7, columns: 3, direction: .right) == 5)
    #expect(PadGridNavigation.neighbour(of: 4, count: 7, columns: 3, direction: .up) == 1)
    #expect(PadGridNavigation.neighbour(of: 3, count: 7, columns: 3, direction: .down) == 6)
}

@Test func gridNavigationStopsAtTheEdges() {
    #expect(PadGridNavigation.neighbour(of: 0, count: 7, columns: 3, direction: .left) == nil)
    #expect(PadGridNavigation.neighbour(of: 6, count: 7, columns: 3, direction: .right) == nil)
    #expect(PadGridNavigation.neighbour(of: 1, count: 7, columns: 3, direction: .up) == nil)
    #expect(PadGridNavigation.neighbour(of: 4, count: 7, columns: 3, direction: .down) == nil)
    #expect(PadGridNavigation.neighbour(of: 0, count: 0, columns: 3, direction: .right) == nil)
}
