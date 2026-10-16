import Foundation
import Network

/// Receives OSC messages on a UDP port and sends them to `DeckCommands`.
///
/// The server is off by default. The enabled state and the port are preferences in
/// `UserDefaults`. All handlers run on the main queue.
@MainActor
final class OSCServer: ObservableObject {
    static let shared = OSCServer()

    static let defaultPort: UInt16 = 9000
    private static let enabledKey = "oscEnabled"
    private static let portKey = "oscPort"

    enum State: Equatable {
        case off
        case starting
        case listening(UInt16)
        case failed(String)
    }

    @Published private(set) var state: State = .off
    @Published private(set) var isEnabled = false
    @Published private(set) var port: UInt16 = OSCServer.defaultPort

    private var listener: NWListener?
    private var connections: [NWConnection] = []

    private init() {
        let stored = UserDefaults.standard.integer(forKey: Self.portKey)
        if let value = UInt16(exactly: stored), value > 0 { port = value }
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// Starts the server at app start when the user enabled it.
    func startIfEnabled() {
        if isEnabled { start() }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { start() } else { stop() }
    }

    func setPort(_ newPort: UInt16) {
        guard newPort > 0, newPort != port else { return }
        port = newPort
        UserDefaults.standard.set(Int(newPort), forKey: Self.portKey)
        if isEnabled { start() }
    }

    private func start() {
        stop()
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let listener: NWListener
        do {
            listener = try NWListener(using: .udp, on: endpointPort)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        let port = self.port
        listener.stateUpdateHandler = { [weak self, weak listener] newState in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                switch newState {
                case .ready:
                    self.state = .listening(port)
                    print("[DEBUG] OSC listening on UDP port \(port)")
                case .failed(let error), .waiting(let error):
                    self.state = .failed(error.localizedDescription)
                    print("[DEBUG] OSC listener error: \(error)")
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        self.listener = listener
        state = .starting
        listener.start(queue: .main)
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        state = .off
    }

    /// UDP has no connections. The framework makes one `NWConnection` for each sender.
    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] newState in
            MainActor.assumeIsolated {
                guard let self, let connection else { return }
                switch newState {
                case .failed, .cancelled:
                    self.connections.removeAll { $0 === connection }
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, let connection else { return }
                if let data { self.handle(data) }
                if error == nil { self.receive(on: connection) }
            }
        }
    }

    private func handle(_ data: Data) {
        for message in OSCParser.messages(in: data) {
            guard let command = OSCCommand.command(for: message) else {
                print("[DEBUG] OSC ignored \(message.address)")
                continue
            }
            guard let commands = DeckCommands.shared else { return }
            let found: Bool
            switch command {
            case .play(let pad): found = commands.play(pad)
            case .release(let pad): found = commands.release(pad)
            case .stop(let pad): found = commands.stop(pad)
            case .deck(let name): found = commands.selectDeck(name)
            }
            if !found { print("[DEBUG] OSC found no match for \(message.address) \(message.arguments)") }
        }
    }

    /// The IPv4 addresses of this Mac, without the loopback address.
    static func localAddresses() -> [String] {
        var result: [String] = []
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var pointer = first
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                                     nil, 0, NI_NUMERICHOST)
            if status == 0 { result.append(String(cString: host)) }
        }
        return result
    }
}
