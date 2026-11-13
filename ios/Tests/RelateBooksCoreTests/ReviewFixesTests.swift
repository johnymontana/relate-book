import Testing
import Foundation
@testable import RelateBooksCore

/// Regression tests for the phase 1 review round: duplicate Author nodes,
/// the format filter's shown item, http image URLs, author sort suffixes,
/// mixed-source lifespans, and the search debounce.
@Suite("Phase 1 review fixes")
struct ReviewFixesTests {
    /// Adds two more "Jane Appleseed" Author nodes to Apple Orchards: one
    /// bare, one with a birth date only (the real store has three
    /// "David Allen" nodes on Getting Things Done).
    static func addDuplicateAuthors(to store: GraphStore) async throws {
        try await store.query("""
            MATCH (b:Book {key: '/works/OL1W'})
            CREATE (d1:Author {key: '/authors/OL0A', name: 'Jane Appleseed'})
            CREATE (d2:Author {key: '/authors/OL9A', name: 'jane appleseed', birth_date: '1950'})
            CREATE (b)-[:WRITTEN_BY {role: 'Author'}]->(d1), (b)-[:WRITTEN_BY]->(d2)
            """)
    }

    @Test("same-name Author nodes: one name in the list row, the richest node in detail")
    func duplicateAuthors() async throws {
        let store = try await LibraryFixture.store()
        try await Self.addDuplicateAuthors(to: store)
        let row = try #require(try await store.libraryPage(sort: .title).first { $0.key == "/works/OL1W" })
        // Exact duplicates collapse in Cypher; the case-variant node stays a distinct name there.
        #expect(row.authors.filter { $0 == "Jane Appleseed" }.count == 1)
        let book = try #require(try await store.bookDetail(key: "/works/OL1W"))
        // OL1A has a photo, bio and birth date, so it stands for all three nodes.
        #expect(book.authors == [AuthorRef(key: "/authors/OL1A", name: "Jane Appleseed", role: "Author")])
    }

    @Test("deduplicated: richness wins, then the smaller key; other names are kept")
    func dedupeRule() {
        let rows = [
            Row(["key": .string("/a/2"), "name": .string("Ann Lee"), "richness": .int(1)]),
            Row(["key": .string("/a/3"), "name": .string("Ann Lee"), "richness": .int(1)]),
            Row(["key": .string("/a/1"), "name": .string("Bo Ek"), "richness": .int(0)]),
            Row(["key": .string("/a/9"), "name": .string("ANN LEE"), "richness": .int(0)]),
        ]
        #expect(AuthorRef.deduplicated(rows).map(\.key) == ["/a/2", "/a/1"])
    }

