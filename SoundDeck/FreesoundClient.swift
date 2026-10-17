import Foundation
import Security

// MARK: - Model

/// One sound in a search result of the Freesound APIv2.
struct FreesoundSound: Decodable, Identifiable, Equatable {
    let id: Int
    let name: String
    let username: String
    /// A Creative Commons URL, for example `http://creativecommons.org/licenses/by/4.0/`.
    /// Older documentation gives a name, for example "Attribution". Both forms classify.
    let license: String
    /// Seconds.
    let duration: Double
    let previews: [String: String]
    let tags: [String]?

    /// The only preview that token authentication can download: 128 kbps MP3.
    var previewURL: URL? { previews["preview-hq-mp3"].flatMap(URL.init(string:)) }

    var licenseKind: FreesoundLicense { FreesoundLicense(license) }

    var pageURL: String { "freesound.org/s/\(id)" }
}

/// One page of search results.
struct FreesoundPage: Decodable, Equatable {
    let count: Int
    let next: URL?
    let results: [FreesoundSound]
}

// MARK: - License

enum FreesoundLicense: Equatable {
    case cc0
    /// `version` is nil when the license value has no version, for example "Attribution".
    case attribution(version: String?)
    case nonCommercial(version: String?)
    /// Sampling+ and all values that Sound Deck does not know.
    case other

    init(_ value: String) {
        let text = value.lowercased()
        if text.contains("publicdomain/zero") || text == "creative commons 0" || text == "cc0" {
            self = .cc0
        } else if text.contains("/by-nc") || text.hasPrefix("attribution noncommercial") {
            self = .nonCommercial(version: Self.version(in: text))
        } else if text.contains("/licenses/by/") || text.hasPrefix("attribution") {
            self = .attribution(version: Self.version(in: text))
        } else {
            self = .other
        }
    }

    /// The first path part that is a version number, for example "4.0".
    private static func version(in text: String) -> String? {
        text.split(separator: "/").first { part in
            part.contains(".") && part.allSatisfy { $0.isNumber || $0 == "." }
        }.map(String.init)
    }

    /// The short name on the badge and in the credit, for example "CC BY 4.0".
    var label: String {
        switch self {
        case .cc0: return "CC0"
        case .attribution(let version): return ["CC BY", version].compactMap { $0 }.joined(separator: " ")
        case .nonCommercial(let version): return ["CC BY-NC", version].compactMap { $0 }.joined(separator: " ")
        case .other: return "Other"
        }
    }

    /// True when the license tells the user to give credit.
    var requiresCredit: Bool {
        switch self {
        case .cc0: return false
        default: return true
        }
    }
}

// MARK: - Query

struct FreesoundQuery: Equatable {
    enum LicenseFilter: String, CaseIterable, Identifiable {
        case any, attributionOrCC0, cc0

        var id: String { rawValue }

        var label: String {
            switch self {
            case .any: return "Any"
            case .attributionOrCC0: return "CC BY or CC0"
            case .cc0: return "CC0 only"
            }
        }
    }

    enum DurationFilter: Double, CaseIterable, Identifiable {
        case under10 = 10
        case under30 = 30
        case any = 0

        var id: Double { rawValue }

        var label: String {
            switch self {
            case .under10: return "Under 10 s"
            case .under30: return "Under 30 s"
            case .any: return "Any length"
            }
        }
    }

    static let base = URL(string: "https://freesound.org/apiv2/search/")!
    static let fields = "id,name,username,license,duration,previews,tags"
    static let pageSize = 30

    var text: String
    var license: LicenseFilter = .attributionOrCC0
    /// Applies only to `.any`. The other license filters never include NonCommercial.
    var includesNonCommercial = false
    var duration: DurationFilter = .under10

