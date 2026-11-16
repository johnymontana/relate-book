import Relate

/// The schema this build expects, as a Relate `Migrator`.
///
/// Every launch runs `ddl` (all `IF NOT EXISTS`, so re-running is a no-op),
/// then each registered step whose version is above the one the store
/// records. A step commits together with the record of its version.
///
/// The version is `(:AppMeta {key: 'schema_version'}).version`. Builds from
/// before the app used `Migrator` kept it in `value`; `adoptLegacyVersion`
/// moves it across before the migrator reads it.
enum Schema {
    /// The version `migrate` leaves a store at. Bump it by registering a
    /// step in `migrator`.
    static var currentVersion: Int { migrator.latestVersion }

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

    /// Version 1 is the original DDL and version 2 added the two vector
    /// indexes. Both are DDL only, so the one registered step has no data
    /// statements: it records that the store is at version 2.
    static let migrator: Migrator = {
        var migrator = Migrator(versionLabel: "AppMeta")
        migrator.schema = ddl.map { Statement($0) }
        migrator.register(version: 2, [])
        return migrator
    }()

    /// The stored version, or null for a store never migrated.
    static let readVersion =
        "OPTIONAL MATCH (m:AppMeta {key: 'schema_version'}) RETURN m.version AS version"

    /// Moves a version kept in `value` (builds before the migrator) to
    /// `version`. A no-op on a fresh store and on one already moved.
    static let adoptLegacyVersion = Statement("""
        MATCH (m:AppMeta {key: 'schema_version'})
        WHERE m.version IS NULL AND m.value IS NOT NULL
        SET m.version = m.value
        REMOVE m.value
        """)

    /// Returns the schema version the store is at afterwards.
    @discardableResult
    static func migrate(_ database: Database) async throws -> Int {
        try await database.write(adoptLegacyVersion)
        return try await migrator.migrate(database)
    }
}
