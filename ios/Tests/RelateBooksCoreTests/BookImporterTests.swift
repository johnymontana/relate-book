import Testing
import Foundation
import Relate
@testable import RelateBooksCore

@Suite("Book importer")
struct BookImporterTests {
    static func seedJunger(_ store: GraphStore) async throws {
        try await store.query("CREATE (:Author {key: '/authors/OL389527A', name: 'Sebastian Junger', bio: 'old bio'})")
    }

    static func paths(_ transport: StubOpenLibraryTransport) async -> [String] {
        await transport.requestedURLs.map(FakeTransport.key)
    }

    @Test("ISBN on an empty store: search, work, both authors (4 requests)")
    func emptyStore() async throws {
        let store = try await GraphStore.inMemory()
        let transport = StubOpenLibraryTransport(latency: .zero)
        let importer = BookImporter(client: OpenLibraryClient(transport: transport, minimumInterval: .zero), store: store)
        guard case .draft(let draft) = try await importer.resolve(isbn: PerfectStorm.isbn) else {
            Issue.record("expected a draft"); return
        }
        #expect(draft.key == PerfectStorm.key && draft.match == .isbn)
        #expect(await Self.paths(transport) == ["/search.json?q=isbn:9780393337013", "/works/OL2670211W.json",
                                                 "/authors/OL389527A.json", "/authors/OL2801780A.json"])
        #expect(!draft.authors[0].properties.isEmpty)
        #expect(draft == (try PerfectStorm.draft()))
    }

    @Test("an author already in the store is not fetched and gets no properties (3 requests)")
    func knownAuthor() async throws {
        let store = try await GraphStore.inMemory()
        try await Self.seedJunger(store)
        let transport = StubOpenLibraryTransport(latency: .zero)
        let importer = BookImporter(client: OpenLibraryClient(transport: transport, minimumInterval: .zero), store: store)
        guard case .draft(let draft) = try await importer.resolve(isbn: PerfectStorm.isbn) else {
            Issue.record("expected a draft"); return
        }
        #expect(await transport.requestedURLs.count == 3)
        #expect(draft.authors[0].key == PerfectStorm.junger && draft.authors[0].properties.isEmpty)
        #expect(draft.authors[1].properties["name"] == .string("Anne Collins"))
    }

    @Test("a doc whose work is already a Book: already in library after 1 request")
    func alreadyByWorkKey() async throws {
        let store = try await GraphStore.inMemory()
        try await store.query("CREATE (:Book {key: '/works/OL21745884W', title: 'Project Hail Mary'})")
        let transport = FakeTransport(["/search.json?q=isbn:9780593135211": [.fixture("search-isbn-phm.json")]])
        let importer = BookImporter(client: OpenLibraryClient(transport: transport, minimumInterval: .zero), store: store)
        #expect(try await importer.resolve(isbn: ISBN("9780593135211")!) == .alreadyInLibrary(key: "/works/OL21745884W"))
        #expect(await transport.requestCount == 1)
        #expect(try await importer.resolve(workKey: "/works/OL21745884W") == .alreadyInLibrary(key: "/works/OL21745884W"))
        #expect(await transport.requestCount == 1)
    }

    @Test("fallback chain: isbn13 → isbn10 → /isbn/ → key search → work → authors")
    func fallbackChain() async throws {
        let store = try await GraphStore.inMemory()
        var routes = FakeTransport.perfectStormRoutes()
        routes["/search.json?q=isbn:9780393337013"] = [.fixture("search-notfound.json")]
        routes["/search.json?q=isbn:0393337014"] = [.fixture("search-notfound.json")]
        routes["/isbn/9780393337013.json"] = [.fixture("edition-OL24495814M.json")]
        let transport = FakeTransport(routes)
        let importer = BookImporter(client: OpenLibraryClient(transport: transport, minimumInterval: .zero), store: store)
        guard case .draft(let draft) = try await importer.resolve(isbn: PerfectStorm.isbn) else {
            Issue.record("expected a draft"); return
        }
        #expect(draft.properties["pages"] == .int(233))
        #expect(await transport.paths == ["/search.json?q=isbn:9780393337013", "/search.json?q=isbn:0393337014",
                                          "/isbn/9780393337013.json", "/search.json?q=key:\"/works/OL2670211W\"",
                                          "/works/OL2670211W.json", "/authors/OL389527A.json", "/authors/OL2801780A.json"])
    }

    @Test("nothing anywhere → notFound with the ISBN-13")
    func notFound() async throws {
        let store = try await GraphStore.inMemory()
        let transport = StubOpenLibraryTransport(latency: .zero)
        let importer = BookImporter(client: OpenLibraryClient(transport: transport, minimumInterval: .zero), store: store)
        await #expect(throws: ImportError.notFound("9798999999993")) { try await importer.resolve(isbn: ISBN("9798999999993")!) }
        #expect(await Self.paths(transport) == ["/search.json?q=isbn:9798999999993", "/isbn/9798999999993.json"])
        #expect(ImportError.notFound("9798999999993").errorDescription
                == "No Open Library record for ISBN 9798999999993. Check the number, or add the book manually.")
        await #expect(throws: ImportError.notFound("/works/OL1W")) { try await importer.resolve(workKey: "/works/OL1W") }
    }

    @Test("local ISBN match uses Item isbn13/isbn10 and Book isbn13, with no request")
    func localMatch() async throws {
        let store = try await GraphStore.inMemory()
        try await store.query("""
            CREATE (b:Book {key: '/works/OL21745884W', title: 'Project Hail Mary'})
            CREATE (i:Item {asin: 'PHM1', isbn13: '9780593135204', isbn10: '0593135202'})-[:EDITION_OF]->(b)
            CREATE (:Book {key: '/works/OL2670211W', title: 'The Perfect Storm', isbn13: '9780393337013'})
            """)
        let transport = StubOpenLibraryTransport(latency: .zero)
        let importer = BookImporter(client: OpenLibraryClient(transport: transport, minimumInterval: .zero), store: store)
        #expect(try await importer.localMatch(isbn: ISBN("9780593135204")!) == "/works/OL21745884W")
        #expect(try await importer.localMatch(isbn: ISBN("0593135202")!) == "/works/OL21745884W")
        #expect(try await importer.localMatch(isbn: PerfectStorm.isbn) == PerfectStorm.key)
        #expect(try await importer.localBook(isbn: PerfectStorm.isbn)?.title == "The Perfect Storm")
        #expect(try await importer.localMatch(isbn: ISBN("9798999999993")!) == nil)
        #expect(try await importer.localKeys(["/works/OL21745884W", "/works/OL9W"]) == ["/works/OL21745884W"])
        #expect(try await importer.localKeys([]).isEmpty)
        #expect(await transport.requestedURLs.isEmpty)
    }

    @Test("a network error during lookup fails before anything is written")
    func offlineWork() async throws {
        let store = try await GraphStore.inMemory()
        var routes = FakeTransport.perfectStormRoutes()
        routes["/works/OL2670211W.json"] = [.failure(.notConnectedToInternet)]
        let importer = BookImporter(client: OpenLibraryClient(transport: FakeTransport(routes), minimumInterval: .zero), store: store)
        await #expect(throws: ImportError.network(.offline)) { try await importer.resolve(isbn: PerfectStorm.isbn) }
        #expect(try await store.bookCount() == 0)
    }
}
