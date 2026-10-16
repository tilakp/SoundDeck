import Foundation
import Network

// MARK: - HTTP request

/// One HTTP/1.1 request. The header names are in lowercase.
struct HTTPRequest: Equatable {
    var method: String
    /// The path without the query.
    var path: String
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// The result of one parse of the bytes that a connection received.
enum HTTPParseResult: Equatable {
    /// The request is not complete. Read more bytes.
    case incomplete
    case request(HTTPRequest)
    /// The request is not valid. Send this status and close the connection.
    case failure(status: Int)
}

/// Reads a request line, the headers and a body of `Content-Length` bytes.
///
/// The parser is a pure function, so that the tests can give it any bytes.
/// It does not accept chunked bodies. The web remote does not send them.
enum HTTPParser {
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 64 * 1024

    static func parse(_ received: Data) -> HTTPParseResult {
        let data = Data(received)
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .failure(status: 431) : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes else { return .failure(status: 431) }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else {
            return .failure(status: 400)
        }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3,
              requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0",
              !requestLine[0].isEmpty,
              requestLine[0].allSatisfy({ $0.isASCII && $0.isUppercase }),
              requestLine[1].hasPrefix("/")
        else { return .failure(status: 400) }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .failure(status: 400) }
            let name = line[..<colon]
            guard !name.isEmpty, !name.contains(where: { $0 == " " || $0 == "\t" }) else {
                return .failure(status: 400)
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let key = name.lowercased()
            if let earlier = headers[key], key == "content-length", earlier != value {
                return .failure(status: 400)
            }
            headers[key] = value
        }

        if headers["transfer-encoding"] != nil { return .failure(status: 501) }
        var length = 0
        if let text = headers["content-length"] {
            guard !text.isEmpty, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber) else {
                return .failure(status: 400)
            }
            // A number that is too large for Int is also too large for the limit.
            guard let value = Int(text), value <= maxBodyBytes else { return .failure(status: 413) }
            length = value
        }

        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]

        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? target
        return .request(HTTPRequest(method: String(requestLine[0]), path: path,
                                    headers: headers, body: Data(body)))
    }
}

// MARK: - HTTP response

struct HTTPResponse: Equatable {
    var status: Int
    var contentType: String
    var body: Data
    var headers: [String: String] = [:]

    static let reasons: [Int: String] = [
        200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
        405: "Method Not Allowed", 413: "Content Too Large", 429: "Too Many Requests",
        431: "Request Header Fields Too Large", 500: "Internal Server Error",
        501: "Not Implemented", 503: "Service Unavailable",
    ]

    /// A short JSON body: `{"ok":true}` or `{"error":"Not Found"}`.
    static func status(_ status: Int) -> HTTPResponse {
        let text = status == 200 ? #"{"ok":true}"# : #"{"error":"\#(reasons[status] ?? "Error")"}"#
        return HTTPResponse(status: status, contentType: "application/json", body: Data(text.utf8))
    }

    static func json<Value: Encodable>(_ value: Value) -> HTTPResponse {
        guard let body = try? JSONEncoder().encode(value) else { return .status(500) }
        return HTTPResponse(status: 200, contentType: "application/json", body: body)
    }

    /// The bytes to send. The server closes the connection after each response.
    func serialized() -> Data {
        var lines = [
            "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Error")",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "Cache-Control: no-store",
            "X-Content-Type-Options: nosniff",
        ]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name): \(value)")
        }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        return data
    }
}

// MARK: - Routing

/// What a request asks the deck to do.
enum WebRemoteCommand: Equatable {
    case page
    case pads
    case play(String)
    case release(String)
    /// Stops one pad, or all pads when the value is nil.
    case stop(String?)
    case deck(String)
}

/// Turns a request into a command. It also does the check of the pairing code.
enum WebRemoteRouter {
    static let codeHeader = "X-Pairing-Code"

    enum Decision: Equatable {
        case command(WebRemoteCommand)
        case reject(status: Int)
    }

    private struct Body: Decodable {
        var pad: String?
        var deck: String?
    }

