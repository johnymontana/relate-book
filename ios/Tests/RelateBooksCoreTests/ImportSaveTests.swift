import Testing
import Foundation
import Relate
@testable import RelateBooksCore

@Suite("Import save")
struct ImportSaveTests {
    static let now = Date(timeIntervalSince1970: 1_794_169_800)   // 2026-11-08T20:30:00Z

    /// LibraryFixture + the book_text index + Junger (old bio) + a located "New England".
    static func store() async throws -> GraphStore {
        let store = try await LibraryFixture.store()
        for ddl in EmbeddingFixture.fulltextDDL { try await store.query(ddl) }
        try await store.query("""
            CREATE (:Author {key: '/authors/OL389527A', name: 'Sebastian Junger', bio: 'old bio'})
            CREATE (:Place {name: 'New England', location: point({latitude: 43.97, longitude: -71.31}),
                            geocoded_label: 'New England', geo_status: 'ok'})
            """)
        return store
    }

    static func count(_ store: GraphStore, _ cypher: String) async throws -> Int {
        try await EmbeddingFixture.count(store, cypher)
    }

    static func counts(_ store: GraphStore) async throws -> [Int] {
        var out: [Int] = []
        for label in ["Book", "Author", "Subject", "Place", "Person", "Era", "Genre"] {
            out.append(try await count(store, "MATCH (n:\(label)) RETURN count(n) AS c"))
        }
        out.append(try await count(store, "MATCH (:Book {key: '/works/OL2670211W'})-[r]-() RETURN count(r) AS c"))
        return out
    }

    @Test("save writes the book, links existing nodes untouched, and stamps what it created")
    func save() async throws {
        let store = try await Self.store()
        let structural = "MATCH (n) WHERE n:Item OR n:Edition OR n:Publisher OR n:Series RETURN count(n) AS c"
        let structuralBefore = try await Self.count(store, structural)
        let draft = try PerfectStorm.draft()
        let result = try await store.saveImport(draft, now: Self.now)
        #expect(result == .created(key: PerfectStorm.key, newPlaces: ["North Atlantic Ocean", "Gloucester (Mass.)"]))

        let detail = try #require(try await store.bookDetail(key: PerfectStorm.key))
        #expect(detail.source == "app" && detail.isAppAdded && !detail.isManual)
        #expect(detail.addedOn == Self.now)
        #expect(detail.importMatch == .isbn)
        #expect(detail.appEdition?.isbn13 == "9780393337013" && detail.appEdition?.publishYear == 2009)
        #expect(detail.title == "The Perfect Storm" && detail.items.isEmpty)
        #expect(detail.authors.count == 2 && detail.subjects.count == 36 && detail.places.count == 3)
        #expect(detail.description?.hasPrefix("It was the storm") == true && detail.olRating == 4.125)

        let junger = try await store.query("MATCH (a:Author {key: '/authors/OL389527A'}) RETURN a.bio AS bio, a.added_on AS added, a.source AS source").rowsView[0]
        #expect(junger.string("bio") == "old bio" && junger["added"] == .null && junger["source"] == .null)
        let collins = try await store.query("MATCH (a:Author {key: '/authors/OL2801780A'}) RETURN a.added_on AS added, a.source AS source").rowsView[0]
        #expect(collins.instant("added") == Self.now && collins.string("source") == "openlibrary")
        #expect(try await Self.count(store, "MATCH (s:Subject) WHERE s.added_on IS NOT NULL RETURN count(s) AS c") == 36)
        #expect(try await Self.count(store, "MATCH (p:Place) WHERE p.added_on IS NOT NULL RETURN count(p) AS c") == 2)
        #expect(try await Self.count(store, "MATCH (p:Place {name: 'New England'}) WHERE p.added_on IS NULL RETURN count(p) AS c") == 1)
        #expect(try await Self.count(store, "MATCH (:Book {key: '/works/OL2670211W'})-[w:WRITTEN_BY {role: 'Author'}]->() RETURN count(w) AS c") == 2)
        #expect(try await Self.count(store, structural) == structuralBefore)
    }

    @Test("idempotent: the same draft again is .existing and changes nothing")
    func idempotent() async throws {
        let store = try await Self.store()
        let draft = try PerfectStorm.draft()
        _ = try await store.saveImport(draft, now: Self.now)
        let before = try await Self.counts(store)
        #expect(try await store.saveImport(draft, now: Self.now.addingTimeInterval(60)) == .existing(key: PerfectStorm.key))
        #expect(try await Self.counts(store) == before)
        // The statements themselves are guarded too (a race past the pre-check).
        let results = try await store.write(try ImportQueries.saveStatements(draft, now: Self.now.addingTimeInterval(120)))
        #expect(results[0].rowsView.first?.bool("created") == false)
        #expect(try await Self.counts(store) == before)
    }

    @Test("an existing book is never overwritten")
    func neverOverwrite() async throws {
        let store = try await Self.store()
        let draft = try PerfectStorm.draft()
        let hijack = ImportDraft(key: "/works/OL1W", match: .isbn, title: "Hijack", properties: draft.properties,
                                 authors: draft.authors, terms: draft.terms)
        let edgesBefore = try await Self.count(store, "MATCH (:Book {key: '/works/OL1W'})-[r]-() RETURN count(r) AS c")
        #expect(try await store.saveImport(hijack, now: Self.now) == .existing(key: "/works/OL1W"))
        let row = try await store.query("MATCH (b:Book {key: '/works/OL1W'}) RETURN b.title AS t, b.source AS s, b.isbn13 AS i").rowsView[0]
        #expect(row.string("t") == "Apple Orchards" && row["s"] == .null && row["i"] == .null)
        #expect(try await Self.count(store, "MATCH (:Book {key: '/works/OL1W'})-[r]-() RETURN count(r) AS c") == edgesBefore)
        #expect(try await Self.count(store, "MATCH (n) WHERE n.added_on IS NOT NULL RETURN count(n) AS c") == 0)
    }

