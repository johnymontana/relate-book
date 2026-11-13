import Foundation
import Relate
@testable import RelateBooksCore

/// A perf-scale library built from the bundled sample store (6 books).
///
/// The bundled `books.rl` is a small public sample, so the perf budgets
/// (PerfTests, ImportRealStoreTests) run on a temp copy grown to roughly the
/// size of a real wishlist export: `copies` × every Book, Author and Item
/// (6 × 300 = 1,800 books, 2,400 authors, 1,800 editions), each clone keyed
/// `<original>~<k>` with titles suffixed " <k>". Subjects, genres, series,
/// awards, eras, people, publishers and countries are shared, so term pages
/// grow the way they do on real data ("Fiction" has 1,200 books). The first
/// `placeCopies` copies also clone every Place (label suffixed " <k>", the
/// point shifted deterministically in longitude and latitude), giving the map
/// hundreds of distinct located labels; later copies link the original
/// places. Copy 0 is the untouched sample, so sanity checks run on real data.
///
/// Clones carry no ISBNs (an ISBN lookup must find the one real edition) and
/// wishlist positions continue after the originals. Only CREATE and SET, no
/// DELETE, each statement auto-committed (LABS-1188 does not apply).
/// Verified with the relate 1.0.1 CLI on a store copy: about 3 s of engine
/// time for 300 copies.
enum ScaledLibrary {
    static let copies = 300
    static let placeCopies = 30
    static var bookCount: Int { 6 * copies }

