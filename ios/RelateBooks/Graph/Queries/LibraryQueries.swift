import Relate

/// Cypher for the library list. Strings live here; execution is the
/// `GraphStore` extension below, which runs each statement as a read or a write.
///
/// Page shape: filter `Book`s, compute one sort key per book, sort, apply
/// SKIP/LIMIT, and only then join authors and items for the 40 survivors
/// (`summaryProjection`). Only active filters are spliced into the WHERE
/// clause (fixed fragments); every value is a parameter.
enum LibraryQueries {
    static let pageSize = 40

    static let bookCount = "MATCH (b:Book) RETURN count(b) AS count"

    /// Joins authors and one wishlist item onto rows bound as `b, sortKey`,
    /// and returns `BookSummary` columns. Must be followed by an ORDER BY
    /// that restores the page order.
    ///
    /// Authors are collected by DISTINCT name: the store has separate Author
    /// nodes with the same name on one book (e.g. three "David Allen"s).
    /// The shown item is the first by `CONTAINS.position`, except that with
    /// `preferringFormat` (a format filter is active; the statement binds
    /// `$format`) the first item in that format wins, so the row's format and
    /// price match the filter. `position` and `itemCount` cover all items.
    ///
    /// Phase 5: a book added in the app has no Item, so `item` is null: the
    /// format falls back to `Book.physical_format` (ISBN imports), price,
    /// position and the item columns are null and `itemCount` is 0, and
    /// `source` / `addedOn` say where it came from ("Added in app").
    static func summaryProjection(preferringFormat: Bool = false) -> String {
        let itemOrder = preferringFormat
            ? "CASE WHEN i.format = $format THEN 0 ELSE 1 END, c.position"
            : "c.position"
        return """
            OPTIONAL MATCH (b)-[:WRITTEN_BY]->(a:Author)
            WITH b, sortKey, collect(DISTINCT a.name) AS authors
            OPTIONAL MATCH (:Wishlist)-[c:CONTAINS]->(i:Item)-[:EDITION_OF]->(b)
            WITH b, sortKey, authors, i, c ORDER BY \(itemOrder)
            WITH b, sortKey, authors, collect(i)[0] AS item, min(c.position) AS position, count(i) AS itemCount
            RETURN b.key AS key, b.title AS title, item.title AS itemTitle, authors,
                   coalesce(item.format, b.physical_format) AS format, b.cover_url AS coverURL, item.thumbnail_url AS thumbnailURL,
                   coalesce(b.reading_status, 'want') AS status, b.my_rating AS myRating, item.price AS price,
                   item.currency AS currency, item.price_text AS priceText,
                   position, itemCount, b.ol_rating AS olRating, b.first_publish_year AS firstPublishYear,
                   b.source AS source, b.added_on AS addedOn
            """
    }

    /// Name suffixes the surname sort skips ("Frederick P. Brooks Jr." → brooks).
    static let nameSuffixes = "['jr','sr','ii','iii','iv','phd','md']"

    /// Surname-ish sort key for an author name expression `n`: the part
    /// before a comma ("Smith, Greg"), else the last word before any
    /// parenthetical ("Santiago Foz (argentino)" → "foz"), skipping name
    /// suffixes ("Martin Luther King, Jr." → king, "William H. Draper III"
    /// → draper, "Nicholas A. Christakis MD  PhD" → christakis).
    ///
    /// Speed: the suffix-aware form (a list comprehension) only runs for
    /// names ending in a character a suffix can end with ('.', r, R, I, V,
    /// D); everything else takes the plain form. Measured on the real store
    /// the guard costs about 3 ms per author-sorted page; the unguarded
    /// suffix-aware form cost about 10 ms.
    static func surname(_ n: String) -> String {
        let plain = "CASE WHEN \(n) CONTAINS ',' THEN trim(split(\(n), ',')[0]) ELSE last(split(trim(split(\(n), ' (')[0]), ' ')) END"
        let p = "split(trim(split(\(n), ' (')[0]), ',')"
        let suffixAware = """
            CASE WHEN size(\(p)) > 1 AND NOT toLower(replace(trim(\(p)[1]), '.', '')) IN \(nameSuffixes) \
            THEN trim(\(p)[0]) \
            ELSE last([w IN split(trim(\(p)[0]), ' ') WHERE w <> '' AND NOT toLower(replace(w, '.', '')) IN \(nameSuffixes)]) END
            """
        let guardClause = [".", "r", "R", "I", "V", "D"].map { "\(n) ENDS WITH '\($0)'" }.joined(separator: " OR ")
        return "toLower(CASE WHEN \(guardClause) THEN \(suffixAware) ELSE \(plain) END)"
    }