    static func decide(_ request: HTTPRequest, pairingCode: String) -> Decision {
        // The page has no secrets. It asks for the code and sends it with each API call.
        if request.path == "/" {
            return request.method == "GET" ? .command(.page) : .reject(status: 405)
        }
        guard request.path.hasPrefix("/api/") else { return .reject(status: 404) }
        // Check the code before the path, so that a client without the code learns nothing.
        guard let sent = request.header(codeHeader), codesMatch(sent, pairingCode) else {
            return .reject(status: 401)
        }

        let endpoints = ["/api/pads": "GET", "/api/play": "POST", "/api/release": "POST",
                         "/api/stop": "POST", "/api/deck": "POST"]
        guard let method = endpoints[request.path] else { return .reject(status: 404) }
        guard request.method == method else { return .reject(status: 405) }
        if request.path == "/api/pads" { return .command(.pads) }

        let body: Body
        if request.body.isEmpty {
            body = Body()
        } else {
            guard let decoded = try? JSONDecoder().decode(Body.self, from: request.body) else {
                return .reject(status: 400)
            }
            body = decoded
        }
        let pad = body.pad.flatMap { $0.isEmpty ? nil : $0 }
        switch request.path {
        case "/api/stop":
            return .command(.stop(pad))
        case "/api/deck":
            guard let deck = body.deck, !deck.isEmpty else { return .reject(status: 400) }
            return .command(.deck(deck))
        default:
            guard let pad else { return .reject(status: 400) }
            return .command(request.path == "/api/play" ? .play(pad) : .release(pad))
        }
    }

    /// Compares in constant time, so that the time of a reply does not tell which digits are correct.
    static func codesMatch(_ sent: String, _ expected: String) -> Bool {
        let a = Array(sent.utf8)
        let b = Array(expected.utf8)
        guard !b.isEmpty, a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}

/// Blocks the API after too many incorrect codes in a short time.
///
/// A six-digit code has one million values. With 10 attempts each minute, a search takes months.
struct FailureThrottle {
    var limit = 10
    var window: TimeInterval = 60
    private(set) var failures: [Date] = []

    mutating func isBlocked(at now: Date) -> Bool {
        failures.removeAll { now.timeIntervalSince($0) >= window }
        return failures.count >= limit
    }

    mutating func recordFailure(at now: Date) {
        failures.append(now)
    }

    mutating func reset() {
        failures.removeAll()
    }
}

/// The JSON of `GET /api/pads`.
struct WebRemoteState: Codable, Equatable {
    struct DeckEntry: Codable, Equatable {
        let id: UUID
        let name: String
    }

    let decks: [DeckEntry]
    let activeDeck: UUID
    let pads: [DeckCommands.PadInfo]
}

// MARK: - Server

/// Serves the web remote: one page and a small JSON API on the local network.
///
/// The server is off by default. The settings are in `UserDefaults`.
/// Each API call must send the pairing code in the `X-Pairing-Code` header.
@MainActor
final class WebRemoteServer: ObservableObject {
    static let shared = WebRemoteServer()
    static let defaultPort: UInt16 = 8787
    /// The server closes a connection that does not complete a request in this time.
    nonisolated static let connectionTimeout: TimeInterval = 10

