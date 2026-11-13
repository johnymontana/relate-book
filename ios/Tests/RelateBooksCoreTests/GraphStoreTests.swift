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

    @Test("provision removes temp copies left by an interrupted earlier copy")
    func staleTempCopiesRemoved() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundled = dir.appendingPathComponent("books.rl")
        let target = dir.appendingPathComponent("library.rl")
        try Fixtures.makeFixtureStore(at: bundled)
        let stale = dir.appendingPathComponent(".library.rl.\(UUID().uuidString).tmp")
        let unrelated = dir.appendingPathComponent(".other.rl.\(UUID().uuidString).tmp")
        try Data("partial".utf8).write(to: stale)
        try Data("keep".utf8).write(to: unrelated)

        #expect(try GraphStore.provision(from: bundled, to: target))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: target.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".library.rl.") }
        #expect(leftovers.isEmpty)
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
