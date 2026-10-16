import Foundation

/// A short message that goes away by itself. The monitor strip uses it for playback errors.
///
/// A live show must not stop for a modal alert. The message shows for `duration` seconds.
/// A newer message replaces an older one and starts a new period.
struct TransientNotice: Equatable {
    static let duration: TimeInterval = 4

    private(set) var text: String?
    /// Identifies the current message. An expiry for an older message has no effect.
    private(set) var token = 0

    /// Shows a message. Give the returned token to `expire(_:)` after `duration`.
    mutating func show(_ message: String) -> Int {
        token += 1
        text = message
        return token
    }

    /// Removes the message if no newer message replaced it.
    mutating func expire(_ token: Int) {
        guard token == self.token else { return }
        text = nil
    }
}