    @Test("format filter: the row shows an item in that format, with its price")
    func formatFilterShowsMatchingItem() async throws {
        let store = try await LibraryFixture.store()
        // Apple Orchards: position 1 Hardcover $25, position 3 Paperback $10.
        let paperback = try #require(try await store.libraryPage(filter: LibraryFilter(format: "Paperback"))
            .first { $0.key == "/works/OL1W" })
        #expect(paperback.format == "Paperback")
        #expect(paperback.price == 10.0)
        #expect(paperback.itemTitle == "Apple Orchards (Paperback)")
        #expect(paperback.itemCount == 2)                 // still counts every item
        #expect(paperback.wishlistPosition == 1)          // and the book's best position
        for sort in LibrarySort.allCases {
            let rows = try await store.libraryPage(filter: LibraryFilter(format: "Paperback"), sort: sort)
            #expect(rows.allSatisfy { $0.format == "Paperback" })
        }
        // Without the filter the position-1 item still wins.
        #expect(try await store.libraryPage().first { $0.key == "/works/OL1W" }?.format == "Hardcover")
    }

    @Test("image URLs: http is upgraded to https; Wikimedia originals get a width")
    func secureImageURLs() async throws {
        let wiki = "http://commons.wikimedia.org/wiki/Special:FilePath/TNW%20Con%20EU15-David%20Allen%20-%204.jpg"
        #expect(ImageURLs.secure(URL(string: wiki)!).absoluteString
                == "https://commons.wikimedia.org/wiki/Special:FilePath/TNW%20Con%20EU15-David%20Allen%20-%204.jpg?width=400")
        let cover = "https://covers.openlibrary.org/b/id/1-L.jpg"
        #expect(ImageURLs.secure(URL(string: cover)!).absoluteString == cover)
        #expect(ImageURLs.secure(URL(string: "http://m.media-amazon.com/x.jpg")!).absoluteString == "https://m.media-amazon.com/x.jpg")

        let store = try await LibraryFixture.store()
        try await store.query("MATCH (a:Author {key: '/authors/OL2A'}) SET a.image_url = $u", ["u": .string(wiki)])
        let zed = try #require(try await store.authorDetail(key: "/authors/OL2A"))
        #expect(zed.imageURLs.count == 1)
        #expect(zed.imageURLs.allSatisfy { $0.scheme == "https" })
    }

    @Test("author sort skips name suffixes such as Jr., III and PhD")
    func surnameSuffixes() async throws {
        let store = try await GraphStore.inMemory()
        let cases: [(String, String)] = [
            ("Frederick P. Brooks Jr.", "brooks"), ("William H. Draper III", "draper"),
            ("Nicholas A. Christakis MD  PhD", "christakis"), ("Smith, Greg", "smith"),
            ("Martin Luther King, Jr.", "king"), ("Santiago Foz (argentino)", "foz"), ("Plato", "plato"),
            ("Ray Bradbury", "bradbury"), ("Jane Baker", "baker"), ("Ursula K. Le Guin", "guin"), ("Henry VIII", "viii"),
        ]
        for (name, expected) in cases {
            let result = try await store.query("RETURN \(LibraryQueries.surname("$n")) AS s", ["n": .string(name)])
            #expect(try result.scalar().stringValue == expected, "\(name)")
        }
    }

    @Test("lifespan: one source per pair; ISO dates read like Open Library dates")
    func lifespan() async throws {
        #expect(AuthorDetail.displayDate("1942-02-12") == "12 February 1942")
        #expect(AuthorDetail.displayDate("12 February 1942") == "12 February 1942")
        #expect(AuthorDetail.displayDate("1948") == "1948")
        #expect(AuthorDetail.displayDate(")") == nil)

        let store = try await LibraryFixture.store()
        // Terry Bisson's shape: OL birth text, Wikidata birth and death only.
        try await store.query("""
            MATCH (a:Author {key: '/authors/OL2A'})
            SET a.birth_date = '12 February 1942', a.wikidata_birth_date = '1942-02-12',
                a.wikidata_death_date = '2024-01-10'
            """)
        let zed = try #require(try await store.authorDetail(key: "/authors/OL2A"))
        #expect(zed.lifespan == "12 February 1942 – 10 January 2024")
        // Open Library pair stays as is.
        #expect(try await store.authorDetail(key: "/authors/OL4A")?.lifespan == "7 November 1913 – 4 January 1960")
    }

    @MainActor
    @Test("search: typing a letter and deleting it inside the debounce leaves the applied text")
    func searchDebounceRevert() async throws {
        let store = try await LibraryFixture.store()
        let model = LibraryModel(store: store)
        model.searchDebounce = .zero
        await model.start()
        model.setSearchText("ap")
        await model.settleSearch()
        #expect(model.filter.text == "ap")

        model.searchDebounce = .milliseconds(200)
        model.setSearchText("apx")              // pending
        model.setSearchText("ap")               // back to the applied text: must cancel "apx"
        await model.settleSearch()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.filter.text == "ap")
        #expect(model.list.books.map(\.key) == ["/works/OL1W"])
    }
}
