import Foundation
import Testing
@testable import SoundDeck

struct FreesoundQueryTests {
    private func parameters(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test func urlHasTheSearchParameters() {
        let url = FreesoundQuery(text: "  dog bark ").url
        #expect(url.absoluteString.hasPrefix("https://freesound.org/apiv2/search/?"))
        let values = parameters(url)
        #expect(values["query"] == "dog bark")
        #expect(values["sort"] == "score")
        #expect(values["fields"] == "id,name,username,license,duration,previews,tags")
        #expect(values["page_size"] == "30")
        #expect(values["token"] == nil)
    }

    @Test func reservedCharactersAreEncoded() {
        let url = FreesoundQuery(text: "a+b & c=d #1").url
        #expect(url.absoluteString.contains("query=a%2Bb%20%26%20c%3Dd%20%231"))
        #expect(parameters(url)["query"] == "a+b & c=d #1")
    }

    @Test func defaultFilterExcludesNonCommercialAndLongSounds() {
        let query = FreesoundQuery(text: "x")
        #expect(query.filter == #"license:("Attribution" OR "Creative Commons 0") duration:[0 TO 10]"#)
        #expect(parameters(query.url)["filter"] == query.filter)
    }

    @Test func licenseFilters() {
        var query = FreesoundQuery(text: "x", duration: .any)
        query.license = .cc0
        #expect(query.filter == #"license:"Creative Commons 0""#)
        query.license = .any
        #expect(query.filter == #"license:("Attribution" OR "Creative Commons 0")"#)
        query.includesNonCommercial = true
        #expect(query.filter == nil)
        #expect(parameters(query.url)["filter"] == nil)
    }

    @Test func nonCommercialToggleAppliesOnlyToAny() {
        var query = FreesoundQuery(text: "x", license: .cc0, includesNonCommercial: true, duration: .under30)
        #expect(query.filter == #"license:"Creative Commons 0" duration:[0 TO 30]"#)
        #expect(query.allows(.nonCommercial(version: "4.0")) == false)
        query.license = .any
        #expect(query.allows(.nonCommercial(version: "4.0")))
    }

    @Test func resultCheckMatchesTheFilter() {
        let query = FreesoundQuery(text: "x", license: .cc0)
        #expect(query.allows(.cc0))
        #expect(query.allows(.attribution(version: "4.0")) == false)
        let open = FreesoundQuery(text: "x")
        #expect(open.allows(.attribution(version: nil)))
        #expect(open.allows(.nonCommercial(version: nil)) == false)
        #expect(open.allows(.other) == false)
    }
}

struct FreesoundLicenseTests {
    @Test func urlsClassify() {
        #expect(FreesoundLicense("http://creativecommons.org/publicdomain/zero/1.0/") == .cc0)
        #expect(FreesoundLicense("https://creativecommons.org/licenses/by/4.0/") == .attribution(version: "4.0"))
        #expect(FreesoundLicense("http://creativecommons.org/licenses/by/3.0/") == .attribution(version: "3.0"))
        #expect(FreesoundLicense("https://creativecommons.org/licenses/by-nc/4.0/") == .nonCommercial(version: "4.0"))
        #expect(FreesoundLicense("http://creativecommons.org/licenses/sampling+/1.0/") == .other)
    }

    @Test func namesClassify() {
        #expect(FreesoundLicense("Creative Commons 0") == .cc0)
        #expect(FreesoundLicense("Attribution") == .attribution(version: nil))
        #expect(FreesoundLicense("Attribution NonCommercial") == .nonCommercial(version: nil))
        #expect(FreesoundLicense("Something else") == .other)
    }

    @Test func labels() {
        #expect(FreesoundLicense.cc0.label == "CC0")
        #expect(FreesoundLicense.attribution(version: "4.0").label == "CC BY 4.0")
        #expect(FreesoundLicense.attribution(version: nil).label == "CC BY")
        #expect(FreesoundLicense.nonCommercial(version: "3.0").label == "CC BY-NC 3.0")
        #expect(FreesoundLicense.cc0.requiresCredit == false)
        #expect(FreesoundLicense.attribution(version: nil).requiresCredit)
    }
}

struct FreesoundDecodingTests {
    static let fixture = """
    {
      "count": 2,
      "previous": null,
      "next": "https://freesound.org/apiv2/search/?query=gong&page=2&page_size=30",
      "results": [
        {
          "id": 1234,
          "name": "Gong.wav",
          "username": "ann",
          "license": "https://creativecommons.org/licenses/by/4.0/",
          "duration": 3.52,
          "tags": ["gong", "metal"],
          "previews": {
            "preview-hq-mp3": "https://cdn.freesound.org/previews/1/1234_5-hq.mp3",
            "preview-lq-mp3": "https://cdn.freesound.org/previews/1/1234_5-lq.mp3",
            "preview-hq-ogg": "https://cdn.freesound.org/previews/1/1234_5-hq.ogg",
            "preview-lq-ogg": "https://cdn.freesound.org/previews/1/1234_5-lq.ogg"
          }
        },
        {
          "id": 99,
          "name": "Click",
          "username": "bo",
          "license": "http://creativecommons.org/publicdomain/zero/1.0/",
          "duration": 0.1,
          "previews": {}
        }
      ]
    }
    """

