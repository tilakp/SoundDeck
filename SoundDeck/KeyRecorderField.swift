import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The rules of the key recorder. These functions have no UI, so the tests can call them.
enum KeyRecording {
    /// The characters that a pad can use. This set agrees with `GlobalHotKeys.keyCode(for:)`.
    static let allowedCharacters: Set<Character> = Set("abcdefghijklmnopqrstuvwxyz0123456789")

    /// What one key press does while the field records.
    enum Action: Equatable {
        /// Record this key. The key is lowercase.
        case record(String)
        /// Remove the key from the pad.
        case clear
        /// Stop the recording and keep the old key.
        case cancel
        /// Keep the recording. The key is not a permitted key.
        case ignore
        /// Give the event to the app. This keeps menu shortcuts such as Command-W.
        case passThrough
    }

    /// Gives the lowercase key for the typed characters, or nil if the pad cannot use them.
    static func normalized(_ characters: String?) -> String? {
        guard let lower = characters?.lowercased(), lower.count == 1,
              let character = lower.first, allowedCharacters.contains(character) else { return nil }
        return lower
    }

    /// Gives the action for one key press.
    ///
    /// Use `charactersIgnoringModifiers` for `characters`. Then Option-A gives "a" and not "å".
    static func action(keyCode: UInt16, characters: String?, commandOrControl: Bool) -> Action {
        if commandOrControl { return .passThrough }
        switch Int(keyCode) {
        case kVK_Escape: return .cancel
        case kVK_Delete, kVK_ForwardDelete: return .clear
        default: break
        }
        guard let key = normalized(characters) else { return .ignore }
        return .record(key)
    }

    /// Gives the other pad that has the key, if there is one.
    static func owner(of key: String, excluding id: UUID, in sounds: [SoundItem]) -> SoundItem? {
        guard !key.isEmpty else { return nil }
        let lower = key.lowercased()
        return sounds.first { $0.id != id && $0.hotKey?.lowercased() == lower }
    }
}

/// A field that records one key. Click it, then press a letter or a digit.
///
/// Delete or Backspace clears the key. Escape stops the recording and keeps the old key.
/// A click on the field during the recording also stops it.
struct KeyRecorderField: View {
    @Binding var key: String
    var tint: Color = Theme.accent

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hovering = false

    var body: some View {
        Button(action: toggleRecording) {
            HStack(spacing: Theme.Spacing.s) {
                if isRecording {
                    Text("Press a key")
                        .font(Theme.Font.body())
                        .foregroundStyle(Theme.textPrimary)
                } else if key.isEmpty {
                    Text("Click to set")
                        .font(Theme.Font.body())
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    KeyCap(key: key)
                }
            }
            .frame(minWidth: 96, minHeight: 22)
            .padding(.horizontal, Theme.Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(hovering || isRecording ? Theme.surfaceHover : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(isRecording ? tint : Theme.strokeStrong, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Click, then press a letter or a digit. Delete clears the key. Escape cancels.")
        .accessibilityLabel("Hotkey")
        .accessibilityValue(isRecording ? "Recording" : (key.isEmpty ? "None" : key.uppercased()))
        .accessibilityHint("Click, then press a letter or a digit.")
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        // A local monitor sees only the key events of this app. It needs no permission.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let action = KeyRecording.action(
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers,
                commandOrControl: flags.contains(.command) || flags.contains(.control)
            )
            switch action {
            case .record(let newKey):
                key = newKey
                stopRecording()
            case .clear:
                key = ""
                stopRecording()
            case .cancel:
                stopRecording()
            case .ignore:
                break
            case .passThrough:
                return event
            }
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
