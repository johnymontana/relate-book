import Testing
import Foundation
@testable import RelateBooksCore

@Suite("Book, author and term queries")
struct DetailQueriesTests {
    @Test("bookDetail returns every facet of a book")
    func bookDetailFacets() async throws {
        let store = try await LibraryFixture.store()
        let book = try #require(try await store.bookDetail(key: "/works/OL1W"))
        #expect(book.title == "Apple Orchards")
        #expect(book.authors == [AuthorRef(key: "/authors/OL1A", name: "Jane Appleseed", role: "Author")])
        #expect(book.description == "All about apples.")
        #expect(book.firstPublishYear == 2001)
        #expect(book.pagesMedian == 320)
        #expect(book.olRating == 4.5)
        #expect(book.olRatingCount == 12)
        #expect(book.olWantToRead == 40)
        #expect(book.subjects == ["Fruit", "Orchards"])
        #expect(book.places == ["Washington"])
        #expect(book.people == ["Johnny Appleseed"])
        #expect(book.eras == ["20th century"])
        #expect(book.genres == ["fantasy"])
        #expect(book.publishers == ["Tree Press"])
        #expect(book.series == [SeriesMembership(name: "Orchard Cycle", position: "2")])
        #expect(book.awards == [AwardWin(name: "Hugo Award", year: 2002)])
        #expect(book.items.map(\.asin) == ["A002", "A001"])        // wishlist order
        #expect(book.primaryItem?.displayPrice == "$25.00")
        #expect(book.items[1].amazonRating == 4.2)
        #expect(book.items[1].amazonReviewCount == 31)
        #expect(book.items[1].url == URL(string: "https://www.amazon.com/dp/A001"))
        #expect(book.items[0].priority == "high")
        #expect(book.status == .want)
        #expect(book.url == URL(string: "https://openlibrary.org/works/OL1W"))
    }

    @Test("bookDetail handles a book with no author, an unresolved book, and a missing key")
    func bookDetailEdges() async throws {
        let store = try await LibraryFixture.store()
        let zebra = try #require(try await store.bookDetail(key: "/works/OL3W"))
        #expect(zebra.authors.isEmpty)
        #expect(zebra.subjects.isEmpty && zebra.awards.isEmpty)
        let mystery = try #require(try await store.bookDetail(key: "amazon:B000UNRES"))
        #expect(mystery.isUnresolved)
        #expect(mystery.subtitle == nil)
        #expect(mystery.primaryItem?.displayPrice == "$3.99")
        let stranger = try #require(try await store.bookDetail(key: "/works/OL5W"))
        #expect(stranger.subtitle == "The Stranger")
        #expect(try await store.bookDetail(key: "/works/NOPE") == nil)
    }

    @Test("authorDetail decodes bio, dates, origins, awards; authorBooks lists the books")
    func author() async throws {
        let store = try await LibraryFixture.store()
        let jane = try #require(try await store.authorDetail(key: "/authors/OL1A"))
        #expect(jane.name == "Jane Appleseed")
        #expect(jane.bio == "Grew apples.")                // "Source: [Wikipedia]" trailer removed
        #expect(jane.lifespan == "Born 1 January 1950")
        #expect(jane.wikipediaURL == URL(string: "https://en.wikipedia.org/wiki/Jane"))
        #expect(jane.imageURLs.count == 1)
        #expect(jane.occupations == ["novelist", "farmer"])
        #expect(jane.bookCount == 1)
        #expect(try await store.authorBooks(key: "/authors/OL1A").map(\.key) == ["/works/OL1W"])

        let camus = try #require(try await store.authorDetail(key: "/authors/OL4A"))
        #expect(camus.lifespan == "7 November 1913 – 4 January 1960")
        #expect(camus.bornIn == ["Mondovi"])
        #expect(camus.citizenOf == ["France"])
        #expect(camus.awards == [AwardWin(name: "Nobel Prize in Literature", year: 1957)])
        #expect(try await store.authorDetail(key: "/authors/NOPE") == nil)
    }

    @Test("authorBooks: newest first, decoded like library rows")
    func authorBooksOrder() async throws {
        let store = try await LibraryFixture.store()
        try await store.query("""
            MATCH (a:Author {key: '/authors/OL1A'}), (b:Book {key: '/works/OL3W'})
            CREATE (b)-[:WRITTEN_BY]->(a)
            """)
        let books = try await store.authorBooks(key: "/authors/OL1A")
        #expect(books.map(\.key) == ["/works/OL3W", "/works/OL1W"])
        #expect(books[1].format == "Hardcover")
    }

    @Test("termBooks reaches every facet kind", arguments: [
        (TermKind.subject, "Fruit", ["/works/OL1W", "/works/OL2W"]),
        (TermKind.genre, "fantasy", ["/works/OL1W"]),
        (TermKind.place, "Washington", ["/works/OL1W"]),
        (TermKind.person, "Johnny Appleseed", ["/works/OL1W"]),
        (TermKind.era, "20th century", ["/works/OL1W"]),
        (TermKind.publisher, "Tree Press", ["/works/OL1W"]),
        (TermKind.award, "Hugo Award", ["/works/OL1W"]),
        (TermKind.country, "France", ["/works/OL5W"]),
        // Series: reading order (#1 Zebra, #2 Apple), not title order.
        (TermKind.series, "Orchard Cycle", ["/works/OL3W", "/works/OL1W"]),
        (TermKind.subject, "Nothing", []),
    ])
    func termBooks(kind: TermKind, name: String, expected: [String]) async throws {
        let store = try await LibraryFixture.store()
        #expect(try await store.termBooks(kind, name: name).map(\.key) == expected)
        #expect(try await store.termBookCount(kind, name: name) == expected.count)
    }

    @Test("termAuthors: born in a place, citizens, award winners")
    func termAuthors() async throws {
        let store = try await LibraryFixture.store()
        #expect(try await store.termAuthors(.place, name: "Mondovi").map(\.name) == ["Albert Camus"])
        #expect(try await store.termAuthors(.country, name: "France").map(\.key) == ["/authors/OL4A"])
        #expect(try await store.termAuthors(.award, name: "Nobel Prize in Literature").first?.bookCount == 1)
        #expect(try await store.termAuthors(.subject, name: "Fruit").isEmpty)
        let summary = try await store.termSummary(.place, name: "Mondovi")
        #expect(summary.bookCount == 0 && summary.authorCount == 1)
    }

    @Test("termBooks pages with SKIP/LIMIT")
    func termPaging() async throws {
        let store = try await LibraryFixture.store()
        try await LibraryFixture.addFillers(45, to: store)
        try await store.query("""
            MATCH (b:Book) WHERE b.key STARTS WITH '/works/F'
            MATCH (s:Subject {name: 'Fruit'}) CREATE (b)-[:ABOUT]->(s)
            """)
        let first = try await store.termBooks(.subject, name: "Fruit", skip: 0)
        let second = try await store.termBooks(.subject, name: "Fruit", skip: 40)
        #expect(first.count == 40 && second.count == 7)
        #expect(Set(first.map(\.key)).isDisjoint(with: second.map(\.key)))
    }
}
