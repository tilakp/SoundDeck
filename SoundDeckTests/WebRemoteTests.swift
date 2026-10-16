import Foundation
import Testing
@testable import SoundDeck

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SoundDeckTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func bytes(_ text: String) -> Data { Data(text.utf8) }

private func request(_ method: String, _ path: String, code: String? = nil, body: String = "") -> HTTPRequest {
    var headers: [String: String] = [:]
    if let code { headers["x-pairing-code"] = code }
    return HTTPRequest(method: method, path: path, headers: headers, body: bytes(body))
}

struct HTTPParserTests {
    @Test func parsesAGetRequest() throws {
        let result = HTTPParser.parse(bytes("GET /api/pads?x=1 HTTP/1.1\r\nHost: mac\r\nX-Pairing-Code: 123456\r\n\r\n"))
        guard case .request(let request) = result else { Issue.record("\(result)"); return }
        #expect(request.method == "GET")
        #expect(request.path == "/api/pads")
        #expect(request.header("X-PAIRING-CODE") == "123456")
        #expect(request.header("host") == "mac")
        #expect(request.body.isEmpty)
    }

    @Test func parsesAPostBody() {
        let text = "POST /api/play HTTP/1.1\r\nContent-Length: 12\r\n\r\n{\"pad\":\"a\"}\n"
        guard case .request(let request) = HTTPParser.parse(bytes(text)) else { Issue.record("no request"); return }
        #expect(request.body == bytes("{\"pad\":\"a\"}\n"))
    }

    @Test func waitsForMoreBytes() {
        #expect(HTTPParser.parse(Data()) == .incomplete)
        #expect(HTTPParser.parse(bytes("GET / HTTP/1.1\r\nHost: mac\r\n")) == .incomplete)
        #expect(HTTPParser.parse(bytes("POST /api/play HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"pad\"")) == .incomplete)
    }

    @Test func rejectsMalformedRequests() {
        let bad = [
            "GET /\r\n\r\n",
            "GET / HTTP/2.0\r\n\r\n",
            "GET  / HTTP/1.1\r\n\r\n",
            "get / HTTP/1.1\r\n\r\n",
            "GET index.html HTTP/1.1\r\n\r\n",
            "GET / HTTP/1.1\r\nNo colon here\r\n\r\n",
            "GET / HTTP/1.1\r\nBad name: x\r\n\r\n",
            "POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
            "POST / HTTP/1.1\r\nContent-Length: 1x\r\n\r\n",
            "POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab",
        ]
        for text in bad {
            #expect(HTTPParser.parse(bytes(text)) == .failure(status: 400), "\(text)")
        }
        var invalidUTF8 = bytes("GET /")
        invalidUTF8.append(0xFF)
        invalidUTF8.append(bytes(" HTTP/1.1\r\n\r\n"))
        #expect(HTTPParser.parse(invalidUTF8) == .failure(status: 400))
        #expect(HTTPParser.parse(bytes("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")) == .failure(status: 501))
    }

    @Test func limitsTheBody() {
        let limit = HTTPParser.maxBodyBytes
        let over = "POST /api/play HTTP/1.1\r\nContent-Length: \(limit + 1)\r\n\r\n"
        #expect(HTTPParser.parse(bytes(over)) == .failure(status: 413))
        let huge = "POST /api/play HTTP/1.1\r\nContent-Length: 99999999999999999999999\r\n\r\n"
        #expect(HTTPParser.parse(bytes(huge)) == .failure(status: 413))

        var exact = bytes("POST /api/play HTTP/1.1\r\nContent-Length: \(limit)\r\n\r\n")
        exact.append(Data(repeating: 0x20, count: limit))
        guard case .request(let request) = HTTPParser.parse(exact) else { Issue.record("no request"); return }
        #expect(request.body.count == limit)
    }

    @Test func limitsTheHeaders() {
        let long = "GET / HTTP/1.1\r\nX-Long: " + String(repeating: "a", count: HTTPParser.maxHeaderBytes)
        #expect(HTTPParser.parse(bytes(long)) == .failure(status: 431))
        #expect(HTTPParser.parse(bytes(long + "\r\n\r\n")) == .failure(status: 431))
    }

