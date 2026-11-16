import Relate

/// Cypher for two-hop connections between books: `(book)-[rel]->(shared
/// node)<-[rel]-(other book)`, the same relationship type on both sides.
///
/// Three uses, one shape:
/// - `related`: neighbours of the top search hits (the fourth candidate
///   list of hybrid search);
/// - `reading`: why a book connects to books the user read, is reading or
///   rated highly;
/// - `between`: why the books in a list connect to one given book ("More
///   like this").
///
/// Rules these follow:
/// - A shared node counts by rarity: `strength / degree`, the degree being
///   the number of books on it. A node on more than `maxDegree` books is
///   skipped before it is expanded, so a subject such as "History" neither
///   dominates nor costs anything. A node on one book links nothing.
/// - Rarity is relative too: a subject, place, person or era on more than
///   `maxShare` of the library (a third) links nothing, unless it is on
///   exactly two books. Without this, on the six-book sample a subject on
///   four books counted as rare. Series, authors and awards are exempt: an
///   author of half a small library is still a real link.
/// - Catalogue noise is not a link: subjects that are machine tags
///   (`nyt:…`, `award:…=…`) or bookkeeping (`noiseSubjects`).
/// - Relationship types come from `ConnectionKind` (a fixed table); every
///   value is a parameter.
/// - The degree is counted once per shared node, not once per book that
///   uses it (`collect` the uses, count, `UNWIND` them again): fifty
///   results that share the same ninety hubs cost ninety counts, not 4,500.
///   On the scaled perf store, where every subject is on 300 to 1,200
///   books, that took `reading` for 50 keys from 161 ms to under the budget.
/// - No `CALL { }` subquery (the engine reports one as a write, and these
///   run as reads). The best link per book is `collect(...)[0]` after an
///   `ORDER BY`, as in the notes search.
enum ConnectionQueries {
    static let defaultMaxDegree = 50
    /// The weakest link worth showing as a reason. A subject weighs
    /// `1 / degree`, so by default one shared by more than ten books is a
    /// reason only through a rated book (up to twenty for a rating of 5). On
    /// a 1,811-book list, without this floor four results in five were
    /// "explained", mostly by a broad subject.
    static let defaultMinReasonWeight = 0.1

    /// The largest share of the library a linking node may be on.
    static let defaultMaxShare = 1.0 / 3

    /// Subjects that say nothing about a book (lowercased): the embedding
    /// text's stoplist plus catalogue headings for "a novel" in several
    /// languages. Hubs on a large list, noise on a small one.
    static let noiseSubjects: [String] = (BookEmbeddingText.subjectStoplist.union([
        "fiction, general", "fiction in english", "ficción", "novela", "romans, nouvelles", "roman", "literary",
        "fiction / literary", "fiction / general", "literature", "popular works", "histoire", "historia",
    ])).sorted()

    /// Keeps the shared node `t` out when it is a noise subject (binds `$noise`).
    static let notNoise =
        "NOT (t:Subject AND (t.name CONTAINS ':' OR t.name CONTAINS '=' OR toLower(t.name) IN $noise))"

    /// Keeps `t` when its `degree` links (binds `$maxDegree`, `$maxShare`; needs `total`).
    static let links = """
        degree >= 2 AND degree <= $maxDegree \
        AND (degree = 2 OR degree <= total * $maxShare OR t:Series OR t:Author OR t:Award)
        """

    /// `PART_OF|WRITTEN_BY|…`: every connection relationship type.
    static let relationshipTypes = ConnectionKind.allCases.map(\.relationship).joined(separator: "|")

    /// `CASE via WHEN 'PART_OF' THEN 4.0 … END`: a kind's strength in Cypher.
    static func strengthCase(_ variable: String) -> String {
        let arms = ConnectionKind.allCases.map { "WHEN '\($0.relationship)' THEN \($0.strength)" }.joined(separator: " ")
        return "CASE \(variable) \(arms) ELSE 0.0 END"
    }