    static let statements: [String] = [
        // Nodes.
        """
        MATCH (b:Book) WITH collect(b) AS books UNWIND range(1, $copies - 1) AS k UNWIND books AS b
        CREATE (c:Book) SET c = properties(b), c.key = b.key + '~' + toString(k), c.title = b.title + ' ' + toString(k), c.scale_copy = k
        """,
        """
        MATCH (a:Author) WITH collect(a) AS authors UNWIND range(1, $copies - 1) AS k UNWIND authors AS a
        CREATE (c:Author) SET c = properties(a), c.key = a.key + '~' + toString(k), c.scale_copy = k
        """,
        """
        MATCH (i:Item) WHERE i.scale_copy IS NULL WITH collect(i) AS items UNWIND range(1, $copies - 1) AS k UNWIND items AS i
        CREATE (c:Item) SET c = properties(i), c.asin = i.asin + '~' + toString(k), c.title = i.title + ' ' + toString(k),
            c.isbn13 = null, c.isbn10 = null, c.scale_copy = k
        """,
        "MATCH (c:Item) WHERE c.scale_copy IS NOT NULL MATCH (:Item:Edition {asin: split(c.asin, '~')[0]}) SET c:Edition",
        """
        MATCH (p:Place) WITH collect(p) AS places UNWIND range(1, $placeCopies - 1) AS k UNWIND places AS p
        CREATE (c:Place) SET c = properties(p), c.name = p.name + ' ~' + toString(k), c.scale_copy = k,
            c.geocoded_label = CASE WHEN p.geocoded_label IS NULL THEN null ELSE p.geocoded_label + ' ' + toString(k) END
        """,
        """
        MATCH (c:Place) WHERE c.scale_copy IS NOT NULL AND c.location IS NOT NULL
        WITH c, c.location.latitude + ((c.scale_copy % 9) - 4) * 0.7 AS lat0,
             ((c.location.longitude + 180.0 + c.scale_copy * 12.3) % 360.0) - 180.0 AS lon
        WITH c, CASE WHEN lat0 > 85.0 THEN 85.0 WHEN lat0 < -85.0 THEN -85.0 ELSE lat0 END AS lat, lon
        SET c.location = point({latitude: lat, longitude: lon}), c.geo_lat = lat, c.geo_lon = lon
        """,
        // Book relationships.
        """
        MATCH (c:Book) WHERE c.scale_copy IS NOT NULL MATCH (:Book {key: split(c.key, '~')[0]})-[r:WRITTEN_BY]->(a:Author)
        MATCH (a2:Author {key: a.key + '~' + toString(c.scale_copy)}) CREATE (c)-[r2:WRITTEN_BY]->(a2) SET r2 = properties(r)
        """,
        "MATCH (c:Book) WHERE c.scale_copy IS NOT NULL MATCH (:Book {key: split(c.key, '~')[0]})-[:ABOUT]->(t) CREATE (c)-[:ABOUT]->(t)",
        "MATCH (c:Book) WHERE c.scale_copy IS NOT NULL MATCH (:Book {key: split(c.key, '~')[0]})-[:FEATURES]->(t) CREATE (c)-[:FEATURES]->(t)",
        "MATCH (c:Book) WHERE c.scale_copy IS NOT NULL MATCH (:Book {key: split(c.key, '~')[0]})-[:SET_DURING]->(t) CREATE (c)-[:SET_DURING]->(t)",
        "MATCH (c:Book) WHERE c.scale_copy IS NOT NULL MATCH (:Book {key: split(c.key, '~')[0]})-[:IN_GENRE]->(t) CREATE (c)-[:IN_GENRE]->(t)",
        """
        MATCH (c:Book) WHERE c.scale_copy IS NOT NULL MATCH (:Book {key: split(c.key, '~')[0]})-[r:PART_OF]->(t)
        CREATE (c)-[r2:PART_OF]->(t) SET r2 = properties(r)
        """,
        """
        MATCH (c:Book) WHERE c.scale_copy IS NOT NULL MATCH (:Book {key: split(c.key, '~')[0]})-[r:WON]->(t)
        CREATE (c)-[r2:WON]->(t) SET r2 = properties(r)
        """,
        """
        MATCH (c:Book) WHERE c.scale_copy IS NOT NULL MATCH (:Book {key: split(c.key, '~')[0]})-[:SET_IN]->(p:Place)
        OPTIONAL MATCH (p2:Place {name: p.name + ' ~' + toString(c.scale_copy)})
        WITH c, coalesce(p2, p) AS x CREATE (c)-[:SET_IN]->(x)
        """,
        // Author relationships.
        """
        MATCH (c:Author) WHERE c.scale_copy IS NOT NULL MATCH (:Author {key: split(c.key, '~')[0]})-[:BORN_IN]->(p:Place)
        OPTIONAL MATCH (p2:Place {name: p.name + ' ~' + toString(c.scale_copy)})
        WITH c, coalesce(p2, p) AS x CREATE (c)-[:BORN_IN]->(x)
        """,
        "MATCH (c:Author) WHERE c.scale_copy IS NOT NULL MATCH (:Author {key: split(c.key, '~')[0]})-[:CITIZEN_OF]->(t) CREATE (c)-[:CITIZEN_OF]->(t)",
        """
        MATCH (c:Author) WHERE c.scale_copy IS NOT NULL MATCH (:Author {key: split(c.key, '~')[0]})-[r:WON]->(t)
        CREATE (c)-[r2:WON]->(t) SET r2 = properties(r)
        """,
        // Item relationships.
        """
        MATCH (c:Item) WHERE c.scale_copy IS NOT NULL MATCH (:Item {asin: split(c.asin, '~')[0]})-[:EDITION_OF]->(b:Book)
        MATCH (b2:Book {key: b.key + '~' + toString(c.scale_copy)}) CREATE (c)-[:EDITION_OF]->(b2)
        """,
        "MATCH (c:Item) WHERE c.scale_copy IS NOT NULL MATCH (:Item {asin: split(c.asin, '~')[0]})-[:PUBLISHED_BY]->(t) CREATE (c)-[:PUBLISHED_BY]->(t)",
        """
        MATCH (w:Wishlist)-[r:CONTAINS]->(:Item) WITH w, count(r) AS n
        MATCH (c:Item) WHERE c.scale_copy IS NOT NULL MATCH (w)-[r:CONTAINS]->(:Item {asin: split(c.asin, '~')[0]})
        CREATE (w)-[r2:CONTAINS]->(c)
        SET r2 = properties(r), r2.position = r.position + c.scale_copy * n, r2.item_id = r.item_id + '~' + toString(c.scale_copy)
        """,
    ]

    /// Grows `store` (a temp copy) in place.
    static func scale(_ store: GraphStore, copies: Int = copies, placeCopies: Int = placeCopies) async throws {
        let params: [String: CypherValue] = ["copies": CypherValue(copies), "placeCopies": CypherValue(placeCopies)]
        for cypher in statements {
            try await store.query(cypher, params)
        }
    }

    /// Bootstraps a temp copy of the bundled sample at `url` and scales it.
    static func make(at url: URL) async throws -> GraphStore {
        let store = try await GraphStore.bootstrap(bundledStore: PerfTests.bundledStore, storeURL: url)
        try await scale(store)
        return store
    }
}