    @Test func decodesAPage() throws {
        let page = try JSONDecoder().decode(FreesoundPage.self, from: Data(Self.fixture.utf8))
        #expect(page.count == 2)
        #expect(page.next?.absoluteString.contains("page=2") == true)
        #expect(page.results.count == 2)
        let gong = page.results[0]
        #expect(gong.id == 1234)
        #expect(gong.username == "ann")
        #expect(gong.duration == 3.52)
        #expect(gong.tags == ["gong", "metal"])
        #expect(gong.previewURL?.absoluteString == "https://cdn.freesound.org/previews/1/1234_5-hq.mp3")
        #expect(gong.licenseKind == .attribution(version: "4.0"))
        let click = page.results[1]
        #expect(click.tags == nil)
        #expect(click.previewURL == nil)
        #expect(click.licenseKind == .cc0)
    }

    @Test func lastPageHasNoNext() throws {
        let json = #"{"count": 0, "next": null, "previous": null, "results": []}"#
        let page = try JSONDecoder().decode(FreesoundPage.self, from: Data(json.utf8))
        #expect(page.next == nil)
        #expect(page.results.isEmpty)
    }
}

struct FreesoundCreditTests {
    private func sound(license: String) -> FreesoundSound {
        FreesoundSound(id: 1234, name: "Gong.wav", username: "ann", license: license, duration: 1, previews: [:], tags: nil)
    }

    @Test func creditText() {
        let credit = FreesoundCredit.text(for: sound(license: "https://creativecommons.org/licenses/by/4.0/"))
        #expect(credit == "Gong.wav by ann, CC BY 4.0, freesound.org/s/1234")
        let cc0 = FreesoundCredit.text(for: sound(license: "Creative Commons 0"))
        #expect(cc0 == "Gong.wav by ann, CC0, freesound.org/s/1234")
    }

    @Test func deckCreditsListOnlyPadsWithACredit() {
        var a = SoundItem(copiedFileName: "a.mp3")
        a.credit = "A by x, CC BY 4.0, freesound.org/s/1"
        let b = SoundItem(copiedFileName: "b.wav")
        var c = SoundItem(copiedFileName: "c.mp3")
        c.credit = "C by y, CC0, freesound.org/s/3"
        #expect(FreesoundCredit.deckCredits([a, b, c]) == "A by x, CC BY 4.0, freesound.org/s/1\nC by y, CC0, freesound.org/s/3")
        #expect(FreesoundCredit.deckCredits([b]).isEmpty)
    }

    @Test func creditSurvivesEncodingAndOldFilesHaveNone() throws {
        var item = SoundItem(copiedFileName: "a.mp3")
        item.credit = "A by x, CC BY 4.0, freesound.org/s/1"
        let copy = try JSONDecoder().decode(SoundItem.self, from: try JSONEncoder().encode(item))
        #expect(copy.credit == item.credit)

        let old = #"{"id": "\#(UUID().uuidString)", "name": "Old", "isBundled": false}"#
        let decoded = try JSONDecoder().decode(SoundItem.self, from: Data(old.utf8))
        #expect(decoded.credit == nil)
    }

    @Test func archiveEntryCarriesTheCredit() throws {
        let entry = DeckArchive.Entry(
            name: "A", fileName: "a.mp3", volume: 1, loops: false, trimStart: 0, trimEnd: nil,
            tint: .none, emoji: nil, hotKey: nil, credit: "A by x, CC0, freesound.org/s/1", audio: Data("x".utf8)
        )
        let copy = try JSONDecoder().decode(DeckArchive.Entry.self, from: try JSONEncoder().encode(entry))
        #expect(copy.credit == entry.credit)
    }
}

struct FreesoundDurationFormatTests {
    @Test func formats() {
        #expect(FreesoundSheet.format(3.52) == "3.5 s")
        #expect(FreesoundSheet.format(0) == "0.0 s")
        #expect(FreesoundSheet.format(65.2) == "1:05.2")
    }
}
