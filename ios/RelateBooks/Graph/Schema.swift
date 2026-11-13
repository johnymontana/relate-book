import Relate

/// Idempotent schema + the AppMeta schema_version tracker.
///
/// Every launch runs `ddl` (all `IF NOT EXISTS`, so re-running is a no-op),
/// then applies each migration whose version is above the stored
/// `schema_version`, then stores `currentVersion`.
enum Schema {
    /// Bump when a migration is appended to `migrations`.
    static let currentVersion = 2

    static let ddl: [String] = [
        "CREATE CONSTRAINT meta_key IF NOT EXISTS FOR (m:AppMeta) REQUIRE m.key IS UNIQUE",
        "CREATE CONSTRAINT tag_name IF NOT EXISTS FOR (t:Tag) REQUIRE t.name IS UNIQUE",
        "CREATE CONSTRAINT note_id IF NOT EXISTS FOR (n:Note) REQUIRE n.id IS UNIQUE",
        "CREATE INDEX book_status IF NOT EXISTS FOR (b:Book) ON (b.reading_status)",
        "CREATE POINT INDEX place_location IF NOT EXISTS FOR (p:Place) ON (p.location)",
        // Phase 4: place sheet, search and resolve look Places up by their map
        // label. DDL only (idempotent, no version bump); the geocoded books.rl
        // already carries it from wishlist-to-graph --geocode.
        "CREATE INDEX place_label IF NOT EXISTS FOR (p:Place) ON (p.geocoded_label)",
        // Version 2 (phase 3): exact flat-scan vector search over the
        // embeddings the indexer writes (384-d all-MiniLM-L6-v2, cosine).
        "CREATE VECTOR INDEX book_embedding IF NOT EXISTS FOR (b:Book) ON (b.embedding) OPTIONS {indexConfig: {`vector.dimensions`: 384, `vector.similarity_function`: 'cosine'}}",
        "CREATE VECTOR INDEX note_embedding IF NOT EXISTS FOR (n:Note) ON (n.embedding) OPTIONS {indexConfig: {`vector.dimensions`: 384, `vector.similarity_function`: 'cosine'}}",
    ]

    /// Data migrations keyed by the version they bring the store to.
    /// Version 1 is the original DDL; version 2 adds the two vector indexes
    /// (DDL only, idempotent), so neither needs a data step.
    static let migrations: [(version: Int, statements: [String])] = [
        (version: 2, statements: []),
    ]

    static let readVersion =
        "OPTIONAL MATCH (m:AppMeta {key: 'schema_version'}) RETURN m.value AS value"

    static let writeVersion = """
        MERGE (m:AppMeta {key: 'schema_version'})
        ON CREATE SET m.value = $version, m.created_on = datetime(), m.updated_on = datetime()
        ON MATCH SET m.value = $version, m.updated_on = datetime()
        RETURN m.value AS value
        """

    /// Returns the schema version the store is at afterwards.
    @discardableResult
    static func migrate(_ conn: Connection) throws -> Int {
        for statement in ddl {
            _ = try conn.query(statement)
        }
        let stored = Int(try conn.query(readVersion).scalar().intValue ?? 0)
        let pending = migrations.filter { $0.version > stored }.sorted { $0.version < $1.version }
        if stored < currentVersion {
            try conn.transaction { tx in
                for migration in pending {
                    for statement in migration.statements { _ = try tx.query(statement) }
                }
                _ = try tx.query(writeVersion, ["version": CypherValue(currentVersion)])
            }
        }
        return max(stored, currentVersion)
    }
}
