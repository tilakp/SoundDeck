import Foundation

// MARK: - IRC line parser

/// One line of Twitch IRC, for example
/// `@badges=moderator/1;display-name=Ann :ann!ann@ann.tmi.twitch.tv PRIVMSG #chan :!sound gong`.
struct IRCMessage: Equatable {
    var tags: [String: String] = [:]
    var prefix: String?
    var command: String
    var params: [String] = []
    var trailing: String?

    /// The nick in the prefix: the text before `!`.
    var nick: String? {
        guard let prefix else { return nil }
        return prefix.split(separator: "!", maxSplits: 1).first.map(String.init)
    }

    /// Parses one line without the line end. Returns nil for an empty line or a line without a command.
    static func parse(_ line: String) -> IRCMessage? {
        var rest = Substring(line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n")))
        var tags: [String: String] = [:]
        if rest.hasPrefix("@") {
            let end = rest.firstIndex(of: " ") ?? rest.endIndex
            for pair in rest[rest.index(after: rest.startIndex)..<end].split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let value = parts.count > 1 ? unescapeTagValue(String(parts[1])) : ""
                tags[String(parts[0])] = value
            }
            rest = rest[end...].drop { $0 == " " }
        }
        var prefix: String?
        if rest.hasPrefix(":") {
            let end = rest.firstIndex(of: " ") ?? rest.endIndex
            prefix = String(rest[rest.index(after: rest.startIndex)..<end])
            rest = rest[end...].drop { $0 == " " }
        }
        var trailing: String?
        if let range = rest.range(of: " :") {
            trailing = String(rest[range.upperBound...])
            rest = rest[..<range.lowerBound]
        } else if rest.hasPrefix(":") {
            return nil
        }
        let words = rest.split(separator: " ").map(String.init)
        guard let command = words.first else { return nil }
        return IRCMessage(tags: tags, prefix: prefix, command: command.uppercased(),
                          params: Array(words.dropFirst()), trailing: trailing)
    }