    enum Status: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    private enum Key {
        static let enabled = "webRemoteEnabled"
        static let port = "webRemotePort"
        static let code = "webRemotePairingCode"
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var port: UInt16
    @Published private(set) var pairingCode: String
    @Published private(set) var status: Status = .stopped

    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "SoundDeck.WebRemoteServer")
    private var listener: NWListener?
    private var throttle = FailureThrottle()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Key.enabled)
        let stored = defaults.integer(forKey: Key.port)
        port = Self.isValidPort(stored) ? UInt16(stored) : Self.defaultPort
        if let code = defaults.string(forKey: Key.code), code.count == 6, code.allSatisfy(\.isNumber) {
            pairingCode = code
        } else {
            pairingCode = Self.makeCode()
            defaults.set(pairingCode, forKey: Key.code)
        }
    }

    /// A random code of six digits. The system generator is cryptographically secure.
    static func makeCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    static func isValidPort(_ value: Int) -> Bool {
        (1024...65535).contains(value)
    }

    func startIfEnabled() {
        if isEnabled { start() }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Key.enabled)
        enabled ? start() : stop()
    }

    func setPort(_ value: Int) {
        guard Self.isValidPort(value), value != Int(port) else { return }
        port = UInt16(value)
        defaults.set(value, forKey: Key.port)
        if isEnabled { start() }
    }

    /// Makes a new pairing code. Each paired browser must type the new code.
    func makeNewCode() {
        pairingCode = Self.makeCode()
        defaults.set(pairingCode, forKey: Key.code)
        throttle.reset()
    }

    func start() {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        status = .starting
        Self.configure(listener, queue: queue, onState: { [weak self] state in
            Task { @MainActor in self?.update(listener, to: state) }
        }, handler: { [weak self] request in
            await self?.respond(to: request) ?? .status(503)
        })
        self.listener = listener
        listener.start(queue: queue)
        print("[DEBUG] Web remote starts on port \(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        status = .stopped
    }

    private func update(_ source: NWListener, to state: NWListener.State) {
        // Ignore a late event from a listener that a restart replaced.
        guard source === listener else { return }
        switch state {
        case .ready:
            status = .running
        case .failed(let error):
            print("[DEBUG] Web remote failed: \(error)")
            status = .failed(error.localizedDescription)
            listener?.cancel()
            listener = nil
        default:
            break
        }
    }

    /// Gives the response to one request. The code check and the throttle are here.
    func respond(to request: HTTPRequest, now: Date = Date()) -> HTTPResponse {
        if request.path.hasPrefix("/api/"), throttle.isBlocked(at: now) {
            return .status(429)
        }
        switch WebRemoteRouter.decide(request, pairingCode: pairingCode) {
        case .reject(let status):
            if status == 401 { throttle.recordFailure(at: now) }
            return .status(status)
        case .command(let command):
            guard let commands = DeckCommands.shared else { return .status(503) }
            return Self.perform(command, with: commands)
        }
    }

    static func perform(_ command: WebRemoteCommand, with commands: DeckCommands) -> HTTPResponse {
        switch command {
        case .page:
            var response = HTTPResponse(status: 200, contentType: "text/html; charset=utf-8",
                                        body: Data(WebRemotePage.html.utf8))
            response.headers["Content-Security-Policy"] = WebRemotePage.contentSecurityPolicy
            return response
        case .pads:
            let library = commands.library
            let decks = library.decks.map { WebRemoteState.DeckEntry(id: $0.id, name: $0.name) }
            return .json(WebRemoteState(decks: decks, activeDeck: library.activeDeck.id,
                                        pads: commands.pads()))
        case .play(let pad):
            return .status(commands.play(pad) ? 200 : 404)
        case .release(let pad):
            return .status(commands.release(pad) ? 200 : 404)
        case .stop(let pad):
            return .status(commands.stop(pad) ? 200 : 404)
        case .deck(let deck):
            return .status(commands.selectDeck(deck) ? 200 : 404)
        }
    }

    // MARK: Connections

    // These functions run on the server queue. They do not touch the main actor state.

    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private nonisolated static func configure(_ listener: NWListener, queue: DispatchQueue,
                                              onState: @escaping @Sendable (NWListener.State) -> Void,
                                              handler: @escaping Handler) {
        listener.stateUpdateHandler = onState
        listener.newConnectionHandler = { connection in
            serve(connection, queue: queue, handler: handler)
        }
    }

    private nonisolated static func serve(_ connection: NWConnection, queue: DispatchQueue, handler: @escaping Handler) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + connectionTimeout) { connection.cancel() }
        receive(on: connection, buffer: Data(), handler: handler)
    }

    private nonisolated static func receive(on connection: NWConnection, buffer: Data, handler: @escaping Handler) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPParser.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    receive(on: connection, buffer: buffer, handler: handler)
                }
            case .failure(let status):
                send(.status(status), on: connection)
            case .request(let request):
                Task {
                    let response = await handler(request)
                    send(response, on: connection)
                }
            }
        }
    }

    private nonisolated static func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: Addresses

    /// The IPv4 addresses of the active network interfaces, without the loopback address.
    nonisolated static func localAddresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var addresses: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                                     socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            if result == 0 {
                let text = String(cString: host)
                if !addresses.contains(text) { addresses.append(text) }
            }
        }
        return addresses
    }
}
