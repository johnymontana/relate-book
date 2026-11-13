import Relate

/// Cypher for the generic term page (subject, genre, series, place, person,
/// era, publisher, award, country). Labels and relationship types come from
/// `TermKind` constants; the term name is always the `$name` parameter.
enum TermQueries {
    /// Series pages sort by the stored series position ("4"); others by title.
    static func sortKey(_ kind: TermKind) -> String {
        switch kind {
        case .series:
            "WITH b, [(b)-[r:PART_OF]->(:Series {name: $name}) | toFloat(r.position)][0] AS sortKey"
        default:
            "WITH b, toLower(coalesce(b.title, b.key)) AS sortKey"
        }
    }

    static let order = "ORDER BY sortKey IS NULL, sortKey, toLower(coalesce(b.title, b.key)), b.key"

    static func books(_ kind: TermKind, name: String, skip: Int, limit: Int = LibraryQueries.pageSize) -> Statement {
        Statement("""
            MATCH \(kind.bookPattern)
            WITH DISTINCT b
            \(sortKey(kind))
            \(order)
            SKIP $skip LIMIT $limit
            \(LibraryQueries.summaryProjection())
            \(order)
            """, ["name": .string(name), "skip": CypherValue(max(0, skip)), "limit": CypherValue(max(0, limit))])
    }

    static func summary(_ kind: TermKind, name: String) -> Statement {
        let authors = kind.authorPattern.map { "COUNT { MATCH \($0) }" } ?? "0"
        return Statement("""
            RETURN COUNT { MATCH \(kind.bookPattern) RETURN DISTINCT b } AS bookCount,
                   \(authors) AS authorCount
            """, ["name": .string(name)])
    }

    /// Authors linked to the term (place: born there; country: citizens; award: winners).
    static func authors(_ kind: TermKind, name: String) -> Statement? {
        guard let pattern = kind.authorPattern else { return nil }
        return Statement("""
            MATCH \(pattern)
            WITH DISTINCT a
            RETURN a.key AS key, a.name AS name, COUNT { MATCH (a)<-[:WRITTEN_BY]-(:Book) } AS bookCount
            ORDER BY bookCount DESC, toLower(a.name), a.key
            """, ["name": .string(name)])
    }
}

extension GraphStore {
    func termBooks(_ kind: TermKind, name: String, skip: Int = 0, limit: Int = LibraryQueries.pageSize) throws -> [BookSummary] {
        try run(TermQueries.books(kind, name: name, skip: skip, limit: limit), label: "termBooks")
            .rowsView.map(BookSummary.init(row:))
    }

    func termSummary(_ kind: TermKind, name: String) throws -> TermSummary {
        let row = try run(TermQueries.summary(kind, name: name), label: "termSummary").rowsView.first
        return TermSummary(kind: kind, name: name, bookCount: row?.int("bookCount") ?? 0,
                           authorCount: row?.int("authorCount") ?? 0)
    }

    func termBookCount(_ kind: TermKind, name: String) throws -> Int {
        try termSummary(kind, name: name).bookCount
    }

    func termAuthors(_ kind: TermKind, name: String) throws -> [AuthorSummary] {
        guard let statement = TermQueries.authors(kind, name: name) else { return [] }
        return try run(statement, label: "termAuthors").rowsView.map(AuthorSummary.init(row:))
    }
}