    /// `WITH b, <key> AS sortKey` (plus any join it needs) and the direction.
    static func sortKey(_ sort: LibrarySort) -> (clause: String, descending: Bool) {
        switch sort {
        case .title:
            ("WITH b, toLower(coalesce(b.title, b.key)) AS sortKey", false)
        case .author:
            ("""
             OPTIONAL MATCH (b)-[:WRITTEN_BY]->(sa:Author)
             WITH b, min(\(surname("sa.name"))) AS sortKey
             """, false)
        case .wishlist:
            ("""
             OPTIONAL MATCH (:Wishlist)-[sc:CONTAINS]->(:Item)-[:EDITION_OF]->(b)
             WITH b, min(sc.position) AS sortKey
             """, false)
        case .rating:
            ("WITH b, b.ol_rating AS sortKey", true)
        case .year:
            ("WITH b, b.first_publish_year AS sortKey", true)
        case .recentlyUpdated:
            ("WITH b, b.status_changed_on AS sortKey", true)
        }
    }

    static func orderBy(_ sort: LibrarySort) -> String {
        let direction = sortKey(sort).descending ? " DESC" : ""
        return "ORDER BY sortKey IS NULL, sortKey\(direction), toLower(coalesce(b.title, b.key)), b.key"
    }

    /// The status condition on `b` (binds `$status`). A missing
    /// reading_status means want; reading/read use plain equality, which the
    /// book_status index serves. Shared with search's hydrate query.
    static func statusCondition(_ status: ReadingStatus) -> String {
        status == .want ? "coalesce(b.reading_status, 'want') = $status" : "b.reading_status = $status"
    }

    /// Binds `b` to the books the filter matches: `MATCH (b:Book) [WHERE …]`
    /// with only the active filters, and their parameters.
    ///
    /// Search text runs first as a UNION of three label scans (book titles,
    /// author names, item titles), which measured about 3x faster on the real
    /// store than per-book `EXISTS` subqueries; the other filters then apply
    /// to that candidate set. That form is a `CALL { }` subquery, which the
    /// engine reports as read-write, so the list runs it through
    /// `GraphStore.readWithSubquery` (see there).
    ///
    /// A tag filter without search text starts at the tag
    /// (`MATCH (:Tag {name: $tag})<-[:TAGGED]-(b:Book)`), about 5x faster
    /// than a per-book `EXISTS` on the real store (1.9 vs 10.3 ms for a
    /// 200-book tag). It cannot duplicate a book: Tag.name is unique and
    /// TAGGED is written with MERGE, so there is one per (book, tag). With
    /// search text the tag is an `EXISTS` condition on the search results.
    static func match(_ filter: LibraryFilter) throws -> Statement {
        var conditions: [String] = []
        var parameters: [String: any CypherValueConvertible] = [:]
        var base = "MATCH (b:Book)"
        if let status = filter.status {
            conditions.append(statusCondition(status))
            parameters["status"] = status.rawValue
        }
        if let tag = filter.tag {
            parameters["tag"] = tag
            if filter.normalizedText == nil {
                base = "MATCH (:Tag {name: $tag})<-[:TAGGED]-(b:Book)"
            } else {
                conditions.append("EXISTS { MATCH (b)-[:TAGGED]->(ft:Tag) WHERE ft.name = $tag }")
            }
        }
        if filter.unresolvedOnly {
            conditions.append("b.key STARTS WITH 'amazon:'")
        }
        if let format = filter.format {
            // App-added books have no Item; their format is Book.physical_format (phase 5).
            conditions.append("(EXISTS { MATCH (fi:Item)-[:EDITION_OF]->(b) WHERE fi.format = $format } OR b.physical_format = $format)")
            parameters["format"] = format
        }
        if let genre = filter.genre {
            conditions.append("EXISTS { MATCH (b)-[:IN_GENRE]->(fg:Genre) WHERE fg.name = $genre }")
            parameters["genre"] = genre
        }
        let whereClause = conditions.isEmpty ? "" : "\nWHERE " + conditions.joined(separator: "\n  AND ")
        guard let text = filter.normalizedText else {
            return try Statement(base + whereClause, parameters)
        }
        parameters["text"] = text
        let search = """
            CALL {
              MATCH (b:Book) WHERE toLower(b.title) CONTAINS $text RETURN b
              UNION
              MATCH (fa:Author)<-[:WRITTEN_BY]-(b:Book) WHERE toLower(fa.name) CONTAINS $text RETURN b
              UNION
              MATCH (ft:Item)-[:EDITION_OF]->(b:Book) WHERE toLower(ft.title) CONTAINS $text RETURN b
            }
            WITH b
            """
        return try Statement(search + whereClause, parameters)
    }