    /// The value of the `filter` parameter in Solr syntax. Nil when there is no filter.
    var filter: String? {
        var parts: [String] = []
        switch license {
        case .any:
            // Without NonCommercial, "Any" keeps the licenses that allow all uses.
            if !includesNonCommercial { parts.append(#"license:("Attribution" OR "Creative Commons 0")"#) }
        case .attributionOrCC0:
            parts.append(#"license:("Attribution" OR "Creative Commons 0")"#)
        case .cc0:
            parts.append(#"license:"Creative Commons 0""#)
        }
        if duration != .any {
            parts.append("duration:[0 TO \(Int(duration.rawValue))]")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The URL of the first page, sorted by relevance. The API key goes in a header, not in the URL.
    var url: URL {
        var items: [(String, String)] = [
            ("query", text.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("sort", "score"),
            ("fields", Self.fields),
            ("page_size", String(Self.pageSize)),
        ]
        if let filter { items.append(("filter", filter)) }
        var components = URLComponents(url: Self.base, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = items
            .map { "\($0.0)=\(Self.encode($0.1))" }
            .joined(separator: "&")
        return components.url!
    }

    /// Percent-encodes a query value. `URLComponents` keeps "+" as it is, and the server reads it as a space.
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: - Credit

enum FreesoundCredit {
    /// For example "Gong.wav by ann, CC BY 4.0, freesound.org/s/1234".
    static func text(for sound: FreesoundSound) -> String {
        "\(sound.name) by \(sound.username), \(sound.licenseKind.label), \(sound.pageURL)"
    }

    /// One line for each pad that has a credit, in the order of the deck.
    static func deckCredits(_ sounds: [SoundItem]) -> String {
        sounds.compactMap(\.credit).joined(separator: "\n")
    }
}

// MARK: - Key

/// Keeps the Freesound API key in the login keychain. The key is a secret, so it is not in `UserDefaults`.
final class FreesoundKey: ObservableObject {
    static let shared = FreesoundKey()

    private static let service = "com.patelt.SoundDeck.freesound"
    private static let account = "api-key"

    @Published private(set) var value: String?

    private init() { value = Self.read() }

    /// An empty key deletes the item.
    func set(_ newValue: String) {
        let key = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.delete()
        if !key.isEmpty { Self.write(key) }
        value = Self.read()
    }

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound { print("[DEBUG] Freesound key read failed: \(status)") }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ key: String) {
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { print("[DEBUG] Freesound key write failed: \(status)") }
    }

    private static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Client

enum FreesoundError: LocalizedError {
    case invalidKey
    case throttled
    case http(Int)
    case noPreview

    var errorDescription: String? {
        switch self {
        case .invalidKey: return "Freesound does not accept the API key. Check the key in Settings > Freesound."
        case .throttled: return "Freesound received too many requests. Wait a minute, then try again."
        case .http(let code): return "Freesound sent the error \(code)."
        case .noPreview: return "This sound has no MP3 preview."
        }
    }
}

/// Searches Freesound and downloads previews. It uses token authentication.
/// Token authentication cannot download the original files, so a pad gets the 128 kbps MP3 preview.
enum FreesoundClient {
    static func search(_ query: FreesoundQuery, key: String) async throws -> FreesoundPage {
        try await page(at: query.url, key: key)
    }

    /// Loads a page from the `next` URL of an earlier page.
    static func page(at url: URL, key: String) async throws -> FreesoundPage {
        var request = URLRequest(url: url)
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response)
        return try JSONDecoder().decode(FreesoundPage.self, from: data)
    }

    /// Downloads the preview to the temporary directory and returns the file.
    static func downloadPreview(of sound: FreesoundSound) async throws -> URL {
        guard let url = sound.previewURL else { throw FreesoundError.noPreview }
        let (temporary, response) = try await URLSession.shared.download(from: url)
        try check(response)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("freesound-\(sound.id).mp3")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw FreesoundError.invalidKey
        case 429: throw FreesoundError.throttled
        default: throw FreesoundError.http(http.statusCode)
        }
    }
}
