import Foundation
import Testing
@testable import SoundDeck

struct FloatingDeckTests {
    private func makeDefaults() -> UserDefaults {
        let name = "FloatingDeckTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func preferenceIsClosedByDefault() {
        #expect(FloatingDeckPreference(defaults: makeDefaults()).isOpen == false)
    }

    @Test func preferenceKeepsTheOpenState() {
        let defaults = makeDefaults()
        FloatingDeckPreference(defaults: defaults).isOpen = true
        #expect(FloatingDeckPreference(defaults: defaults).isOpen)
        FloatingDeckPreference(defaults: defaults).isOpen = false
        #expect(FloatingDeckPreference(defaults: defaults).isOpen == false)
    }
}