    /// Books linked to the seed books, strongest first: `key, weight` and
    /// the strongest link (`via, name, otherKey, otherTitle, linkWeight`,
    /// the other book being the seed). A seed is never returned. A link from the n-th seed
    /// counts `1 / n`, so the neighbours of the best hit come first.
    static func related(seeds: [String], limit: Int, maxDegree: Int = defaultMaxDegree,
                        maxShare: Double = defaultMaxShare) throws -> Statement {
        try Statement("""
            MATCH (every:Book)
            WITH count(every) AS total
            UNWIND range(0, size($seeds) - 1) AS idx
            WITH total, idx, $seeds[idx] AS k
            MATCH (s:Book {key: k})-[r:\(relationshipTypes)]->(t)
            WHERE \(notNoise)
            WITH total, t, collect({idx: idx, s: s, via: type(r)}) AS uses
            WITH total, t, uses, COUNT { (t)<--(:Book) } AS degree
            WHERE \(links)
            UNWIND uses AS use
            WITH t, degree, use.idx AS idx, use.s AS s, use.via AS via
            MATCH (t)<-[r2]-(o:Book)
            WHERE type(r2) = via AND NOT o.key IN $seeds
            WITH o, s, t, via, \(strengthCase("via")) / degree / (idx + 1) AS w
            ORDER BY w DESC, s.key, t.name
            WITH o, sum(w) AS weight,
                 collect({via: via, name: t.name, otherKey: s.key, otherTitle: s.title, weight: w})[0] AS best
            RETURN o.key AS key, weight, best.via AS via, best.name AS name,
                   best.otherKey AS otherKey, best.otherTitle AS otherTitle, best.weight AS linkWeight
            ORDER BY weight DESC, key
            LIMIT $limit
            """, ["seeds": seeds, "limit": max(1, limit), "maxDegree": max(2, maxDegree), "maxShare": maxShare,
                  "noise": noiseSubjects])
    }

    /// For each of `keys`, its strongest links to books the user read, is
    /// reading or rated at least `minRating`: `key, links` (up to `perBook`
    /// maps `via, name, otherKey, otherTitle, weight, status, rating`), one
    /// per other book: two books that share three subjects are one reason,
    /// named by the strongest, and rank by everything they share. A
    /// book with no such link returns no row. A rated book counts up to
    /// twice as much as an unrated one (a rating of 5 doubles the weight).
    /// Links lighter than `minWeight` are not reasons.
    static func reading(keys: [String], perBook: Int = 1, minRating: Int = 4, minWeight: Double = defaultMinReasonWeight,
                        maxDegree: Int = defaultMaxDegree, maxShare: Double = defaultMaxShare) throws -> Statement {
        try Statement("""
            MATCH (every:Book)
            WITH count(every) AS total
            UNWIND $keys AS k
            MATCH (b:Book {key: k})-[r:\(relationshipTypes)]->(t)
            WHERE \(notNoise)
            WITH total, t, collect({b: b, via: type(r)}) AS uses
            WITH total, t, uses, COUNT { (t)<--(:Book) } AS degree
            WHERE \(links)
            UNWIND uses AS use
            WITH t, degree, use.b AS b, use.via AS via
            MATCH (t)<-[r2]-(a:Book)
            WHERE type(r2) = via AND a <> b
              AND (a.reading_status IN ['read', 'reading'] OR a.my_rating >= $minRating)
            WITH b, a, t, via, \(strengthCase("via")) / degree * (1.0 + coalesce(a.my_rating, 0) / 5.0) AS w
            WHERE w >= $minWeight
            ORDER BY w DESC, t.name
            WITH b, a, sum(w) AS shared,
                 collect({via: via, name: t.name, otherKey: a.key, otherTitle: a.title, weight: w,
                          status: coalesce(a.reading_status, 'want'), rating: a.my_rating})[0] AS best
            ORDER BY shared DESC, a.key
            WITH b, collect(best) AS links
            RETURN b.key AS key, links[0..$perBook] AS links
            """, ["keys": keys, "perBook": max(1, perBook), "minRating": minRating, "minWeight": minWeight,
                  "maxDegree": max(2, maxDegree), "maxShare": maxShare, "noise": noiseSubjects])
    }

