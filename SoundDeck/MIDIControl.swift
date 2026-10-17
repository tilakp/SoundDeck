import CoreMIDI
import Foundation

/// Waits for the next MIDI note or controller and gives it to the view that asked.
///
/// Only one view learns at a time. A new request cancels the previous one.
@MainActor
final class MIDILearn: ObservableObject {
    /// The view that learns now, for example the id of a pad. Nil when no view learns.
    @Published private(set) var owner: String?
    private var completion: ((MIDITrigger) -> Void)?

    func begin(owner: String, completion: @escaping (MIDITrigger) -> Void) {
        self.owner = owner
        self.completion = completion
    }

    func cancel(owner: String) {
        guard self.owner == owner else { return }
        self.owner = nil
        completion = nil
    }

    /// Gives true if the message became a mapping. A Note Off does not.
    func capture(_ message: MIDIMessage) -> Bool {
        guard let completion, let trigger = message.input else { return false }
        if case .noteOff = message { return false }
        owner = nil
        self.completion = nil
        completion(trigger)
        return true
    }
}

/// Receives MIDI from all sources and sends the mapped commands to `DeckCommands`.
///
/// The input is off by default. The enabled state and the Stop All mapping are preferences
/// in `UserDefaults`. CoreMIDI calls the receive block on its own thread. The block parses
/// the words there and sends the messages to the main actor.
@MainActor
final class MIDIControl: ObservableObject {
    static let shared = MIDIControl()

    private static let enabledKey = "midiEnabled"
    private static let stopAllKey = "midiStopAllTrigger"

    @Published private(set) var isEnabled = false
    /// The display names of the connected sources.
    @Published private(set) var sources: [String] = []
    /// For the Settings window, so that the user can see what a controller sends.
    @Published private(set) var lastMessage: String?
    @Published private(set) var error: String?
    @Published private(set) var stopAllTrigger: MIDITrigger?

    let learn = MIDILearn()

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var matcher = MIDIMatcher()
    private var connected: [MIDIEndpointRef] = []

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if let data = UserDefaults.standard.data(forKey: Self.stopAllKey) {
            stopAllTrigger = try? JSONDecoder().decode(MIDITrigger.self, from: data)
        }
    }

    /// Starts the input at app start when the user enabled it.
    func startIfEnabled() {
        if isEnabled { start() }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { start() } else { stop() }
    }

    func setStopAllTrigger(_ trigger: MIDITrigger?) {
        stopAllTrigger = trigger
        if let trigger, let data = try? JSONEncoder().encode(trigger) {
            UserDefaults.standard.set(data, forKey: Self.stopAllKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.stopAllKey)
        }
    }

    private func start() {
        if client == 0 {
            let status = MIDIClientCreateWithBlock("Sound Deck" as CFString, &client, Self.notifyBlock())
            guard status == noErr else { return fail("Could not start MIDI (error \(status)).") }
        }
        if port == 0 {
            let status = MIDIInputPortCreateWithProtocol(
                client, "Sound Deck Input" as CFString, ._1_0, &port, Self.receiveBlock())
            guard status == noErr else { return fail("Could not open the MIDI input (error \(status)).") }
        }
        error = nil
        connectSources()
    }

    private func stop() {
        if port != 0 {
            MIDIPortDispose(port)
            port = 0
        }
        connected = []
        sources = []
        matcher = MIDIMatcher()
    }

    private func fail(_ message: String) {
        print("[DEBUG] MIDI: \(message)")
        error = message
    }

    /// Disconnects all sources, then connects every source that exists now.
    private func connectSources() {
        guard port != 0 else { return }
        connected.forEach { MIDIPortDisconnectSource(port, $0) }
        connected = []
        var names: [String] = []
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            guard source != 0, MIDIPortConnectSource(port, source, nil) == noErr else { continue }
            connected.append(source)
            names.append(Self.displayName(of: source))
        }
        sources = names
        print("[DEBUG] MIDI sources: \(names)")
    }

    private static func displayName(of object: MIDIObjectRef) -> String {
        var name: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &name) == noErr,
              let name else { return "Unknown source" }
        return name.takeRetainedValue() as String
    }

    /// Called on the main actor for each message.
    private func handle(_ message: MIDIMessage) {
        lastMessage = message.label
        if learn.capture(message) { return }
        guard let commands = DeckCommands.shared else { return }
        let actions = matcher.commands(for: message, sounds: commands.library.sounds, stopAll: stopAllTrigger)
        for action in actions {
            switch action {
            case .play(let id): commands.play(id.uuidString)
            case .release(let id): commands.release(id.uuidString)
            case .stopAll: commands.stop()
            }
        }
    }

    // The blocks are made in nonisolated functions. CoreMIDI calls them on its own threads,
    // and a block made inside the main actor could fail an isolation check.

    private nonisolated static func notifyBlock() -> MIDINotifyBlock {
        return { notification in
            // A device came or went. Connect the sources again.
            guard notification.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MIDIControl.shared.connectSources() }
            }
        }
    }

    private nonisolated static func receiveBlock() -> MIDIReceiveBlock {
        return { list, _ in
            let messages = Self.messages(in: list)
            guard !messages.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    messages.forEach { MIDIControl.shared.handle($0) }
                }
            }
        }
    }

    private nonisolated static func messages(in list: UnsafePointer<MIDIEventList>) -> [MIDIMessage] {
        var result: [MIDIMessage] = []
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            let words = withUnsafeBytes(of: packet.pointee.words) { raw in
                Array(raw.bindMemory(to: UInt32.self).prefix(count))
            }
            result += MIDIParser.messages(fromUMP: words)
        }
        return result
    }
}
