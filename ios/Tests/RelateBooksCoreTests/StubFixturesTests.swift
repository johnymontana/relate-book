import Testing
import Foundation
@testable import RelateBooksCore

@Suite("Stub fixtures")
struct StubFixturesTests {
    @Test("every embedded fixture equals its recorded file as JSON")
    func fixturesMatchFiles() throws {
        #expect(StubOpenLibraryFixtures.all.count == 9)
        for (name, text) in StubOpenLibraryFixtures.all {
            #expect(try JSONValue.parse(Data(text.utf8)) == FixtureFiles.openLibraryJSON(name), "\(name)")
        }
    }

    @Test("routes")
    func routes() {
        func name(_ url: String) -> String? { StubOpenLibraryTransport.fixtureName(for: URL(string: url)!) }
        let search = { (q: String) in OpenLibraryClient.searchURL(q: q, fields: OpenLibraryClient.docFields, limit: 1).absoluteString }
        #expect(name(search("isbn:9780393337013")) == "search-isbn13.json")
        #expect(name(search("isbn:0393337014")) == "search-isbn10.json")
        #expect(name(search("key:\"/works/OL2670211W\"")) == "search-key.json")
        #expect(name(OpenLibraryClient.searchURL(q: "The Perfect Storm", fields: OpenLibraryClient.listFields, limit: 20).absoluteString)
                == "search-title.json")
        #expect(name(search("isbn:9798999999993")) == "search-notfound.json")
        #expect(name("https://openlibrary.org/works/OL2670211W.json") == "work-OL2670211W.json")
        #expect(name("https://openlibrary.org/authors/OL389527A.json") == "author-OL389527A.json")
        #expect(name("https://openlibrary.org/authors/OL2801780A.json") == "author-OL2801780A.json")
        #expect(name("https://openlibrary.org/isbn/9780393337013.json") == "edition-OL24495814M.json")
        #expect(name("https://openlibrary.org/isbn/0393337014.json") == "edition-OL24495814M.json")
        #expect(name("https://openlibrary.org/works/OL1W.json") == nil)
        #expect(name("https://openlibrary.org/isbn/9798999999993.json") == nil)
    }

    @Test("the stub transport answers 404 for unknown records and records URLs")
    func transport() async throws {
        let stub = StubOpenLibraryTransport(latency: .zero)
        let (_, missing) = try await stub.data(for: URLRequest(url: URL(string: "https://openlibrary.org/works/OL1W.json")!))
        #expect(missing.statusCode == 404)
        let (body, ok) = try await stub.data(for: URLRequest(url: URL(string: "https://openlibrary.org/works/OL2670211W.json")!))
        let work = OLWork(json: try JSONValue.parse(body))
        #expect(ok.statusCode == 200 && work.title == "The Perfect Storm")
        #expect(await stub.requestedURLs.count == 2)
    }

    @Test("the stub geocoder covers exactly the fixture's new places")
    func geocoderTable() throws {
        let doc = try PerfectStorm.doc()
        let newPlaces = doc.places.filter { $0 != "New England" }
        let queries = Set(newPlaces.compactMap { HeadingNormalizer.normalize($0).query })
        #expect(Set(StubPlaceGeocoder.fixtureTable.keys) == queries)
        #expect(StubPlaceGeocoder().sourceName == "stub")
    }
}
