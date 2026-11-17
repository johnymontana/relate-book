import Foundation
import Relate

/// The app's handle on its graph: one Relate `Database`, opened once and shared.
///
/// The database owns the connections (one writer, a small pool of readers,
/// each on its own queue), so there is no connection for the app to hold or
/// replace. A read runs in a transaction that is rolled back and sees one
/// snapshot; a write is one transaction on the single writer. Reads do not
/// wait for a write in progress, so a list stays responsive while the
/// embedding indexer writes. A connection the engine poisoned (an error at
/// stage `.internal`) is discarded by the pool and replaced on the next use;
/// the failed call's error is rethrown and nothing is retried.
///
/// Query files extend this type with one method per query. Views are
/// `@MainActor` and `await` them.
struct GraphStore: Sendable {
    /// File name of the writable store in Application Support.
    static let storeFileName = "library.rl"

    let database: Database

    /// Wraps an already-open database and starts logging its statements.
    /// Does not migrate.
    init(database: Database) {
        self.database = database
        database.setTraceHandler(GraphStore.log)
    }

    /// A throwaway in-memory store with the schema applied (tests, previews).
    static func inMemory() async throws -> GraphStore {
        let store = GraphStore(database: try Database.inMemory())
        try await store.migrate()
        return store
    }

    /// `Application Support/library.rl`. Creates Application Support if
    /// needed; does not create the store file.
    static func persistentStoreURL() throws -> URL {
        try Database.defaultStoreURL(named: storeFileName)
    }

    /// Opens the user's store, provisioning it from `bundledStore` on first
    /// launch, then migrates and checkpoints.
    ///
    /// The bundled file is never opened in place (app bundles are read-only
    /// and a `.rl` store writes beside itself). `Database.provision` copies
    /// it only when nothing is at the target, through a temporary name, so an
    /// interrupted first launch never leaves a half-copied store.
    static func bootstrap(bundledStore: URL, storeURL: URL? = nil) async throws -> GraphStore {
        let target = try storeURL ?? persistentStoreURL()
        let fm = FileManager.default
        if !fm.fileExists(atPath: target.path), !fm.fileExists(atPath: bundledStore.path) {
            throw GraphError.bundledStoreMissing
        }
        try Database.provision(at: target, from: bundledStore)
        let store = GraphStore(database: try Database(url: target))
        try await store.migrate()
        try await store.checkpoint()
        return store
    }

    /// Applies the idempotent schema and any pending migration; returns the
    /// schema version.
    @discardableResult
    func migrate() async throws -> Int {
        try await Schema.migrate(database)
    }

    /// Folds the WAL into the store file, on the writer's queue, between writes.
    func checkpoint() async throws {
        try await database.checkpointInBackground()
    }

    /// Runs one statement as a read. A statement that writes is refused.
    func read(_ statement: Statement) async throws -> QueryResult {
        try await database.read(statement)
    }

    /// Runs a statement that only reads but contains a `CALL { }` subquery.
    ///
    /// The engine (checked on 1.1.0; LABS-1761) reports any statement with a
    /// CALL subquery as read-write, whatever the subquery does, and a managed
    /// read refuses a statement that is not a read. Until the engine tells the
    /// two apart, such a statement runs as a transaction on the writer: it
    /// commits nothing, but it waits its turn behind a write in progress.
    /// The app has two: the library's text search and the ISBN lookup.
    func readWithSubquery(_ statement: Statement) async throws -> QueryResult {
        try await database.write(statement)
    }

    /// Runs one statement as a write transaction.
    @discardableResult
    func write(_ statement: Statement) async throws -> QueryResult {
        try await database.write(statement)
    }

    /// Runs `statements` in one write transaction: all commit or none do.
    ///
    /// Relate 1.0.1 and 1.1.0 (LABS-1188, still open): never
    /// delete, inside one transaction, a node created earlier in that same
    /// transaction. The engine panics ("update counters are non-negative")
    /// and poisons the connection. Deleting nodes that existed before the
    /// transaction began is fine.
    @discardableResult
    func write(_ statements: [Statement]) async throws -> [QueryResult] {
        try await database.write(statements)
    }

    /// Ad-hoc Cypher text, on the writer so it may read or write (tests and
    /// tools; the app's own queries are `Statement`s in `Graph/Queries`).
    @discardableResult
    func query(_ cypher: String, _ parameters: [String: CypherValue] = [:]) async throws -> QueryResult {
        try await database.write(Statement(cypher, parameters))
    }

    /// One line per statement on the `query` channel, from the database's
    /// trace handler: every statement on every connection, the migrator's and
    /// a transaction's included. A trace carries parameter names, not values.
    /// Its statement text and its error can quote a literal, so both are
    /// logged private.
    private static let log: @Sendable (QueryTrace) -> Void = { trace in
        let text = String(trace.statement.prefix(160))
        if let error = trace.error {
            Log.query.error("failed in \(trace.wallMs, format: .fixed(precision: 2)) ms: \(error.localizedDescription, privacy: .private) [\(text, privacy: .private)]")
        } else {
            Log.query.debug("\(trace.rowCount) rows in \(trace.elapsedMs, format: .fixed(precision: 2)) ms (\(trace.wallMs, format: .fixed(precision: 2)) ms wall): \(text, privacy: .private)")
        }
    }
}