    @Test func serializesAResponse() throws {
        var response = HTTPResponse.status(404)
        response.headers["X-Test"] = "1"
        let text = try #require(String(data: response.serialized(), encoding: .utf8))
        #expect(text.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        #expect(text.contains("Content-Length: 21\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.contains("X-Test: 1\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{\"error\":\"Not Found\"}"))
    }
}

struct WebRemoteRouterTests {
    let code = "042917"

    @Test func servesThePageWithoutTheCode() {
        #expect(WebRemoteRouter.decide(request("GET", "/"), pairingCode: code) == .command(.page))
        #expect(WebRemoteRouter.decide(request("POST", "/"), pairingCode: code) == .reject(status: 405))
        #expect(WebRemoteRouter.decide(request("GET", "/index.html"), pairingCode: code) == .reject(status: 404))
        #expect(WebRemoteRouter.decide(request("GET", "/favicon.ico", code: code), pairingCode: code) == .reject(status: 404))
    }

    @Test func requiresTheCodeForTheAPI() {
        let paths = ["/api/pads", "/api/play", "/api/nothing"]
        for path in paths {
            #expect(WebRemoteRouter.decide(request("GET", path), pairingCode: code) == .reject(status: 401))
            #expect(WebRemoteRouter.decide(request("GET", path, code: "000000"), pairingCode: code) == .reject(status: 401))
            #expect(WebRemoteRouter.decide(request("GET", path, code: ""), pairingCode: code) == .reject(status: 401))
        }
        #expect(WebRemoteRouter.decide(request("GET", "/api/pads", code: code), pairingCode: code) == .command(.pads))
        #expect(WebRemoteRouter.decide(request("GET", "/api/nothing", code: code), pairingCode: code) == .reject(status: 404))
    }

    @Test func comparesCodes() {
        #expect(WebRemoteRouter.codesMatch("042917", "042917"))
        #expect(!WebRemoteRouter.codesMatch("042918", "042917"))
        #expect(!WebRemoteRouter.codesMatch("04291", "042917"))
        #expect(!WebRemoteRouter.codesMatch("0429170", "042917"))
        #expect(!WebRemoteRouter.codesMatch("", ""))
    }

    @Test func readsTheCommands() {
        func decide(_ method: String, _ path: String, _ body: String = "") -> WebRemoteRouter.Decision {
            WebRemoteRouter.decide(request(method, path, code: code, body: body), pairingCode: code)
        }
        #expect(decide("POST", "/api/play", #"{"pad":"Gong"}"#) == .command(.play("Gong")))
        #expect(decide("POST", "/api/release", #"{"pad":"Gong"}"#) == .command(.release("Gong")))
        #expect(decide("POST", "/api/stop", #"{"pad":"Gong"}"#) == .command(.stop("Gong")))
        #expect(decide("POST", "/api/stop", "{}") == .command(.stop(nil)))
        #expect(decide("POST", "/api/stop") == .command(.stop(nil)))
        #expect(decide("POST", "/api/deck", #"{"deck":"Show"}"#) == .command(.deck("Show")))

        #expect(decide("GET", "/api/play") == .reject(status: 405))
        #expect(decide("POST", "/api/pads") == .reject(status: 405))
        #expect(decide("POST", "/api/play") == .reject(status: 400))
        #expect(decide("POST", "/api/play", #"{"pad":""}"#) == .reject(status: 400))
        #expect(decide("POST", "/api/play", "not json") == .reject(status: 400))
        #expect(decide("POST", "/api/play", #"{"pad":5}"#) == .reject(status: 400))
        #expect(decide("POST", "/api/deck", "{}") == .reject(status: 400))
    }
}

struct FailureThrottleTests {
    @Test func blocksAfterTheLimitAndForgetsOldFailures() {
        var throttle = FailureThrottle(limit: 3, window: 60)
        func blocked(_ time: Date) -> Bool { throttle.isBlocked(at: time) }
        let start = Date(timeIntervalSince1970: 1000)
        for second in 0..<3 {
            #expect(!blocked(start + Double(second)))
            throttle.recordFailure(at: start + Double(second))
        }
        #expect(blocked(start + 10))
        #expect(!blocked(start + 61))
        throttle.recordFailure(at: start + 61)
        throttle.recordFailure(at: start + 61)
        throttle.recordFailure(at: start + 61)
        #expect(blocked(start + 62))
        throttle.reset()
        #expect(!blocked(start + 62))
    }
}