    /// Reverses the IRCv3 escapes in a tag value.
    static func unescapeTagValue(_ value: String) -> String {
        var result = ""
        var escaping = false
        for character in value {
            if escaping {
                switch character {
                case ":": result.append(";")
                case "s": result.append(" ")
                case "r": result.append("\r")
                case "n": result.append("\n")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}

// MARK: - Chat triggers

/// The settings that control which chat messages play a pad.
struct ChatTriggerSettings: Equatable {
    var prefix = "!sound"
    /// True: all pads of the active deck. False: only the pads in `allowedPads`.
    var allowAllPads = true
    var allowedPads: [String] = []
    var globalCooldown: TimeInterval = 10
    var userCooldown: TimeInterval = 30
    var privilegedOnly = false

    /// Splits a comma-separated list of pad names.
    static func padList(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// Decides if a chat message plays a pad. It keeps the cooldowns.
/// The caller gives the time, so that tests can use their own clock.
struct ChatTriggerGate {
    enum Outcome: Equatable {
        /// The message is not a command, or it names no pad.
        case ignored
        case notAllowed
        case unknownPad
        case cooldown
        case play(user: String, pad: String)
    }

    private(set) var lastGlobal: Date?
    private(set) var lastByUser: [String: Date] = [:]

    /// The pad name after the prefix, or nil when the text is not a command.
    static func padQuery(in text: String, prefix: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = prefix.trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty, text.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        let rest = text.dropFirst(prefix.count)
        // "!soundboard" is not "!sound board".
        guard let first = rest.first, first.isWhitespace else { return nil }
        let query = rest.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? nil : query
    }

    /// True for a subscriber, a moderator or the broadcaster.
    static func isPrivileged(_ tags: [String: String]) -> Bool {
        if tags["subscriber"] == "1" || tags["mod"] == "1" { return true }
        let badges = (tags["badges"] ?? "").split(separator: ",")
        return badges.contains { $0.hasPrefix("broadcaster/") }
    }

    /// Evaluates one IRC message. `activePads` holds the pad names of the active deck.
    /// Only an accepted message starts the cooldowns.
    mutating func evaluate(_ message: IRCMessage, settings: ChatTriggerSettings,
                           activePads: [String], now: Date) -> Outcome {
        guard message.command == "PRIVMSG", let text = message.trailing,
              let query = Self.padQuery(in: text, prefix: settings.prefix) else { return .ignored }
        if settings.privilegedOnly && !Self.isPrivileged(message.tags) { return .notAllowed }
        let candidates = settings.allowAllPads ? activePads : settings.allowedPads
        let match = candidates.first { $0.compare(query, options: .caseInsensitive) == .orderedSame }
        guard let pad = match else { return .unknownPad }
        let userKey = message.tags["user-id"] ?? message.nick?.lowercased() ?? ""
        if let last = lastGlobal, now.timeIntervalSince(last) < settings.globalCooldown { return .cooldown }
        if let last = lastByUser[userKey], now.timeIntervalSince(last) < settings.userCooldown { return .cooldown }
        lastGlobal = now
        lastByUser[userKey] = now
        let user = message.tags["display-name"].flatMap { $0.isEmpty ? nil : $0 } ?? message.nick ?? "?"
        return .play(user: user, pad: pad)
    }
}

// MARK: - Connection

/// Reads the chat of one Twitch channel and plays pads for `!sound <pad>` commands.
///
/// The connection is anonymous and read-only. Twitch accepts a `justinfan<number>` nick
/// with any password. A channel point reward needs OAuth and is not supported.
@MainActor
final class TwitchChat: ObservableObject {
    static let shared = TwitchChat()

    enum Keys {
        static let enabled = "twitch.enabled"
        static let channel = "twitch.channel"
        static let prefix = "twitch.prefix"
        static let allowAllPads = "twitch.allowAllPads"
        static let allowedPads = "twitch.allowedPads"
        static let globalCooldown = "twitch.globalCooldown"
        static let userCooldown = "twitch.userCooldown"
        static let privilegedOnly = "twitch.privilegedOnly"
    }

    enum State: Equatable {
        case off
        case connecting
        case connected
        case waiting(seconds: Int)

        var label: String {
            switch self {
            case .off: return "Off"
            case .connecting: return "Connecting"
            case .connected: return "Connected"
            case .waiting(let seconds): return "Connection lost. Retry in \(seconds) s"
            }
        }
    }

    struct Trigger: Identifiable, Equatable {
        let id = UUID()
        let user: String
        let pad: String
    }

    @Published private(set) var state: State = .off
    /// The last 5 triggers, the newest first.
    @Published private(set) var recentTriggers: [Trigger] = []

    private let defaults: UserDefaults
    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var gate = ChatTriggerGate()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Lowercase, without `#` and spaces.
    nonisolated static func normalizedChannel(_ text: String) -> String {
        var channel = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while channel.hasPrefix("#") { channel.removeFirst() }
        return channel
    }

    var settings: ChatTriggerSettings {
        var settings = ChatTriggerSettings()
        if let prefix = defaults.string(forKey: Keys.prefix), !prefix.isEmpty { settings.prefix = prefix }
        if defaults.object(forKey: Keys.allowAllPads) != nil {
            settings.allowAllPads = defaults.bool(forKey: Keys.allowAllPads)
        }
        settings.allowedPads = ChatTriggerSettings.padList(defaults.string(forKey: Keys.allowedPads) ?? "")
        if defaults.object(forKey: Keys.globalCooldown) != nil {
            settings.globalCooldown = max(0, defaults.double(forKey: Keys.globalCooldown))
        }
        if defaults.object(forKey: Keys.userCooldown) != nil {
            settings.userCooldown = max(0, defaults.double(forKey: Keys.userCooldown))
        }
        settings.privilegedOnly = defaults.bool(forKey: Keys.privilegedOnly)
        return settings
    }

    /// Connects when the setting is on and a channel is set. Otherwise disconnects.
    /// Call it after a change to the enable toggle or to the channel.
    func restart() {
        stop()
        let channel = Self.normalizedChannel(defaults.string(forKey: Keys.channel) ?? "")
        guard defaults.bool(forKey: Keys.enabled), !channel.isEmpty else { return }
        loop = Task { [weak self] in await self?.run(channel: channel) }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        state = .off
    }

    /// Connects, reads and reconnects with backoff until the task is cancelled.
    private func run(channel: String) async {
        var delay = 1
        while !Task.isCancelled {
            state = .connecting
            let received = await session(channel: channel)
            guard !Task.isCancelled else { return }
            // A session that received data was healthy. Start the backoff again.
            if received { delay = 1 }
            print("[DEBUG] Twitch chat dropped. Retry in \(delay) s")
            for remaining in stride(from: delay, to: 0, by: -1) {
                state = .waiting(seconds: remaining)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            delay = min(delay * 2, 60)
        }
    }

    /// One connection. Returns true when the connection received data.
    private func session(channel: String) async -> Bool {
        guard let url = URL(string: "wss://irc-ws.chat.twitch.tv:443") else { return false }
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        var received = false
        defer {
            task.cancel(with: .goingAway, reason: nil)
            if socket === task { socket = nil }
        }
        do {
            let nick = "justinfan\(Int.random(in: 10_000...99_999))"
            for line in ["CAP REQ :twitch.tv/tags", "PASS SCHMOOPIIE", "NICK \(nick)", "JOIN #\(channel)"] {
                try await task.send(.string(line))
            }
            while !Task.isCancelled {
                let text: String
                switch try await task.receive() {
                case .string(let string): text = string
                case .data(let data): text = String(decoding: data, as: UTF8.self)
                @unknown default: continue
                }
                received = true
                for line in text.split(whereSeparator: \.isNewline) {
                    guard let message = IRCMessage.parse(String(line)) else { continue }
                    if try await handle(message, task: task) == false { return received }
                }
            }
        } catch {
            print("[DEBUG] Twitch chat error: \(error.localizedDescription)")
        }
        return received
    }

    /// Returns false when the server asks for a new connection.
    private func handle(_ message: IRCMessage, task: URLSessionWebSocketTask) async throws -> Bool {
        switch message.command {
        case "PING":
            try await task.send(.string("PONG :\(message.trailing ?? "tmi.twitch.tv")"))
        case "RECONNECT":
            return false
        case "JOIN":
            state = .connected
        case "PRIVMSG":
            handleChat(message)
        default:
            break
        }
        return true
    }

    private func handleChat(_ message: IRCMessage) {
        guard let commands = DeckCommands.shared else { return }
        let names = commands.library.activeDeck.sounds.map(\.name)
        let outcome = gate.evaluate(message, settings: settings, activePads: names, now: Date())
        guard case .play(let user, let pad) = outcome else { return }
        // No release follows, so a Hold pad plays to its end.
        guard commands.play(pad) else { return }
        print("[DEBUG] Twitch chat: \(user) played \(pad)")
        recentTriggers.insert(Trigger(user: user, pad: pad), at: 0)
        if recentTriggers.count > 5 { recentTriggers.removeLast(recentTriggers.count - 5) }
    }
}
