import Testing
@testable import SoundDeck

struct MenuBarDeckTests {
    @Test func deckPickerStyleFollowsDeckCount() {
        #expect(MenuBarDeck.DeckPickerStyle.forDeckCount(0) == .none)
        #expect(MenuBarDeck.DeckPickerStyle.forDeckCount(1) == .none)
        #expect(MenuBarDeck.DeckPickerStyle.forDeckCount(2) == .segmented)
        #expect(MenuBarDeck.DeckPickerStyle.forDeckCount(4) == .segmented)
        #expect(MenuBarDeck.DeckPickerStyle.forDeckCount(5) == .menu)
    }

    @Test func padLabelHasNameOnlyWhenIdle() {
        let label = MiniPadGrid.accessibilityLabel(name: "Airhorn", key: nil, isPlaying: false, hasError: false)
        #expect(label == "Airhorn")
    }

    @Test func padLabelHasKeyAndState() {
        let label = MiniPadGrid.accessibilityLabel(name: "Airhorn", key: "q", isPlaying: true, hasError: true)
        #expect(label == "Airhorn, key Q, playing, failed")
    }
}
