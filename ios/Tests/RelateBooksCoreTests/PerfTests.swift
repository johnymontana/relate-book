import Testing
import Foundation
import Relate
@testable import RelateBooksCore

/// Runs every library-list, detail and term query against a temp copy of
/// the bundled sample store scaled to 1,800 books (`ScaledLibrary`) and
/// asserts the engine-reported `elapsedMs` (median of 5 warm runs) is under
/// 50 ms (phase 4 place queries: 30 ms; the sample must be geocoded). Each
/// line is printed as `PERF <name>: cold … median … max … rows …` for the
/// plan changelog.
@Suite("Perf on the scaled sample books.rl", .serialized)
struct PerfTests {
    static let budgetMs = 50.0
    /// Phase 4: every place query (region, search, sheet, resolve, near me).
    static let placeBudgetMs = 30.0
    static let warmRuns = 5

    /// ios/RelateBooks/Resources/books.rl, located from this file.
    static var bundledStore: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RelateBooks/Resources/books.rl")
    }

    struct Measurement: Sendable {
        let name: String
        let cold: Double
        let median: Double
        let max: Double
        let rows: Int
    }

    static func measure(_ store: GraphStore, _ name: String, _ statement: Statement) async throws -> Measurement {
        let cold = try await store.run(statement)
        var warm: [Double] = []
        var rows = cold.rows.count
        for _ in 0..<warmRuns {
            let r = try await store.run(statement)
            warm.append(r.elapsedMs)
            rows = r.rows.count
        }
        warm.sort()
        let m = Measurement(name: name, cold: cold.elapsedMs, median: warm[warm.count / 2], max: warm.last ?? 0, rows: rows)
        print(String(format: "PERF %@: cold %.2f ms, median %.2f ms, max %.2f ms, rows %d",
                     name, m.cold, m.median, m.max, m.rows))
        return m
    }

    /// Left Hand of Darkness: seeded with notes, a rating and a tag.
    static let leftHand = "/works/OL59800W"
    static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    /// Seeds user data into the temp copy only: statuses on 300 books (with
    /// status_changed_on), a 200-book tag "Big", a 3-book tag "Favorites",
    /// three notes and a rating on Left Hand.
    static func seedUserData(_ store: GraphStore) async throws {
        try await store.query("""
            MATCH (b:Book) WITH b ORDER BY b.key LIMIT 300
            WITH collect(b) AS bs UNWIND range(0, size(bs) - 1) AS i
            WITH bs[i] AS b, i
            SET b.reading_status = CASE i % 3 WHEN 0 THEN 'read' WHEN 1 THEN 'reading' ELSE 'want' END,
                b.status_changed_on = datetime('2026-01-01T00:00:00Z') + duration({minutes: i})
            """)
        try await store.query("""
            MERGE (t:Tag {name: 'Big'}) ON CREATE SET t.color = 'purple', t.created_on = datetime('2026-01-01T00:00:00Z')
            WITH t MATCH (b:Book) WITH t, b ORDER BY b.title SKIP 100 LIMIT 200
            MERGE (b)-[r:TAGGED]->(t) ON CREATE SET r.on = t.created_on
            """)
        for key in [leftHand, "/works/OL17876078W", "/works/OL2965102W"] {
            try await store.addTag(bookKey: key, name: "Favorites")
        }
        for n in 1...3 {
            try await store.addNote(bookKey: leftHand, text: "Perf note \(n)")
        }
        try await store.setRating(key: leftHand, rating: 4)
    }

    /// Phase-2 reads and idempotent writes (safe to run 6 times).
    static func userDataStatements(noteID: String) -> [(String, Statement)] {
        [
            ("tags", TagQueries.list),
            ("tagsForBook Left Hand", TagQueries.forBook(key: leftHand)),
            ("notes Left Hand", NoteQueries.list(bookKey: leftHand)),
            ("bookUserData Left Hand", StatusQueries.userData(key: leftHand)),
            ("setStatus Left Hand read", StatusQueries.setStatus(key: leftHand, status: .read, now: fixedNow, calendar: .current)),
            ("setRating", StatusQueries.setRating(key: leftHand, rating: 5)),
            ("addTag Favorites (existing)", TagQueries.addTag(key: leftHand, name: "Favorites", color: .blue, now: fixedNow)),
            ("renameTag Big->Big", TagQueries.rename(old: "Big", new: "Big")),
            ("updateNote", NoteQueries.update(id: noteID, text: "Perf note 1 (edited)", now: fixedNow)),
        ]
    }

    // MARK: Phase 3 (fake vectors; the real model never runs here)

    static let hailMary = "/works/OL21745884W"

    /// Deterministic unit vectors (SplitMix64, seed 42).
    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unitVector(_ n: Int = 384) -> [Float] {
            let raw = (0..<n).map { _ in Float(Double(next() >> 11) / Double(1 << 53) * 2 - 1) }
            return try! EmbeddingVector.normalized(raw)
        }
    }

    struct EmbeddingSeed {
        var bookRows: [BookEmbeddingRow]
        var query: [Float]
    }

    /// Embeds the first 400 books by key plus Project Hail Mary and Left
    /// Hand with random unit vectors (model "perf-random"), and adds 57 notes
    /// across 19 books (60 with Left Hand's 3), all with random vectors.
    static func seedEmbeddings(_ store: GraphStore) async throws -> EmbeddingSeed {
        var rng = SplitMix64(state: 42)
        var keys = try await store.query("MATCH (b:Book) WITH b ORDER BY b.key LIMIT 400 RETURN b.key AS key")
            .rowsView.compactMap { $0.string("key") }
        for key in [hailMary, leftHand] where !keys.contains(key) { keys.append(key) }
        let rows = keys.map { BookEmbeddingRow(key: $0, vector: rng.unitVector(), hash: "perf") }
        for start in stride(from: 0, to: rows.count, by: 32) {
            try await store.writeBookEmbeddings(Array(rows[start..<min(start + 32, rows.count)]), model: "perf-random")
        }
        for key in keys.prefix(19) {
            for n in 1...3 {
                try await store.addNote(bookKey: key, text: "Perf note \(n) on \(key): a thought about this book.", now: fixedNow)
            }
        }
        let notes = try await store.noteEmbeddingInputs(bookKey: nil)
        let noteRows = notes.map { NoteEmbeddingRow(id: $0.id, text: $0.text, vector: rng.unitVector(), hash: "perf") }
        for start in stride(from: 0, to: noteRows.count, by: 32) {
            try await store.writeNoteEmbeddings(Array(noteRows[start..<min(start + 32, noteRows.count)]), model: "perf-random")
        }
        return EmbeddingSeed(bookRows: rows, query: rng.unitVector())
    }

    static func searchStatements(seed: EmbeddingSeed, hydrateKeys: [String]) -> [(String, Statement)] {
        var list: [(String, Statement)] = [
            ("semantic top50", SearchQueries.semantic(vector: seed.query, limit: 50)),
        ]
        for text in ["lonely astronaut saves earth", "le guin", "history"] {
            let q = KeywordQuery(text)!
            list.append(("bookText [\(text)]", SearchQueries.bookText(q, limit: 50)))
            list.append(("itemText [\(text)]", SearchQueries.itemText(q, limit: 50)))
        }
        list += [
            ("notes top20", SearchQueries.notes(vector: seed.query, limit: 20)),
            ("moreLikeThis Project Hail Mary", SearchQueries.moreLikeThis(key: hailMary)),
            ("moreLikeThis Left Hand", SearchQueries.moreLikeThis(key: leftHand)),
            ("hydrate \(hydrateKeys.count) keys [none]", SearchQueries.hydrate(keys: hydrateKeys, filter: SearchFilter(), limit: 50)),
            ("hydrate \(hydrateKeys.count) keys [status=want]", SearchQueries.hydrate(keys: hydrateKeys, filter: SearchFilter(status: .want), limit: 50)),
            ("hydrate \(hydrateKeys.count) keys [tag=Big]", SearchQueries.hydrate(keys: hydrateKeys, filter: SearchFilter(tag: "Big"), limit: 50)),
            ("scanBooks after \"\" (200)", EmbeddingQueries.scanBooks(after: "")),
            ("scanBooks after /works/OL2 (200)", EmbeddingQueries.scanBooks(after: "/works/OL2")),
            ("scanNotes all", EmbeddingQueries.scanNotes(bookKey: nil)),
            ("writeBooks 32 rows", EmbeddingQueries.writeBooks(Array(seed.bookRows.prefix(32)), model: "perf-random")),
        ]
        return list
    }

    // MARK: Phase 4 (the geocoded store)

    /// The 16 place statements, all under `placeBudgetMs`.
    static func placeStatements() -> [(String, Statement)] {
        let antimeridian = GeoBox(south: -30, west: 170, north: 0, east: -160).split()
        var list: [(String, Statement)] = [
            ("placeRegion world", PlaceQueries.region(.world)),
            ("placeRegion US", PlaceQueries.region(GeoBox(south: 24, west: -125, north: 50, east: -66))),
            ("placeRegion Europe", PlaceQueries.region(GeoBox(south: 35, west: -10, north: 60, east: 30))),
            ("placeRegion Montana", PlaceQueries.region(GeoBox(south: 44.3, west: -116.1, north: 49.1, east: -104.0))),
            ("placeRegion Seattle", PlaceQueries.region(GeoBox(south: 47, west: -123, north: 48, east: -122))),
            ("placeRegion antimeridian 170..180", PlaceQueries.region(antimeridian[0])),
            ("placeRegion antimeridian -180..-160", PlaceQueries.region(antimeridian[1])),
        ]
        for text in ["mont", "new york", "an"] {
            list.append(("placeSearch [\(text)]", PlaceQueries.search(text)))
        }
        list += [
            ("placeSummary San Francisco", PlaceQueries.summary(label: "San Francisco")),
            ("placeBooks San Francisco p0", PlaceQueries.books(label: "San Francisco", skip: 0)),
            ("placeBooks United States p0", PlaceQueries.books(label: "United States", skip: 0)),
            ("placeAuthors New York City", PlaceQueries.authors(label: "New York City")),
            ("placeResolve San Francisco", PlaceQueries.resolve("San Francisco")),
            ("placeLocation San Francisco", PlaceQueries.location(name: "San Francisco")),
            ("placesNear Missoula 500 km", PlaceQueries.nearMe(GeoCoordinate(latitude: 46.87, longitude: -113.99), radiusMeters: 500_000)),
        ]
        return list
    }

    static func statements() -> [(String, Statement)] {
        var list: [(String, Statement)] = []
        let filters: [(String, LibraryFilter)] = [
            ("none", LibraryFilter()),
            ("status=want", LibraryFilter(status: .want)),
            ("format=Hardcover", LibraryFilter(format: "Hardcover")),
            ("genre=science fiction", LibraryFilter(genre: "science fiction")),
            ("unresolved", LibraryFilter(unresolvedOnly: true)),
            ("text=le guin", LibraryFilter(text: "le guin")),
            ("text=the", LibraryFilter(text: "the")),
            ("text=an", LibraryFilter(text: "an")),
            ("all", LibraryFilter(status: .want, format: "Paperback", genre: "science fiction", unresolvedOnly: false, text: "the")),
            ("status=read", LibraryFilter(status: .read)),
            ("tag=Big", LibraryFilter(tag: "Big")),
            ("tag=Favorites", LibraryFilter(tag: "Favorites")),
            ("tag=Big+text=an", LibraryFilter(tag: "Big", text: "an")),
            ("all+tag", LibraryFilter(status: .want, format: "Paperback", genre: "science fiction", tag: "Big", text: "the")),
        ]
        for sort in LibrarySort.allCases {
            for (fname, filter) in filters {
                list.append(("libraryPage \(sort.rawValue) [\(fname)] p0", LibraryQueries.page(filter: filter, sort: sort, skip: 0)))
            }
            list.append(("libraryPage \(sort.rawValue) [none] skip 1760", LibraryQueries.page(filter: LibraryFilter(), sort: sort, skip: 1760)))
        }
        list.append(("libraryPage title [tag=Big] skip 160", LibraryQueries.page(filter: LibraryFilter(tag: "Big"), sort: .title, skip: 160)))
        for (fname, filter) in filters {
            list.append(("libraryCount [\(fname)]", LibraryQueries.count(filter: filter)))
        }
        list.append(("formatFacets", LibraryQueries.formatFacets))
        list.append(("genreFacets", LibraryQueries.genreFacets))
        for (name, key) in [
            ("A Truck Full of Money", "/works/OL17876078W"),
            ("The Left Hand of Darkness", "/works/OL59800W"),
            ("Curious Incident (most subjects)", "/works/OL2965102W"),
            ("clone Left Hand ~299", "/works/OL59800W~299"),
        ] {
            list.append(("bookDetail \(name)", BookQueries.detail(key: key)))
        }
        for (name, key) in [("Ursula K. Le Guin", "/authors/OL31353A"), ("Kim Stanley Robinson", "/authors/OL19986A")] {
            list.append(("authorDetail \(name)", AuthorQueries.detail(key: key)))
            list.append(("authorBooks \(name)", AuthorQueries.books(key: key)))
        }
        let terms: [(TermKind, String)] = [
            (.subject, "Fiction"), (.genre, "science fiction"), (.series, "Hainish Cycle"),
            (.place, "United States"), (.place, "New York City"), (.person, "Rocky"),
            (.era, "20th Century"), (.publisher, "Random House"), (.award, "Hugo Award for Best Novel"),
            (.award, "Locus Award for Best Novella"), (.country, "United States"),
        ]
        for (kind, name) in terms {
            list.append(("termBooks \(kind.rawValue)=\(name) p0", TermQueries.books(kind, name: name, skip: 0)))
            list.append(("termSummary \(kind.rawValue)=\(name)", TermQueries.summary(kind, name: name)))
            if let authors = TermQueries.authors(kind, name: name) {
                list.append(("termAuthors \(kind.rawValue)=\(name)", authors))
            }
        }
        list.append(("termBooks subject=Fiction skip 280", TermQueries.books(.subject, name: "Fiction", skip: 280)))
        list.append(("termBooks country=United States skip 480", TermQueries.books(.country, name: "United States", skip: 480)))
        return list
    }

    @Test("every list, detail, term, user-data, search and indexer query is under 50 ms, and every place query under 30 ms, on the scaled sample")
    func realStore() async throws {
        try await HeavyTestGate.exclusive { try await Self.runRealStore() }
    }

    static func runRealStore() async throws {
        let source = Self.bundledStore
        try #require(FileManager.default.fileExists(atPath: source.path), "missing \(source.path)")
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await GraphStore.bootstrap(bundledStore: source, storeURL: dir.appendingPathComponent("library.rl"))
        #expect(try await store.bookCount() == 6)
        try await ScaledLibrary.scale(store)
        #expect(try await store.bookCount() == ScaledLibrary.bookCount)

        // Sanity: the queries return what the screens need on the sample's books.
        let truck = try #require(try await store.bookDetail(key: "/works/OL17876078W"))
        #expect(truck.title == "A Truck Full of Money")
        #expect(!truck.authors.isEmpty && !truck.subjects.isEmpty && truck.primaryItem?.price != nil)
        let leftHand = try #require(try await store.bookDetail(key: "/works/OL59800W"))
        #expect(leftHand.awards.contains(AwardWin(name: "Hugo Award for Best Novel", year: 1970)))
        #expect(leftHand.series == [SeriesMembership(name: "Hainish Cycle", position: "4")])
        let firstPage = try await store.libraryPage()
        #expect(firstPage.count == LibraryQueries.pageSize)
        #expect(try await store.libraryCount(filter: LibraryFilter(unresolvedOnly: true)) == 0)
        let leGuin = try await store.authorBooks(key: "/authors/OL31353A")
        #expect(Set(leGuin.map(\.title)).isSuperset(of: ["The Left Hand of Darkness"]))

        // Phase 4: the bundled sample must be geocoded. Each original label
        // has its book plus the clones of copies 30...299 (271 books).
        let located = try await store.locatedPlaceCount()
        try #require(located > 300, "bundled books.rl has no geocoded places; re-export with relate run wishlist-to-graph --geocode")
        let sanFrancisco = try #require(try await store.placeSummary(label: "San Francisco"))
        #expect(sanFrancisco.bookCount == 271)
        let sanFranciscoBooks = try await store.placeBooks(label: "San Francisco", limit: 300)
        #expect(sanFranciscoBooks.count == 271 && Set(sanFranciscoBooks.map(\.key)).count == 271)
        let worldPins = try await store.placePins(in: .world)
        #expect(worldPins.count >= 300)
        #expect(Set(worldPins.map(\.label)).count == worldPins.count)
        #expect((worldPins.first { $0.label == "United States" }?.books ?? 0) == 271)
        #expect(try await store.searchPlaces("san fran").first?.label == "San Francisco")
        #expect(try await store.placeLocation(name: "Mars").isOnMap == false)
        #expect(try await store.resolvePlace("UK")?.label == "United Kingdom")
        print("PERF places: \(located) located, \(worldPins.count) world pins")

        // Phase 2: user data on the temp copy only.
        try await Self.seedUserData(store)
        #expect(try await store.libraryCount(filter: LibraryFilter(tag: "Big")) == 200)
        #expect(try await store.libraryCount(filter: LibraryFilter(tag: "Favorites")) == 3)
        #expect(try await store.tags().first?.name == "Big")
        let seeded = try #require(try await store.bookDetail(key: Self.leftHand))
        #expect(seeded.userData.notes.count == 3)
        #expect(seeded.userData.rating == 4)
        #expect(seeded.userData.tags.map(\.name) == ["Favorites"])
        let noteID = try #require(seeded.userData.notes.first { $0.text == "Perf note 1" }?.id)
        let recent = try await store.libraryPage(sort: .recentlyUpdated)
        #expect(recent.first?.status != nil && recent.count == LibraryQueries.pageSize)

        // Phase 3: fake 384-d vectors on 400-402 books and 60 notes (temp copy only).
        let seed = try await Self.seedEmbeddings(store)
        #expect(try await store.query("MATCH (b:Book) WHERE b.embedding IS NOT NULL RETURN count(b) AS c").scalar().intValue == Int64(seed.bookRows.count))
        #expect(try await store.query("MATCH (n:Note) WHERE n.embedding IS NOT NULL RETURN count(n) AS c").scalar().intValue == 60)
        let similar = try await store.moreLikeThis(key: Self.hailMary)
        #expect(similar.count == 10 && !similar.contains { $0.key == Self.hailMary })
        let semanticKeys = try await store.semanticCandidates(vector: seed.query, limit: 50).map(\.key)
        #expect(semanticKeys.count == 50)
        let moreKeys = try await store.query("MATCH (b:Book) WITH b ORDER BY b.key SKIP 1000 LIMIT 100 RETURN b.key AS key")
            .rowsView.compactMap { $0.string("key") }
        let hydrateKeys = semanticKeys + moreKeys
        #expect(hydrateKeys.count == 150)
        #expect(try await store.hydrateSearch(keys: hydrateKeys, limit: 50).map(\.key) == Array(hydrateKeys.prefix(50)))

        var results: [Measurement] = []
        for (name, statement) in Self.statements() + Self.userDataStatements(noteID: noteID)
            + Self.searchStatements(seed: seed, hydrateKeys: hydrateKeys) {
            results.append(try await Self.measure(store, name, statement))
        }
        var placeResults: [Measurement] = []
        for (name, statement) in Self.placeStatements() {
            placeResults.append(try await Self.measure(store, name, statement))
        }
        results += placeResults
        #expect(try await store.tags().first { $0.name == "Favorites" }?.bookCount == 3)
        let worst = results.max { $0.median < $1.median }!
        let worstCold = results.max { $0.cold < $1.cold }!
        print(String(format: "PERF summary: %d queries; slowest median %.2f ms (%@); slowest cold %.2f ms (%@)",
                     results.count, worst.median, worst.name, worstCold.cold, worstCold.name))
        for m in results {
            #expect(m.median < Self.budgetMs, "\(m.name) median \(m.median) ms >= \(Self.budgetMs) ms")
        }
        for m in placeResults {
            #expect(m.median < Self.placeBudgetMs, "\(m.name) median \(m.median) ms >= \(Self.placeBudgetMs) ms")
        }
    }
}
