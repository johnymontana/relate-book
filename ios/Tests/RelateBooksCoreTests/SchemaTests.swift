import Testing
import Relate
@testable import RelateBooksCore

@Suite("Schema")
struct SchemaTests {
    @Test("migrate is idempotent")
    func migrateTwice() async throws {
        let store = GraphStore(database: try Database.inMemory())
        #expect(try await store.migrate() == Schema.currentVersion)
        #expect(try await store.migrate() == Schema.currentVersion)
        let metas = try await store.query("MATCH (m:AppMeta {key: 'schema_version'}) RETURN count(m) AS c").scalar()
        #expect(metas.intValue == 1)
    }

    @Test("schema_version is written to AppMeta")
    func versionWritten() async throws {
        let store = try await GraphStore.inMemory()
        let value = try await store.query(Schema.readVersion).scalar()
        #expect(value.intValue == Int64(Schema.currentVersion))
    }

    @Test("indexes and constraints exist after migrate")
    func indexesExist() async throws {
        let store = try await GraphStore.inMemory()
        let names = try await store.query("SHOW INDEXES YIELD name RETURN name")
            .records.compactMap { $0["name"]?.stringValue }
        for expected in ["meta_key", "tag_name", "note_id", "book_status", "place_location", "place_label"] {
            #expect(names.contains(expected), "missing index \(expected)")
        }
    }

    @Test("AppMeta.key is unique")
    func metaKeyUnique() async throws {
        let store = try await GraphStore.inMemory()
        await #expect(throws: RelateError.self) {
            try await store.query("CREATE (:AppMeta {key: 'schema_version', value: 99})")
        }
    }

    @Test("the two vector indexes exist (phase 3)")
    func vectorIndexes() async throws {
        let store = try await GraphStore.inMemory()
        let rows = try await store.query("SHOW INDEXES YIELD name, type RETURN name, type").rowsView
        let types = Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.string("name").map { ($0, row.string("type") ?? "") } })
        #expect(types["book_embedding"] == "VECTOR")
        #expect(types["note_embedding"] == "VECTOR")
    }

    @Test("schema_version is 2; a version-1 store migrates to 2, idempotently")
    func versionTwo() async throws {
        #expect(Schema.currentVersion == 2)
        let store = GraphStore(database: try Database.inMemory())
        #expect(try await store.migrate() == 2)
        try await store.query("MATCH (m:AppMeta {key: 'schema_version'}) SET m.version = 1")
        #expect(try await store.query(Schema.readVersion).scalar().intValue == 1)
        #expect(try await store.migrate() == 2)
        #expect(try await store.query(Schema.readVersion).scalar().intValue == 2)
        #expect(try await store.migrate() == 2)
        let vectorCount = try await store.query("SHOW INDEXES YIELD name, type WHERE type = 'VECTOR' RETURN count(*) AS c").scalar()
        #expect(vectorCount.intValue == 2)
    }

    @Test("a store from before the migrator (version kept in AppMeta.value) is adopted, at either version")
    func legacyVersionRecord() async throws {
        for legacy in [1, 2] {
            let store = GraphStore(database: try Database.inMemory())
            try await store.query("CREATE (:AppMeta {key: 'schema_version', value: $v})", ["v": .int(Int64(legacy))])
            #expect(try await store.migrate() == 2)
            let record = try #require(try await store.query(
                "MATCH (m:AppMeta {key: 'schema_version'}) RETURN m.version AS version, m.value AS value").rowsView.first)
            #expect(record.int("version") == 2 && record["value"].isNull)
            #expect(try await store.migrate() == 2)
            #expect(try await store.countOf("MATCH (m:AppMeta) RETURN count(m)") == 1)
        }
    }

    @Test("a store written by a newer build is refused before anything runs")
    func newerStoreRefused() async throws {
        let store = GraphStore(database: try Database.inMemory())
        try await store.query("CREATE (:AppMeta {key: 'schema_version', version: 99})")
        await #expect(throws: RelateError.self) { try await store.migrate() }
        let names = try await store.query("SHOW INDEXES YIELD name RETURN name").rowsView.compactMap { $0.string("name") }
        #expect(!names.contains("tag_name") && !names.contains("book_embedding"))
    }
}
