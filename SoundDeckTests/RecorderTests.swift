import Foundation
import Testing
@testable import SoundDeck

struct RecordingTimeFormatTests {
    @Test func formatsMinutesSecondsAndTenths() {
        #expect(RecordingTrim.format(0) == "0:00.0")
        #expect(RecordingTrim.format(3.25) == "0:03.2")
        #expect(RecordingTrim.format(65.3) == "1:05.3")
        #expect(RecordingTrim.format(600) == "10:00.0")
    }

    @Test func tenthsDoNotLoseAStepToRounding() {
        // 0.3 * 10 is not exactly 3 in binary. The text must still show 3 tenths.
        #expect(RecordingTrim.format(0.3) == "0:00.3")
        #expect(RecordingTrim.format(1.7) == "0:01.7")
    }

    @Test func negativeTimeShowsZero() {
        #expect(RecordingTrim.format(-1) == "0:00.0")
    }
}

struct RecordingTrimWindowTests {
    @Test func handlesAtTheEdgesGiveNoTrim() {
        let window = RecordingTrim.window(start: 0, end: 4, duration: 4)
        #expect(window.start == 0)
        #expect(window.end == nil)
    }

    @Test func handlesNearTheEdgesGiveNoTrim() {
        let window = RecordingTrim.window(start: 0.005, end: 3.995, duration: 4)
        #expect(window.start == 0)
        #expect(window.end == nil)
    }

    @Test func movedHandlesGiveTheirSeconds() {
        let window = RecordingTrim.window(start: 0.5, end: 3.2, duration: 4)
        #expect(window.start == 0.5)
        #expect(window.end == 3.2)
    }

    @Test func valuesOutsideTheFileAreClamped() {
        let window = RecordingTrim.window(start: -1, end: 9, duration: 4)
        #expect(window.start == 0)
        #expect(window.end == nil)
    }

    @Test func endBeforeStartIsRaisedToStart() {
        let window = RecordingTrim.window(start: 2, end: 1, duration: 4)
        #expect(window.start == 2)
        #expect(window.end == 2)
    }

    @Test func zeroDurationGivesNoTrim() {
        let window = RecordingTrim.window(start: 1, end: 2, duration: 0)
        #expect(window.start == 0)
        #expect(window.end == nil)
    }
}