    /// One page of the library list: the filter's statement with the sort,
    /// the page window and the projection appended. `append` carries the
    /// filter's parameters along.
    static func page(filter: LibraryFilter, sort: LibrarySort, skip: Int, limit: Int = pageSize) throws -> Statement {
        let order = orderBy(sort)
        var statement = try match(filter)
        try statement.append(Statement("""

            \(sortKey(sort).clause)
            \(order)
            SKIP $skip LIMIT $limit
            \(summaryProjection(preferringFormat: filter.format != nil))
            \(order)
            """, ["skip": max(0, skip), "limit": max(0, limit)]))
        return statement
    }

    /// The number of books the filter matches.
    static func count(filter: LibraryFilter) throws -> Statement {
        var statement = try match(filter)
        try statement.append(Statement("\nRETURN count(b) AS count"))
        return statement
    }

    /// Format chips: each book format with the number of books that have an item in it.
    static let formatFacets = Statement("""
        MATCH (i:Item)-[:EDITION_OF]->(b:Book)
        WHERE i.format IS NOT NULL
        RETURN i.format AS name, count(DISTINCT b) AS count
        ORDER BY count DESC, name
        """)

    /// Format chips for app-added books (phase 5): `Book.physical_format`.
    /// App books never have Items, so these counts are disjoint from
    /// `formatFacets` and `GraphStore.formatFacets()` sums the two per name
    /// (one UNION statement measured 10.5 ms against 2.2 + 1.0 ms).
    static let appFormatFacets = Statement("""
        MATCH (b:Book) WHERE b.physical_format IS NOT NULL
        RETURN b.physical_format AS name, count(b) AS count
        ORDER BY count DESC, name
        """)

    /// Genre chips: each genre with its book count.
    static let genreFacets = Statement("""
        MATCH (b:Book)-[:IN_GENRE]->(g:Genre)
        RETURN g.name AS name, count(DISTINCT b) AS count
        ORDER BY count DESC, name
        """)
}

extension GraphStore {
    func bookCount() async throws -> Int {
        guard let n = try await read(Statement(LibraryQueries.bookCount)).scalar().intValue else {
            throw GraphError.missingColumn("count")
        }
        return Int(n)
    }

    /// One page (default 40) of the library, filtered and sorted.
    func libraryPage(filter: LibraryFilter = LibraryFilter(), sort: LibrarySort = .title,
                     skip: Int = 0, limit: Int = LibraryQueries.pageSize) async throws -> [BookSummary] {
        let statement = try LibraryQueries.page(filter: filter, sort: sort, skip: skip, limit: limit)
        return try await run(statement, searching: filter).rowsView.map(BookSummary.init(row:))
    }

    func libraryCount(filter: LibraryFilter = LibraryFilter()) async throws -> Int {
        try countValue(await run(LibraryQueries.count(filter: filter), searching: filter))
    }

    /// Item formats plus app books' `physical_format`, summed per name,
    /// sorted by count (descending), then name.
    func formatFacets() async throws -> [FacetValue] {
        // Both counts from one snapshot.
        let (items, app) = try await database.read { tx in
            (try facets(tx.run(LibraryQueries.formatFacets)), try facets(tx.run(LibraryQueries.appFormatFacets)))
        }
        guard !app.isEmpty else { return items }
        var counts: [String: Int] = [:]
        for facet in items + app { counts[facet.name, default: 0] += facet.count }
        return counts.map { FacetValue(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    func genreFacets() async throws -> [FacetValue] {
        try facets(await read(LibraryQueries.genreFacets))
    }

    /// A filter with search text is a `CALL { }` subquery (`LibraryQueries.match`).
    private func run(_ statement: Statement, searching filter: LibraryFilter) async throws -> QueryResult {
        filter.normalizedText == nil ? try await read(statement) : try await readWithSubquery(statement)
    }

    private func facets(_ result: QueryResult) throws -> [FacetValue] {
        try result.rowsView.map { FacetValue(name: try $0.requiredString("name"), count: try $0.requiredInt("count")) }
    }

    func countValue(_ result: QueryResult) throws -> Int {
        guard let row = result.rowsView.first, let n = row.int("count") else {
            throw GraphError.missingColumn("count")
        }
        return n
    }
}
