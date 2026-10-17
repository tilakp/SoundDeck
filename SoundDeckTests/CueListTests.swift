import Foundation
import Testing
@testable import SoundDeck

struct CueListTests {
    @Test func goPlaysTheStandbyAndMovesDown() {
        #expect(CueList.go(standby: 0, count: 3) == .init(play: 0, standby: 1))
        #expect(CueList.go(standby: 2, count: 3) == .init(play: 2, standby: 3))
    }

    @Test func goAtTheEndPlaysNothing() {
        #expect(CueList.go(standby: 3, count: 3) == .init(play: nil, standby: 3))
        #expect(CueList.go(standby: 0, count: 0) == .init(play: nil, standby: 0))
    }

    @Test func goClampsAStaleStandby() {
        // A removed pad can leave the standby past the end.
        #expect(CueList.go(standby: 9, count: 2) == .init(play: nil, standby: 2))
        #expect(CueList.go(standby: -1, count: 2) == .init(play: 0, standby: 1))
    }

    @Test func arrowsStopAtTheFirstRowAndAtEnd() {
        #expect(CueList.move(0, by: -1, count: 3) == 0)
        #expect(CueList.move(1, by: 1, count: 3) == 2)
        #expect(CueList.move(2, by: 1, count: 3) == 3)
        #expect(CueList.move(3, by: 1, count: 3) == 3)
        #expect(CueList.move(3, by: -1, count: 3) == 2)
        #expect(CueList.move(0, by: 1, count: 0) == 0)
    }

    @Test func durationUsesTrimAndSpeed() {
        #expect(CueList.duration(fileDuration: 10, trimStart: 0, trimEnd: nil, speed: 1) == 10)
        #expect(CueList.duration(fileDuration: 10, trimStart: 2, trimEnd: 6, speed: 2) == 2)
        #expect(CueList.duration(fileDuration: 10, trimStart: 4, trimEnd: 30, speed: 1) == 6)
        #expect(CueList.duration(fileDuration: 10, trimStart: 12, trimEnd: nil, speed: 1) == 0)
    }

    @Test func formatShowsMinutesAndSeconds() {
        #expect(CueList.format(0) == "0:00")
        #expect(CueList.format(65.4) == "1:05")
        #expect(CueList.format(600) == "10:00")
    }
}

struct DeckLayoutTests {
    private func decode(_ json: String) throws -> Deck {
        try JSONDecoder().decode(Deck.self, from: Data(json.utf8))
    }

    @Test func olderDeckDecodesAsGrid() throws {
        let deck = try decode(#"{"name": "Main", "sounds": []}"#)
        #expect(deck.layout == .grid)
        #expect(deck.cueIndex == 0)
    }

    @Test func unknownLayoutDecodesAsGrid() throws {
        #expect(try decode(#"{"name": "Main", "layout": "timeline"}"#).layout == .grid)
    }

    @Test func layoutRoundTripsAndStandbyIsNotSaved() throws {
        var deck = Deck(name: "Show")
        deck.layout = .cueList
        deck.cueIndex = 4
        let data = try JSONEncoder().encode(deck)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("cueIndex"))
        let decoded = try JSONDecoder().decode(Deck.self, from: data)
        #expect(decoded.layout == .cueList)
        #expect(decoded.cueIndex == 0)
    }

    @Test func noteRoundTripsAndIsOptional() throws {
        var sound = SoundItem(name: "Gong.wav")
        sound.note = "After the intro"
        let decoded = try JSONDecoder().decode(SoundItem.self, from: JSONEncoder().encode(sound))
        #expect(decoded.note == "After the intro")
        #expect(SoundItem(name: "Gong.wav").note == nil)
    }
}
