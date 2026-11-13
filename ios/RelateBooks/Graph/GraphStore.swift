import Foundation
import Relate

/// The single owner of the app's Relate `Connection`.
///
/// `Connection` is not `Sendable`; keeping it private to this actor lets
/// Swift 6 prove no other isolation domain touches it. Views are
/// `@MainActor` and `await` the actor's methods.
actor GraphStore {
    /// File name of the writable store in Application Support.
    static let storeFileName = "library.rl"

    /// Replaced when the engine reports a poisoned handle (stage `.internal`).
    private var conn: Connection
    nonisolated let database: Database

    /// Connects to an already-open database. Does not migrate.
    init(database: Database) throws {
        self.database = database
        self.conn = try database.connect()
    }

    /// A throwaway in-memory store with the schema applied (tests, previews).
    static func inMemory() async throws -> GraphStore {
        let store = try GraphStore(database: Database.inMemory())
        try await store.migrate()
        return store
    }

    /// `Application Support/library.rl`. Creates Application Support if
    /// needed; does not create the store file.
    static func persistentStoreURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return base.appendingPathComponent(storeFileName, isDirectory: false)
    }

    /// Opens the user's store, provisioning it from `bundledStore` on first
    /// launch, then migrates and checkpoints.
    ///
    /// - The bundled file is never opened in place (app bundles are
    ///   read-only and a `.rl` bundle writes its WAL into the same file).
    /// - The copy goes to a temp name and is moved into place, so an
    ///   interrupted first launch never leaves a half-copied store.
    static func bootstrap(bundledStore: URL, storeURL: URL? = nil) async throws -> GraphStore {
        let target = try storeURL ?? persistentStoreURL()
        try provision(from: bundledStore, to: target)
        let store = try GraphStore(database: Database(path: target.path))
        try await store.migrate()
        try await store.checkpoint()
        return store
    }

    /// Copies `source` to `target` when `target` does not exist yet.
    /// Returns true when it copied.
    @discardableResult
    static func provision(from source: URL, to target: URL) throws -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { return false }
        guard fm.fileExists(atPath: source.path) else { throw GraphError.bundledStoreMissing }
        let directory = target.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        removeStaleTempCopies(of: target)
        let temp = directory.appendingPathComponent(tempPrefix(for: target) + UUID().uuidString + ".tmp")
        do {
            try fm.copyItem(at: source, to: temp)
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
            #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
            #endif
            try fm.setAttributes(attributes, ofItemAtPath: temp.path)
            try fm.moveItem(at: temp, to: target)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        return true
    }

    /// `.library.rl.` for target `library.rl`; temp copies are `<prefix><UUID>.tmp`.
    static func tempPrefix(for target: URL) -> String {
        ".\(target.lastPathComponent)."
    }

    /// Deletes temp copies an interrupted earlier provision left behind.
    static func removeStaleTempCopies(of target: URL) {
        let fm = FileManager.default
        let directory = target.deletingLastPathComponent()
        let prefix = tempPrefix(for: target)
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".tmp") {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Applies idempotent schema and migrations; returns the schema version.
    @discardableResult
    func migrate() throws -> Int {
        try Schema.migrate(conn)
    }

    /// Writes a checkpoint and truncates the WAL.
    func checkpoint() throws {
        try database.checkpoint()
    }

    /// The one entry point every query file uses.
    ///
    /// A `.engine` error with stage `.internal` means the handle is poisoned
    /// (SDK spec, Errors): the error is rethrown, not retried, and the
    /// connection is replaced so the next call works again.
    @discardableResult
    func query(_ cypher: String, _ parameters: [String: CypherValue] = [:]) throws -> QueryResult {
        do {
            return try conn.query(cypher, parameters)
        } catch let RelateError.engine(engineError) where engineError.stage == .internal {
            Log.store.error("engine reported an internal error; reopening the connection: \(engineError.message, privacy: .public)")
            if let fresh = try? database.connect() {
                conn = fresh
            }
            throw RelateError.engine(engineError)
        }
    }

    /// Runs `statements` atomically (`Connection.transaction`): all commit or
    /// none do. Same poisoned-handle rule as `query`.
    ///
    /// Relate 0.16.1 and 1.0.1 (LABS-1188, still open): never delete,
    /// inside one transaction, a node created earlier in that same
    /// transaction. The engine panics ("update counters
    /// are non-negative") and poisons the handle. Deleting nodes that existed
    /// before the transaction began is fine.
    @discardableResult
    func transaction(_ statements: [Statement], label: String = "transaction") throws -> [QueryResult] {
        do {
            let results = try conn.transaction { tx in
                try statements.map { try tx.query($0.cypher, $0.parameters) }
            }
            Log.query.debug("\(label, privacy: .public): \(statements.count) statements committed")
            return results
        } catch let RelateError.engine(engineError) where engineError.stage == .internal {
            Log.store.error("engine internal error in transaction; reopening the connection: \(engineError.message, privacy: .public)")
            if let fresh = try? database.connect() {
                conn = fresh
            }
            throw RelateError.engine(engineError)
        }
    }
}