    /// For each of `keys`, its strongest link to the book `anchor`: `key,
    /// via, name, otherKey, otherTitle, weight` (the other book being the
    /// anchor). A book that shares nothing returns no row.
    static func between(anchor: String, keys: [String], maxDegree: Int = defaultMaxDegree,
                        maxShare: Double = defaultMaxShare) throws -> Statement {
        try Statement("""
            MATCH (every:Book)
            WITH count(every) AS total
            MATCH (a:Book {key: $anchor})-[r:\(relationshipTypes)]->(t)
            WHERE \(notNoise)
            WITH total, a, t, type(r) AS via, COUNT { (t)<--(:Book) } AS degree
            WHERE \(links)
            MATCH (t)<-[r2]-(b:Book)
            WHERE type(r2) = via AND b <> a AND b.key IN $keys
            WITH b, a, t, via, \(strengthCase("via")) / degree AS w
            ORDER BY w DESC, t.name
            WITH b, collect({via: via, name: t.name, otherKey: a.key, otherTitle: a.title, weight: w})[0] AS best
            RETURN b.key AS key, best.via AS via, best.name AS name, best.otherKey AS otherKey,
                   best.otherTitle AS otherTitle, best.weight AS weight
            """, ["anchor": anchor, "keys": keys, "maxDegree": max(2, maxDegree), "maxShare": maxShare,
                  "noise": noiseSubjects])
    }
}

extension GraphStore {
    /// Graph neighbours of the seed books (hybrid search's fourth list).
    /// [] without seeds, with no query.
    func relatedCandidates(seeds: [String], limit: Int, maxDegree: Int = ConnectionQueries.defaultMaxDegree,
                           maxShare: Double = ConnectionQueries.defaultMaxShare) async throws -> [RelatedCandidate] {
        guard !seeds.isEmpty, limit > 0 else { return [] }
        return try await read(ConnectionQueries.related(seeds: seeds, limit: limit, maxDegree: maxDegree, maxShare: maxShare))
            .rowsView.compactMap { row in
                guard let key = row.string("key"),
                      let connection = BookConnection(row: row, weightColumn: "linkWeight") else { return nil }
                return RelatedCandidate(key: key, weight: row.double("weight") ?? 0, connection: connection)
            }
    }

    /// The strongest links from each book to the user's reading, by key.
    /// Books with none are absent.
    func readingConnections(keys: [String], perBook: Int = 1, minRating: Int = 4,
                            minWeight: Double = ConnectionQueries.defaultMinReasonWeight,
                            maxDegree: Int = ConnectionQueries.defaultMaxDegree,
                            maxShare: Double = ConnectionQueries.defaultMaxShare) async throws -> [String: [ReadingConnection]] {
        guard !keys.isEmpty else { return [:] }
        let statement = try ConnectionQueries.reading(keys: keys, perBook: perBook, minRating: minRating,
                                                      minWeight: minWeight, maxDegree: maxDegree, maxShare: maxShare)
        var out: [String: [ReadingConnection]] = [:]
        for row in try await read(statement).rowsView {
            guard let key = row.string("key") else { continue }
            let links = row.rows("links").compactMap(ReadingConnection.init(row:))
            if !links.isEmpty { out[key] = links }
        }
        return out
    }

    /// The strongest link from each of `keys` to `anchor`, by key.
    func connections(to anchor: String, from keys: [String], maxDegree: Int = ConnectionQueries.defaultMaxDegree,
                     maxShare: Double = ConnectionQueries.defaultMaxShare) async throws -> [String: BookConnection] {
        guard !keys.isEmpty else { return [:] }
        var out: [String: BookConnection] = [:]
        let statement = try ConnectionQueries.between(anchor: anchor, keys: keys, maxDegree: maxDegree, maxShare: maxShare)
        for row in try await read(statement).rowsView {
            if let key = row.string("key"), let connection = BookConnection(row: row) { out[key] = connection }
        }
        return out
    }
}
