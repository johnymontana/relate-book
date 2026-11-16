import Relate

/// Cypher for "Next up" and for "near your reading" on the map: multi-hop
/// reads that start from what the user has read or rated and end at books
/// they have not.
///
/// - "Unread" is `coalesce(reading_status, 'want') = 'want'`: a missing
///   status means want, and a book being read is not suggested.
/// - Each statement returns keys and the facts for its caption; the caller
///   reads the `BookSummary` rows for those keys in the same snapshot.
/// - No `CALL { }` subquery, so all of it runs as a read.
enum NextUpQueries {
    static let unread = "coalesce(n.reading_status, 'want') = 'want'"

    /// Series with at least one read book and one unread book on the list:
    /// `name, readCount, listCount, unreadCount` and the unread book with
    /// the lowest position (`key, position`). A position that is not a
    /// number sorts last. Most-read series first.
    static func series(limit: Int) throws -> Statement {
        try Statement("""
            MATCH (r:Book)-[:PART_OF]->(s:Series)
            WHERE r.reading_status = 'read'
            WITH s, count(DISTINCT r) AS readCount
            MATCH (n:Book)-[p:PART_OF]->(s)
            WHERE \(unread)
            WITH s, readCount, n, p.position AS position, toFloat(p.position) AS ordinal
            ORDER BY ordinal, n.title, n.key
            WITH s, readCount, collect({key: n.key, position: position}) AS waiting
            RETURN s.name AS name, readCount, COUNT { (s)<-[:PART_OF]-(:Book) } AS listCount,
                   size(waiting) AS unreadCount, waiting[0].key AS key, waiting[0].position AS position
            ORDER BY readCount DESC, name
            LIMIT $limit
            """, ["limit": max(1, limit)])
    }

    /// Authors of a book rated at least `minRating`, with their unread,
    /// unrated books on the list: `authorKey, authorName, best, liked` (the
    /// best-rated title), `unreadCount, keys` (the first `perAuthor`, by
    /// title). Best rating first.
    static func authors(minRating: Int, perAuthor: Int, limit: Int) throws -> Statement {
        try Statement("""
            MATCH (l:Book)-[:WRITTEN_BY]->(a:Author)
            WHERE l.my_rating >= $minRating
            WITH a, l ORDER BY l.my_rating DESC, l.title
            WITH a, max(l.my_rating) AS best, collect(l.title)[0] AS liked
            MATCH (n:Book)-[:WRITTEN_BY]->(a)
            WHERE \(unread) AND n.my_rating IS NULL
            WITH a, best, liked, n ORDER BY n.title, n.key
            WITH a, best, liked, collect(DISTINCT n.key) AS keys
            RETURN a.key AS authorKey, a.name AS authorName, best, liked,
                   size(keys) AS unreadCount, keys[0..$perAuthor] AS keys
            ORDER BY best DESC, authorName, authorKey
            LIMIT $limit
            """, ["minRating": minRating, "perAuthor": max(1, perAuthor), "limit": max(1, limit)])
    }

    /// Unread books that won awards: `key, awardCount, sharedCount` (awards
    /// that a book rated at least `minRating` also won) and up to three
    /// award names, the shared ones first. Books sharing an award with the
    /// user's favourites come first, then the most awarded.
    ///
    /// The favourites' awards are collected first, from the rated books. A
    /// per-row `EXISTS` over each award's winners took 462 ms on the scaled
    /// perf store, where an award has 300 winners.
    static func awards(minRating: Int, limit: Int) throws -> Statement {
        try Statement("""
            OPTIONAL MATCH (l:Book)-[:WON]->(la:Award)
            WHERE l.my_rating >= $minRating
            WITH collect(DISTINCT la) AS likedAwards
            MATCH (n:Book)-[:WON]->(aw:Award)
            WHERE \(unread)
            WITH n, aw, CASE WHEN aw IN likedAwards THEN 1 ELSE 0 END AS shared
            ORDER BY shared DESC, aw.name
            WITH n, collect(aw.name) AS awards, sum(shared) AS sharedCount
            RETURN n.key AS key, size(awards) AS awardCount, sharedCount, awards[0..3] AS awards, n.title AS title
            ORDER BY sharedCount DESC, awardCount DESC, title, key
            LIMIT $limit
            """, ["minRating": minRating, "limit": max(1, limit)])
    }

