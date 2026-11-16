import Testing
import Foundation
@testable import RelateBooksCore

@Suite("LibraryQueries")
struct LibraryQueriesTests {
    @Test("bookCount counts Book nodes")
    func count() async throws {
        let store = try await GraphStore.inMemory()
        #expect(try await store.bookCount() == 0)
        try await Fixtures.insertBooks(into: store)
        #expect(try await store.bookCount() == 3)
    }

    @Test("an empty store returns an empty page and zero count")
    func empty() async throws {
        let store = try await GraphStore.inMemory()
        #expect(try await store.libraryPage().isEmpty)
        #expect(try await store.libraryCount() == 0)
    }

    @Test("title sort: rows decode authors, first item by wishlist position, price, status")
    func titleSortDecodes() async throws {
        let store = try await LibraryFixture.store()
        let page = try await store.libraryPage(sort: .title)
        #expect(page.map(\.key) == ["/works/OL1W", "/works/OL5W", "/works/OL2W", "amazon:B000UNRES", "/works/OL3W"])
        let apple = try #require(page.first)
        #expect(apple.authors == ["Jane Appleseed"])
        #expect(apple.itemCount == 2)
        #expect(apple.wishlistPosition == 1)
        #expect(apple.format == "Hardcover")          // position 1 item wins over position 3
        #expect(apple.price == 25.0)
        #expect(apple.displayPrice == "$25.00")
        #expect(apple.itemTitle == "Apple Orchards: A History")
        #expect(apple.subtitle == nil)                // item title only extends the book title
        #expect(apple.olRating == 4.5)
        #expect(apple.firstPublishYear == 2001)
        #expect(apple.status == .want)
        #expect(apple.imageURLs.first == URL(string: "https://covers.openlibrary.org/b/id/1-M.jpg"))

        let stranger = try #require(page.first { $0.key == "/works/OL5W" })
        #expect(stranger.subtitle == "The Stranger")

        let zebra = try #require(page.first { $0.key == "/works/OL3W" })
        #expect(zebra.authors.isEmpty)
        #expect(zebra.authorLine == "Unknown author")

        let mystery = try #require(page.first { $0.key == "amazon:B000UNRES" })
        #expect(mystery.isUnresolved)
        #expect(mystery.price == nil)
        #expect(mystery.displayPrice == "$3.99")       // falls back to price_text

        #expect(page.first { $0.key == "/works/OL2W" }?.status == .read)
    }

    @Test("each sort orders as documented", arguments: [
        (LibrarySort.title, ["/works/OL1W", "/works/OL5W", "/works/OL2W", "amazon:B000UNRES", "/works/OL3W"]),
        // Surnames: adams, appleseed, brown, camus; no author last.
        (LibrarySort.author, ["/works/OL2W", "/works/OL1W", "amazon:B000UNRES", "/works/OL5W", "/works/OL3W"]),
        (LibrarySort.wishlist, ["/works/OL1W", "/works/OL2W", "/works/OL3W", "amazon:B000UNRES", "/works/OL5W"]),
        // 4.5, 3.9, then unrated by title.
        (LibrarySort.rating, ["/works/OL1W", "/works/OL2W", "/works/OL5W", "amazon:B000UNRES", "/works/OL3W"]),
        // Newest first, undated last.
        (LibrarySort.year, ["/works/OL3W", "/works/OL1W", "/works/OL2W", "/works/OL5W", "amazon:B000UNRES"]),
    ])
    func sorts(sort: LibrarySort, expected: [String]) async throws {
        let store = try await LibraryFixture.store()
        #expect(try await store.libraryPage(sort: sort).map(\.key) == expected)
    }

    @Test("filters narrow page and count alike", arguments: [
        (LibraryFilter(status: .read), ["/works/OL2W"]),
        (LibraryFilter(status: .want), ["/works/OL1W", "/works/OL5W", "amazon:B000UNRES", "/works/OL3W"]),
        (LibraryFilter(status: .reading), []),
        (LibraryFilter(format: "Paperback"), ["/works/OL1W", "/works/OL5W", "/works/OL3W"]),
        (LibraryFilter(format: "Hardcover"), ["/works/OL1W"]),
        (LibraryFilter(genre: "science fiction"), ["/works/OL2W"]),
        (LibraryFilter(unresolvedOnly: true), ["amazon:B000UNRES"]),
        (LibraryFilter(text: "  APPLE "), ["/works/OL1W"]),
        (LibraryFilter(text: "camus"), ["/works/OL5W"]),          // author name
        (LibraryFilter(text: "stranger"), ["/works/OL5W"]),       // English item title
        (LibraryFilter(text: "novel"), ["amazon:B000UNRES"]),     // item title only
        (LibraryFilter(format: "Paperback", text: "zebra"), ["/works/OL3W"]),
        (LibraryFilter(status: .want, format: "Paperback", genre: "fantasy", unresolvedOnly: false, text: "orch"), ["/works/OL1W"]),
        (LibraryFilter(format: "Kindle Edition", genre: "fantasy"), []),
    ])
    func filters(filter: LibraryFilter, expected: [String]) async throws {
        let store = try await LibraryFixture.store()
        #expect(try await store.libraryPage(filter: filter, sort: .title).map(\.key) == expected)
        #expect(try await store.libraryCount(filter: filter) == expected.count)
    }

    @Test("only active filters reach the WHERE clause; values are parameters")
    func statementShape() throws {
        let none = try LibraryQueries.page(filter: LibraryFilter(), sort: .title, skip: 0)
        #expect(!none.cypher.contains("WHERE"))
        #expect(Set(none.parameters.keys) == ["skip", "limit"])
        let evil = "x' OR 1=1 //"
        let some = try LibraryQueries.page(filter: LibraryFilter(format: evil, text: evil), sort: .rating, skip: 80)
        #expect(!some.cypher.contains(evil))
        #expect(some.parameters["format"] == .string(evil))
        #expect(some.parameters["text"] == .string(evil.lowercased()))
        #expect(some.parameters["skip"] == .int(80))
        #expect(some.cypher.contains("sortKey DESC"))
    }

    @Test("paging: 40-row pages, no duplicates or gaps, stable across sorts", arguments: LibrarySort.allCases)
    func paging(sort: LibrarySort) async throws {
        let store = try await LibraryFixture.store()
        try await LibraryFixture.addFillers(90, to: store)
        #expect(try await store.libraryCount() == 95)
        var keys: [String] = []
        var pages: [Int] = []
        var skip = 0
        while true {
            let page = try await store.libraryPage(sort: sort, skip: skip)
            pages.append(page.count)
            keys += page.map(\.key)
            if page.count < LibraryQueries.pageSize { break }
            skip += page.count
        }
        #expect(pages == [40, 40, 15])
        #expect(Set(keys).count == 95)
        let all = try await store.libraryPage(sort: sort, skip: 0, limit: 200)
        #expect(all.map(\.key) == keys)
    }

    @Test("facets count distinct books per format and genre")
    func facets() async throws {
        let store = try await LibraryFixture.store()
        let formats = try await store.formatFacets()
        #expect(formats.first == FacetValue(name: "Paperback", count: 3))
        #expect(Set(formats.map(\.name)) == ["Paperback", "Hardcover", "Kindle Edition", "Mass Market Paperback"])
        let genres = try await store.genreFacets()
        #expect(genres == [FacetValue(name: "fantasy", count: 1), FacetValue(name: "science fiction", count: 1)])
    }
}
