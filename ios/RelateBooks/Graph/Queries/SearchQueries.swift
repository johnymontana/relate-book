import Relate

/// One `book_text` fulltext hit with the texts the coverage gate reads.
struct BookTextHit: Sendable, Equatable {
    let key: String
    let score: Double
    let title: String?
    let description: String?
    let firstSentence: String?
}

/// One `item_text` fulltext hit, mapped to its Book.
struct ItemTextHit: Sendable, Equatable {
    let key: String
    let score: Double
    let bookTitle: String?
    let itemTitle: String?
    let byline: String?
}

/// Cypher for hybrid search and "More like this" (plan §3.4, D9, D11).
///
/// Relate rules these follow (written on 0.16.1, rechecked on 1.0.1):
/// - `SCORE AS score` after SEARCH (mandatory in 0.16.1, optional in 1.0.1;
///   every query needs the score anyway); filters go in a later
///   MATCH / WHERE, after the search.
/// - The vector SCORE is (1 + cosine) / 2; Swift converts back.
/// - `$q` is a typed FLOAT32 vector, never wrapped in vector() (V3).
/// - No pattern comprehension in the RETURN right after a fulltext SEARCH:
///   it costs about 4 ms per row (V6).
/// - No COMBINE (preview-gated); fusion is RRF in Swift.
enum SearchQueries {
    static func semantic(vector: [Float], limit: Int) -> Statement {
        Statement("""
            MATCH (b:Book)
            SEARCH b IN (VECTOR INDEX book_embedding FOR $q LIMIT $limit) SCORE AS score
            RETURN b.key AS key, score
            ORDER BY score DESC, key
            """, ["q": EmbeddingVector.cypherValue(vector), "limit": CypherValue(max(1, limit))])
    }

    static func bookText(_ query: KeywordQuery, limit: Int) -> Statement {
        Statement("""
            MATCH (b:Book)
            SEARCH b IN (FULLTEXT INDEX book_text FOR $text LIMIT $limit) SCORE AS score
            RETURN b.key AS key, score, b.title AS title, b.description AS description, b.first_sentence AS firstSentence
            ORDER BY score DESC, key
            """, ["text": .string(query.text), "limit": CypherValue(max(1, limit))])
    }

    static func itemText(_ query: KeywordQuery, limit: Int) -> Statement {
        Statement("""
            MATCH (i:Item)
            SEARCH i IN (FULLTEXT INDEX item_text FOR $text LIMIT $limit) SCORE AS score
            MATCH (i)-[:EDITION_OF]->(b:Book)
            RETURN b.key AS key, score, b.title AS bookTitle, i.title AS itemTitle, i.byline AS byline
            ORDER BY score DESC, key
            """, ["text": .string(query.text), "limit": CypherValue(max(1, limit))])
    }

    /// The best-matching note per Book.
    static func notes(vector: [Float], limit: Int) -> Statement {
        Statement("""
            MATCH (n:Note)
            SEARCH n IN (VECTOR INDEX note_embedding FOR $q LIMIT $limit) SCORE AS score
            MATCH (b:Book)-[:HAS_NOTE]->(n)
            WITH b, n, score ORDER BY score DESC
            WITH b, collect({id: n.id, text: n.text, score: score})[0] AS best
            RETURN b.key AS key, best.score AS score, best.id AS noteID, best.text AS noteText
            ORDER BY score DESC, key
            """, ["q": EmbeddingVector.cypherValue(vector), "limit": CypherValue(max(1, limit))])
    }