    /// Places with unread books within `radiusMeters` of a place a read
    /// book is set in (that place itself included, at 0 m): `label,
    /// location`, the nearest such place (`fromLabel`, a read title set
    /// there, `meters`), `bookCount` and the first `perPlace` unread keys by
    /// title. Nearest first.
    ///
    /// A place heading on more than `maxPlaceBooks` books is neither an
    /// origin nor a destination: "United States" is on 173 books of a
    /// 1,811-book list and its point is the middle of the country, so it
    /// would be "near" everything and say nothing.
    static func nearReading(radiusMeters: Double, perPlace: Int, limit: Int, maxPlaceBooks: Int = 25) throws -> Statement {
        try Statement("""
            MATCH (r:Book)-[:SET_IN]->(rp:Place)
            WHERE r.reading_status = 'read' AND rp.location IS NOT NULL AND rp.geocoded_label IS NOT NULL
              AND COUNT { (rp)<-[:SET_IN]-(:Book) } <= $maxPlaceBooks
            WITH rp.geocoded_label AS fromLabel, rp.location AS origin, r ORDER BY r.title, r.key
            WITH fromLabel, origin, collect(r.title)[0] AS readTitle
            MATCH (p:Place)
            WHERE point.distance(p.location, origin) <= $radius AND p.geocoded_label IS NOT NULL
              AND COUNT { (p)<-[:SET_IN]-(:Book) } <= $maxPlaceBooks
            WITH p, fromLabel, readTitle, point.distance(p.location, origin) AS meters
            ORDER BY meters, fromLabel
            WITH p.geocoded_label AS label, collect(DISTINCT p) AS places,
                 collect(fromLabel)[0] AS fromLabel, collect(readTitle)[0] AS readTitle, min(meters) AS meters
            UNWIND places AS q
            MATCH (n:Book)-[:SET_IN]->(q)
            WHERE \(unread)
            WITH label, places[0].location AS location, fromLabel, readTitle, meters, n ORDER BY n.title, n.key
            WITH label, location, fromLabel, readTitle, meters, collect(DISTINCT n.key) AS keys
            RETURN label, location, fromLabel, readTitle, toInteger(meters) AS meters,
                   size(keys) AS bookCount, keys[0..$perPlace] AS keys
            ORDER BY meters, bookCount DESC, label
            LIMIT $limit
            """, ["radius": radiusMeters, "perPlace": max(1, perPlace), "limit": max(1, limit),
                  "maxPlaceBooks": max(1, maxPlaceBooks)])
    }
}

extension GraphStore {
    /// Runs `statement` in `tx` and returns its rows with the `BookSummary`
    /// of every key the rows name (`keys(row)`), read in the same snapshot.
    private static func rowsWithBooks(_ tx: Transaction, _ statement: Statement,
                                      keys: (Row) -> [String]) throws -> ([Row], [String: BookSummary]) {
        let rows = try tx.run(statement).rowsView
        var seen: Set<String> = []
        let wanted = rows.flatMap(keys).filter { seen.insert($0).inserted }
        guard !wanted.isEmpty else { return (rows, [:]) }
        let books = try tx.run(SearchQueries.hydrate(keys: wanted, filter: SearchFilter(), limit: wanted.count))
            .rowsView.map(BookSummary.init(row:))
        return (rows, Dictionary(books.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    /// The three "Next up" lists, read from one snapshot.
    func nextUp(minRating: Int = 4, seriesLimit: Int = 20, authorLimit: Int = 20, perAuthor: Int = 3,
                awardLimit: Int = 10) async throws -> NextUp {
        let series = try NextUpQueries.series(limit: seriesLimit)
        let authors = try NextUpQueries.authors(minRating: minRating, perAuthor: perAuthor, limit: authorLimit)
        let awards = try NextUpQueries.awards(minRating: minRating, limit: awardLimit)
        return try await database.read { tx in
            var next = NextUp()
            let (seriesRows, seriesBooks) = try Self.rowsWithBooks(tx, series) { $0.string("key").map { [$0] } ?? [] }
            next.series = seriesRows.compactMap { row in
                guard let name = row.string("name"), let key = row.string("key"), let book = seriesBooks[key] else { return nil }
                return SeriesNext(name: name, readCount: row.int("readCount") ?? 0, listCount: row.int("listCount") ?? 0,
                                  unreadCount: row.int("unreadCount") ?? 0, book: book, position: row.text("position"))
            }
            let (authorRows, authorBooks) = try Self.rowsWithBooks(tx, authors) { $0.strings("keys") }
            next.authors = authorRows.compactMap { row in
                let books = row.strings("keys").compactMap { authorBooks[$0] }
                guard let name = row.string("authorName"), let best = row.int("best"), !books.isEmpty else { return nil }
                return AuthorNext(authorKey: row.string("authorKey"), authorName: name, bestRating: best,
                                  likedTitle: row.string("liked") ?? "", unreadCount: row.int("unreadCount") ?? books.count,
                                  books: books)
            }
            let (awardRows, awardBooks) = try Self.rowsWithBooks(tx, awards) { $0.string("key").map { [$0] } ?? [] }
            next.awards = awardRows.compactMap { row in
                guard let key = row.string("key"), let book = awardBooks[key] else { return nil }
                return AwardNext(book: book, awardCount: row.int("awardCount") ?? 0, sharedCount: row.int("sharedCount") ?? 0,
                                 awards: row.strings("awards"))
            }
            return next
        }
    }

    /// Unread settings near what the user has read, nearest first.
    func placesNearReading(radiusMeters: Double = 250_000, perPlace: Int = 3, limit: Int = 30,
                           maxPlaceBooks: Int = 25) async throws -> [NearbyReading] {
        let statement = try NextUpQueries.nearReading(radiusMeters: radiusMeters, perPlace: perPlace, limit: limit,
                                                      maxPlaceBooks: maxPlaceBooks)
        return try await database.read { tx in
            let (rows, books) = try Self.rowsWithBooks(tx, statement) { $0.strings("keys") }
            return rows.compactMap { row in
                guard let label = row.string("label"), let coordinate = row.point("location"),
                      let from = row.string("fromLabel") else { return nil }
                let found = row.strings("keys").compactMap { books[$0] }
                guard !found.isEmpty else { return nil }
                return NearbyReading(label: label, coordinate: coordinate, fromLabel: from,
                                     readTitle: row.string("readTitle") ?? "", meters: row.int("meters") ?? 0,
                                     bookCount: row.int("bookCount") ?? found.count, books: found)
            }
        }
    }
}
