import Testing
import Foundation
import Relate
@testable import RelateBooksCore

@Suite("GraphStore bootstrap")
struct GraphStoreTests {
    @Test("bootstrap copies the bundled store once, migrates it, and keeps user writes")
    func bootstrapCopiesOnce() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundled = dir.appendingPathComponent("books.rl")
        let target = dir.appendingPathComponent("Support/library.rl")
        try Fixtures.makeFixtureStore(at: bundled)

        do {
            let store = try await GraphStore.bootstrap(bundledStore: bundled, storeURL: target)
            #expect(try await store.bookCount() == 3)
            #expect(try await store.query(Schema.readVersion).scalar().intValue == Int64(Schema.currentVersion))
            try await store.query("CREATE (:AppMeta {key: 'marker', value: 'kept'})")
            try await store.checkpoint()
        }
        #expect(FileManager.default.fileExists(atPath: target.path))

        // Second launch: the existing copy is opened, not replaced.
        let reopened = try await GraphStore.bootstrap(bundledStore: bundled, storeURL: target)
        let marker = try await reopened.query(
            "MATCH (m:AppMeta {key: 'marker'}) RETURN m.value AS v").scalar()
        #expect(marker.stringValue == "kept")
        #expect(try await reopened.bookCount() == 3)
    }

    @Test("a missing bundled store throws bundledStoreMissing")
    func missingBundle() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: GraphError.bundledStoreMissing) {
            _ = try await GraphStore.bootstrap(
                bundledStore: dir.appendingPathComponent("nope.rl"),
                storeURL: dir.appendingPathComponent("library.rl"))
        }
    }

    @Test("bootstrap leaves only the store beside the seed, owner-writable, and no temporary copy")
    func provisionedCopy() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundled = dir.appendingPathComponent("books.rl")
        let support = dir.appendingPathComponent("Support", isDirectory: true)
        let target = support.appendingPathComponent("library.rl")
        try Fixtures.makeFixtureStore(at: bundled)
        // A read-only seed, as in an app bundle.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: bundled.path)

        do {
            let store = try await GraphStore.bootstrap(bundledStore: bundled, storeURL: target)
            try await store.query("CREATE (:AppMeta {key: 'marker'})")
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: support.path)
            .filter { $0.hasSuffix(".provisioning") || $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test("a read never keeps a write, and a write statement sent as a read is refused")
    func readsAreReadOnly() async throws {
        let store = try await GraphStore.inMemory()
        try await Fixtures.insertBooks(into: store)
        await #expect(throws: RelateError.self) {
            _ = try await store.read(Statement("MATCH (b:Book) SET b.title = 'changed' RETURN count(b) AS c"))
        }
        #expect(try await store.countOf("MATCH (b:Book) WHERE b.title = 'changed' RETURN count(b)") == 0)
        #expect(try await store.bookCount() == 3)
    }

    @Test("reads run while a write transaction is open, and see the write only after it commits")
    func readsDoNotWaitForAWrite() async throws {
        let store = try await GraphStore.inMemory()
        try await Fixtures.insertBooks(into: store)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let write = Task {
            try await store.database.write { tx in
                try tx.run("CREATE (:Book {key: '/works/OL4W', title: 'Quince Jam'})")
                entered.signal()
                release.wait()
            }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { entered.wait(); continuation.resume() }
        }
        #expect(try await store.bookCount() == 3)
        release.signal()
        try await write.value
        #expect(try await store.bookCount() == 4)
    }

    @Test("a runtime statement error leaves the connection usable")
    func statementErrorKeepsConnection() async throws {
        let store = try await GraphStore.inMemory()
        await #expect(throws: RelateError.self) {
            _ = try await store.query("RETURN 1/0 AS x")
        }
        #expect(try await store.query("RETURN 41 + 1 AS x").scalar().intValue == 42)
    }
}
