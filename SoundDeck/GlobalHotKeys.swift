import AppKit
import Carbon.HIToolbox
import Foundation

/// System-wide keyboard triggers.
///
/// Uses Carbon's `RegisterEventHotKey` rather than `NSEvent.addGlobalMonitorForEvents`
/// deliberately: the global monitor requires the user to grant Accessibility
/// permission and sees *every* keystroke system-wide, which is a lot of trust to ask
/// for a soundboard. `RegisterEventHotKey` needs no permission and only ever fires
/// for the specific combinations registered here.
///
/// The API is C, pre-ARC, and has no user-data parameter on the modern path, so the
/// dispatch table is held in a singleton keyed by hotkey id.
@MainActor
final class GlobalHotKeys {
    static let shared = GlobalHotKeys()

    /// Ctrl+Option is unclaimed by most apps and cheap to reach one-handed.
    static let modifiers: UInt32 = UInt32(controlKey | optionKey)
    static let modifierDescription = "⌃⌥"

    private var handler: EventHandlerRef?
    private var registered: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private let signature: OSType = 0x53444B31 // 'SDK1'

    private(set) var isEnabled = false

    private init() {}

    /// Installs the Carbon event handler. Safe to call repeatedly.
    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                // Carbon calls back on the main thread, but hop explicitly so the
                // actor isolation is provable rather than assumed.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        GlobalHotKeys.shared.fire(id: hotKeyID.id)
                    }
                }
                return noErr
            },
            1,
            &spec,
            nil,
            &handler
        )
    }

    private func fire(id: UInt32) {
        actions[id]?()
    }

    /// Replaces every registration with one derived from the current deck.
    func rebind(_ bindings: [(key: String, action: () -> Void)]) {
        unregisterAll()
        guard isEnabled else { return }
        installHandlerIfNeeded()

        for binding in bindings {
            guard let code = Self.keyCode(for: binding.key) else { continue }
            let id = nextID
            nextID += 1
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: signature, id: id)
            let status = RegisterEventHotKey(code, Self.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered[id] = ref
                actions[id] = binding.action
            } else if status != noErr {
                // Most often because another app already owns the combination.
                print("[DEBUG] Could not register global hotkey \(binding.key) (OSStatus \(status))")
            }
        }
    }

    /// Persists the preference. The caller re-registers afterwards, since only it
    /// knows the current deck.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
    }

    func unregisterAll() {
        for ref in registered.values { UnregisterEventHotKey(ref) }
        registered.removeAll()
        actions.removeAll()
    }

    static let enabledKey = "SoundDeckGlobalHotKeysEnabled"

    func restoreEnabledState() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// Virtual key codes for the characters the deck can bind.
    private static func keyCode(for character: String) -> UInt32? {
        let map: [String: Int] = [
            "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5,
            "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9, "0": kVK_ANSI_0,
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
            "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
            "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
            "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
            "z": kVK_ANSI_Z
        ]
        guard let code = map[character.lowercased()] else { return nil }
        return UInt32(code)
    }
}