@MainActor
struct WebRemoteServerTests {
    private func makeDefaults() -> UserDefaults {
        let name = "SoundDeckTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func keepsTheSettings() {
        let defaults = makeDefaults()
        let server = WebRemoteServer(defaults: defaults)
        #expect(!server.isEnabled)
        #expect(server.port == 8787)
        #expect(server.pairingCode.count == 6 && server.pairingCode.allSatisfy(\.isNumber))

        server.setPort(9000)
        server.setPort(80)
        let first = server.pairingCode
        var codes: Set<String> = [first]
        for _ in 0..<5 {
            server.makeNewCode()
            codes.insert(server.pairingCode)
        }
        #expect(codes.count > 1)

        let reloaded = WebRemoteServer(defaults: defaults)
        #expect(reloaded.port == 9000)
        #expect(reloaded.pairingCode == server.pairingCode)
    }

    @Test func blocksTheAPIAfterIncorrectCodes() {
        let server = WebRemoteServer(defaults: makeDefaults())
        let now = Date()
        for _ in 0..<10 {
            #expect(server.respond(to: request("GET", "/api/pads", code: "x"), now: now).status == 401)
        }
        let good = request("GET", "/api/pads", code: server.pairingCode)
        #expect(server.respond(to: good, now: now).status == 429)
        // The page stays available, so that a user can see the message.
        #expect(server.respond(to: request("GET", "/"), now: now).status == 200)
        server.makeNewCode()
        let fresh = request("GET", "/api/pads", code: server.pairingCode)
        #expect(server.respond(to: fresh, now: now).status == 200)
    }

    @Test func performsTheCommands() throws {
        let library = SoundLibrary(store: SoundLibraryStore(directoryURL: try temporaryDirectory()))
        let commands = DeckCommands(library: library, engine: AudioEngine())

        let pads = WebRemoteServer.perform(.pads, with: commands)
        #expect(pads.status == 200)
        let state = try JSONDecoder().decode(WebRemoteState.self, from: pads.body)
        #expect(state.activeDeck == library.activeDeck.id)
        #expect(state.decks.map(\.name) == library.decks.map(\.name))
        #expect(state.pads.count == library.sounds.count)

        #expect(WebRemoteServer.perform(.play("no such pad"), with: commands).status == 404)
        #expect(WebRemoteServer.perform(.deck("no such deck"), with: commands).status == 404)
        #expect(WebRemoteServer.perform(.stop(nil), with: commands).status == 200)

        library.addDeck(named: "Show")
        let main = try #require(library.decks.first)
        #expect(WebRemoteServer.perform(.deck(main.id.uuidString), with: commands).status == 200)
        #expect(library.activeDeck.id == main.id)

        let page = WebRemoteServer.perform(.page, with: commands)
        #expect(page.contentType.hasPrefix("text/html"))
        #expect(page.headers["Content-Security-Policy"] != nil)
        #expect(page.body.count < 30 * 1024)
    }

    @Test func servesOverTCP() async throws {
        let server = WebRemoteServer(defaults: makeDefaults())
        let port = Int.random(in: 40000...49000)
        server.setPort(port)
        server.setEnabled(true)
        defer { server.setEnabled(false) }
        for _ in 0..<50 where server.status != .running {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(server.status == .running)

        let url = try #require(URL(string: "http://127.0.0.1:\(port)/api/pads"))
        var call = URLRequest(url: url)
        let (_, denied) = try await URLSession.shared.data(for: call)
        #expect((denied as? HTTPURLResponse)?.statusCode == 401)

        call.setValue(server.pairingCode, forHTTPHeaderField: WebRemoteRouter.codeHeader)
        let (body, allowed) = try await URLSession.shared.data(for: call)
        #expect((allowed as? HTTPURLResponse)?.statusCode == 200)
        #expect((try? JSONDecoder().decode(WebRemoteState.self, from: body)) != nil)
    }
}
