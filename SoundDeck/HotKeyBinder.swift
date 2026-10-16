import AppKit
import Combine
import Foundation

/// Registers the global hotkeys of the active deck.
///
/// It registers again only when the keys change, or when VoiceOver starts or stops.
/// A change of volume or name does not register again. The binder belongs to the
/// application, not to the window, so the keys also change when the window is closed.
@MainActor
final class HotKeyBinder: ObservableObject {
    struct Key: Equatable {
        let soundID: UUID
        let key: String
    }

    private let library: SoundLibrary
    private let register: ([Key]) -> Void
    private var subscription: AnyCancellable?
    private var voiceOverObservation: NSKeyValueObservation?

    /// `register` receives the keys of the active deck. Tests give a closure that records them.
    init(library: SoundLibrary, register: @escaping ([Key]) -> Void) {
        self.library = library
        self.register = register
        subscription = library.$decks.combineLatest(library.$activeDeckID)
            .map { decks, activeID in Self.keys(of: decks.first { $0.id == activeID }) }
            .removeDuplicates()
            .sink { register($0) }
        // The modifiers change when VoiceOver starts or stops.
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Registers the current keys again, for example after the user turns the global hotkeys on.
    func refresh() {
        register(Self.keys(of: library.activeDeck))
    }

    private static func keys(of deck: Deck?) -> [Key] {
        (deck?.sounds ?? []).compactMap { sound in
            sound.hotKey.map { Key(soundID: sound.id, key: $0) }
        }
    }

    /// The binder that the application uses. It triggers a pad through the engine.
    static func live(library: SoundLibrary, engine: AudioEngine) -> HotKeyBinder {
        HotKeyBinder(library: library) { [weak library, weak engine] keys in
            GlobalHotKeys.shared.rebind(keys.map { key in
                (key: key.key,
                 press: {
                     guard let library, let engine, let sound = library.sound(withID: key.soundID) else { return }
                     engine.triggerReportingErrors(sound, in: library)
                 },
                 release: {
                     guard let library, let engine, let sound = library.sound(withID: key.soundID) else { return }
                     engine.release(sound)
                 })
            })
        }
    }
}
