import Foundation
import Relate
@testable import RelateBooksCore

enum Fixtures {
    /// Three books, deliberately out of title order; one has no cover.
    static let books: [CypherValue] = [
        ["key": "/works/OL3W", "title": "Zebra Stripes", "cover_url": "https://covers.openlibrary.org/b/id/3-L.jpg"],
        ["key": "/works/OL1W", "title": "Apple Orchards", "cover_url": "https://covers.openlibrary.org/b/id/1-L.jpg"],
        ["key": "/works/OL2W", "title": "Mango Season"],
    ]

    static let insertBooks = """
        UNWIND $rows AS row
        CREATE (b:Book {key: row.key, title: row.title})
        SET b.cover_url = row.cover_url
        """

    static func insertBooks(into store: GraphStore) async throws {
        try await store.query(insertBooks, ["rows": .list(books)])
    }

    /// A fresh, empty temp directory; caller removes it.
    static func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relatebooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a small `.rl` bundle holding the fixture books, checkpointed
    /// and closed (the Database is released before returning, so the
    /// exclusive bundle lock is free).
    static func makeFixtureStore(at url: URL) throws {
        let db = try Database(path: url.path)
        let conn = try db.connect()
        _ = try conn.query(insertBooks, ["rows": .list(books)])
        try db.checkpoint()
    }
}