    /// `BookSummary` rows for fused keys, in key order, with only the active
    /// filters; at most `limit` rows.
    static func hydrate(keys: [String], filter: SearchFilter, limit: Int) -> Statement {
        var conditions: [String] = []
        var parameters: [String: CypherValue] = [
            "keys": .list(keys.map { .string($0) }),
            "limit": CypherValue(max(0, limit)),
        ]
        if let status = filter.status {
            conditions.append(LibraryQueries.statusCondition(status))
            parameters["status"] = .string(status.rawValue)
        }
        if let tag = filter.tag {
            conditions.append("EXISTS { MATCH (b)-[:TAGGED]->(ft:Tag) WHERE ft.name = $tag }")
            parameters["tag"] = .string(tag)
        }
        let whereClause = conditions.isEmpty ? "" : "\nWHERE " + conditions.joined(separator: " AND ")
        return Statement("""
            UNWIND range(0, size($keys) - 1) AS idx
            WITH idx, $keys[idx] AS k
            MATCH (b:Book {key: k})\(whereClause)
            WITH b, idx AS sortKey
            ORDER BY sortKey
            LIMIT $limit
            \(LibraryQueries.summaryProjection())
            ORDER BY sortKey
            """, parameters)
    }

    /// The nearest books to a book's own stored vector, excluding it (V5).
    /// 0 rows when the book is missing or not embedded yet.
    static func moreLikeThis(key: String, limit: Int = 10) -> Statement {
        Statement("""
            MATCH (s:Book {key: $key})
            WITH s, s.embedding AS q
            MATCH (b:Book)
            SEARCH b IN (VECTOR INDEX book_embedding FOR q LIMIT $probe) SCORE AS score
            WITH s, b, score WHERE b <> s
            WITH b, score ORDER BY score DESC, b.key LIMIT $limit
            WITH b, score AS sortKey
            \(LibraryQueries.summaryProjection())
            ORDER BY sortKey DESC, key
            """, ["key": .string(key), "probe": CypherValue(max(1, limit) + 1), "limit": CypherValue(max(1, limit))])
    }
}

extension GraphStore {
    func semanticCandidates(vector: [Float], limit: Int) throws -> [RankFusion.SemanticCandidate] {
        try run(SearchQueries.semantic(vector: vector, limit: limit), label: "semanticSearch").rowsView.compactMap { row in
            guard let key = row.string("key"), let score = row.double("score") else { return nil }
            return RankFusion.SemanticCandidate(key: key, cosine: 2 * score - 1)
        }
    }

    func bookTextHits(_ query: KeywordQuery, limit: Int) throws -> [BookTextHit] {
        try run(SearchQueries.bookText(query, limit: limit), label: "bookTextSearch").rowsView.compactMap { row in
            guard let key = row.string("key") else { return nil }
            return BookTextHit(key: key, score: row.double("score") ?? 0, title: row.string("title"),
                               description: row.string("description"), firstSentence: row.string("firstSentence"))
        }
    }

    func itemTextHits(_ query: KeywordQuery, limit: Int) throws -> [ItemTextHit] {
        try run(SearchQueries.itemText(query, limit: limit), label: "itemTextSearch").rowsView.compactMap { row in
            guard let key = row.string("key") else { return nil }
            return ItemTextHit(key: key, score: row.double("score") ?? 0, bookTitle: row.string("bookTitle"),
                               itemTitle: row.string("itemTitle"), byline: row.string("byline"))
        }
    }

    func noteCandidates(vector: [Float], limit: Int, snippetLength: Int = 160) throws -> [RankFusion.NoteCandidate] {
        try run(SearchQueries.notes(vector: vector, limit: limit), label: "noteSearch").rowsView.compactMap { row in
            guard let key = row.string("key"), let score = row.double("score"), let id = row.string("noteID") else { return nil }
            let text = row.string("noteText") ?? ""
            return RankFusion.NoteCandidate(key: key, cosine: 2 * score - 1, noteID: id,
                                            snippet: String(text.prefix(snippetLength)))
        }
    }

    func hydrateSearch(keys: [String], filter: SearchFilter = SearchFilter(), limit: Int) throws -> [BookSummary] {
        guard !keys.isEmpty, limit > 0 else { return [] }
        return try run(SearchQueries.hydrate(keys: keys, filter: filter, limit: limit), label: "hydrateSearch")
            .rowsView.map(BookSummary.init(row:))
    }

    func moreLikeThis(key: String, limit: Int = 10) throws -> [BookSummary] {
        try run(SearchQueries.moreLikeThis(key: key, limit: limit), label: "moreLikeThis")
            .rowsView.map(BookSummary.init(row:))
    }
}