    @Test("manual save links an existing byline author without modifying it")
    func manualSave() async throws {
        let store = try await Self.store()
        try await store.query("CREATE (:Author {key: 'name:rana-foroohar', name: 'Rana Foroohar', source: 'amazon-byline'})")
        let draft = try ImportDraft.manual(title: "Field Notes from the Bitterroot", authors: "Jane Doe, Rana Foroohar", uuid: UUID())
        guard case .created(let key, let places) = try await store.saveImport(draft, now: Self.now) else {
            Issue.record("expected created"); return
        }
        #expect(places.isEmpty && key.hasPrefix("manual:"))
        let rows = try await store.query("""
            MATCH (b:Book {key: $key})-[:WRITTEN_BY]->(a:Author)
            RETURN a.key AS key, a.source AS source, a.added_on IS NOT NULL AS stamped, b.match AS m, b.source AS s
            ORDER BY key
            """, ["key": .string(key)]).rowsView
        #expect(rows.map { $0.string("key") } == ["name:jane-doe", "name:rana-foroohar"])
        #expect(rows.map { $0.string("source") } == ["app", "amazon-byline"])
        #expect(rows.map { $0.bool("stamped") } == [true, false])
        #expect(rows.allSatisfy { $0.string("m") == "manual" && $0.string("s") == "app" })
        let detail = try #require(try await store.bookDetail(key: key))
        #expect(detail.isManual && detail.appEdition == nil && detail.importMatch == .manual)
    }

    @Test("lists, search and facets tolerate a book with no Item")
    func lists() async throws {
        let store = try await Self.store()
        _ = try await store.saveImport(try PerfectStorm.draft(), now: Self.now)
        let row = try #require(try await store.libraryPage(filter: LibraryFilter(text: "perfect storm")).first)
        #expect(row.key == PerfectStorm.key && row.source == "app" && row.isAppAdded)
        #expect(row.format == nil && row.itemCount == 0 && row.price == nil)
        #expect(row.trailingText == "Added in app" && row.addedOn == Self.now)
        #expect(row.authors.sorted() == ["Anne Collins", "Sebastian Junger"])
        #expect(try await store.hydrateSearch(keys: [PerfectStorm.key], limit: 5).map(\.key) == [PerfectStorm.key])
        #expect(try await store.termBooks(.subject, name: "Shipwrecks").map(\.key) == [PerfectStorm.key])
        #expect(try await store.authorBooks(key: PerfectStorm.junger).map(\.key) == [PerfectStorm.key])
        #expect(try await store.libraryPage(sort: .wishlist, limit: 100).last?.key == PerfectStorm.key)
        #expect(try await store.libraryCount() == 6)

        let paperbackBefore = try await store.formatFacets().first { $0.name == "Paperback" }?.count ?? 0
        try await store.query("MATCH (b:Book {key: '/works/OL2670211W'}) SET b.physical_format = 'Paperback'")
        #expect(try await store.formatFacets().first { $0.name == "Paperback" }?.count == paperbackBefore + 1)
        #expect(try await store.libraryPage(filter: LibraryFilter(format: "Paperback")).contains { $0.key == PerfectStorm.key })
        #expect(try await store.libraryPage(filter: LibraryFilter(text: "perfect storm")).first?.format == "Paperback")
        let facets = try await store.formatFacets()
        #expect(facets == facets.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name })
    }

    @Test("keyword search finds the new book right after the commit")
    func fulltext() async throws {
        let store = try await Self.store()
        _ = try await store.saveImport(try PerfectStorm.draft(), now: Self.now)
        #expect(try await store.bookTextHits(KeywordQuery("perfect storm")!, limit: 10).first?.key == PerfectStorm.key)
    }

    @Test("resetUserData removes app books and the nodes their imports created, nothing else")
    func reset() async throws {
        let store = try await Self.store()
        let before = try await Self.counts(store)
        _ = try await store.saveImport(try PerfectStorm.draft(), now: Self.now)
        _ = try await store.saveImport(try ImportDraft.manual(title: "Manual", authors: "Jane Doe", uuid: UUID()), now: Self.now)
        #expect(try await store.bookCount() == 7)
        try await store.resetUserData()
        #expect(try await Self.counts(store) == before)
        #expect(try await store.bookExists(key: PerfectStorm.key) == false)
        #expect(try await Self.count(store, "MATCH (a:Author {key: '/authors/OL389527A'}) RETURN count(a) AS c") == 1)
        #expect(try await Self.count(store, "MATCH (p:Place {name: 'New England'}) RETURN count(p) AS c") == 1)
        #expect(try await Self.count(store, "MATCH (n) WHERE n.added_on IS NOT NULL RETURN count(n) AS c") == 0)
        #expect(StatusQueries.reset.count == 5)
        // Re-import works after the reset.
        #expect(try await store.saveImport(try PerfectStorm.draft(), now: Self.now) != .existing(key: PerfectStorm.key))
    }
}
