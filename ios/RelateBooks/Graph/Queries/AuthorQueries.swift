import Relate

/// Cypher for the Author page. Birth and death dates come as a pair from
/// one source (Open Library free text, or Wikidata ISO dates when only
/// Wikidata knows the death), so a lifespan never mixes the two.
enum AuthorQueries {
    static func detail(key: String) throws -> Statement {
        try Statement("""
            MATCH (a:Author {key: $key})
            RETURN a.key AS key, a.name AS name, a.url AS url, a.bio AS bio,
                   CASE WHEN a.death_date IS NULL AND a.wikidata_death_date IS NOT NULL
                        THEN coalesce(a.wikidata_birth_date, a.birth_date)
                        ELSE coalesce(a.birth_date, a.wikidata_birth_date) END AS birthDate,
                   coalesce(a.death_date, a.wikidata_death_date) AS deathDate,
                   a.photo_url AS photoURL, a.image_url AS imageURL,
                   a.wikipedia_url AS wikipediaURL, a.wikidata_url AS wikidataURL,
                   a.occupations AS occupations,
                   [(a)-[:BORN_IN]->(p:Place) | p.name] AS bornIn,
                   [(a)-[:CITIZEN_OF]->(c:Country) | c.name] AS citizenOf,
                   [(a)-[r:WON]->(w:Award) | {name: w.name, year: r.year}] AS awards,
                   size([(a)<-[:WRITTEN_BY]-(b:Book) | b]) AS bookCount
            """, ["key": key])
    }

    /// The author's books on the list, newest first.
    static func books(key: String) throws -> Statement {
        try Statement("""
            MATCH (b:Book)-[:WRITTEN_BY]->(:Author {key: $key})
            WITH DISTINCT b
            WITH b, b.first_publish_year AS sortKey
            \(LibraryQueries.summaryProjection())
            ORDER BY sortKey IS NULL, sortKey DESC, toLower(coalesce(b.title, b.key)), b.key
            """, ["key": key])
    }
}

extension GraphStore {
    func authorDetail(key: String) async throws -> AuthorDetail? {
        try await read(AuthorQueries.detail(key: key)).rowsView.first.map(AuthorDetail.init(row:))
    }

    func authorBooks(key: String) async throws -> [BookSummary] {
        try await read(AuthorQueries.books(key: key)).rowsView.map(BookSummary.init(row:))
    }
}
