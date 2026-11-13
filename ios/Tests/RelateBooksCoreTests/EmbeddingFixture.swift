import Foundation
import Relate
@testable import RelateBooksCore

/// Small in-memory graphs for the indexer and search tests: Books with
/// authors (WRITTEN_BY), subjects (ABOUT), optional descriptions, one Item
/// per book (title + byline), and the two fulltext indexes books.rl has.
enum EmbeddingFixture {
    struct Book: Sendable {
        let key: String
        let title: String
        var authors: [String] = []
        var subjects: [String] = []
        var description: String?
        var status: ReadingStatus?
    }

    static let fulltextDDL = [
        "CREATE FULLTEXT INDEX book_text IF NOT EXISTS FOR (b:Book) ON EACH [b.title, b.description, b.first_sentence]",
        "CREATE FULLTEXT INDEX item_text IF NOT EXISTS FOR (i:Item) ON EACH [i.title, i.byline]",
    ]

    /// Ten books for the indexer tests; even ones have a description.
    static let tenBooks: [Book] = (1...10).map { n in
        Book(key: String(format: "/works/E%02dW", n), title: "Indexer Book \(n)",
             authors: ["Author \(n)", n % 3 == 0 ? "Coauthor" : ""].filter { !$0.isEmpty },
             subjects: ["Subject \(n)", "Shared subject", "nyt:list=\(n)"],
             description: n % 2 == 0 ? "Description of book number \(n), about topic \(n * 7)." : nil)
    }

    /// Eight books with distinct texts for the search tests.
    static let searchBooks: [Book] = [
        Book(key: "/works/S1W", title: "The Lonely Astronaut", authors: ["Ann Star"], subjects: ["Space", "Survival"],
             description: "An astronaut alone in deep space must save the earth from a dying sun.", status: .read),
        Book(key: "/works/S2W", title: "Gardens of the Moon", authors: ["Steven Erikson"], subjects: ["Fantasy", "Empires"],
             description: "Sorcerers and soldiers fight over a city under a floating fortress."),
        Book(key: "/works/S3W", title: "The Victorian Detective", authors: ["Mary Holmes"], subjects: ["Mystery", "London"],
             description: "A detective solves a murder in Victorian London fog.", status: .reading),
        Book(key: "/works/S4W", title: "Habits of Productive People", authors: ["Carl Doe"], subjects: ["Productivity", "Habits"],
             description: "How to build better habits and get organized at work."),
        Book(key: "/works/S5W", title: "A History of Money", authors: ["Niall Coin"], subjects: ["Economics", "Finance"],
             description: "Coins, banks and credit from Babylon to bitcoin.", status: .read),
        Book(key: "/works/S6W", title: "Pasta Every Day", authors: ["Lidia Cook"], subjects: ["Cooking", "Italy"],
             description: "Italian pasta recipes for weeknights."),
        Book(key: "/works/S7W", title: "Forests of Tomorrow", authors: ["Richard Green"], subjects: ["Climate", "Forests"],
             description: "Climate change and the future of forests."),
        Book(key: "/works/S8W", title: "Robots With Feelings", authors: ["Ada Byte"], subjects: ["Robots", "Artificial intelligence"],
             description: "Artificial intelligence and machines that dream."),
    ]

    static func store(_ books: [Book] = tenBooks) async throws -> GraphStore {
        let store = try await GraphStore.inMemory()
        try await seed(books, into: store)
        return store
    }

    static func seed(_ books: [Book], into store: GraphStore) async throws {
        for ddl in fulltextDDL { try await store.query(ddl) }
        let rows: [CypherValue] = books.enumerated().map { index, b in
            .map([
                "key": .string(b.key), "title": .string(b.title),
                "description": b.description.map(CypherValue.string) ?? .null,
                "status": b.status.map { .string($0.rawValue) } ?? .null,
                "authors": .list(b.authors.map(CypherValue.string)),
                "subjects": .list(b.subjects.map(CypherValue.string)),
                "byline": .string(b.authors.joined(separator: ", ")),
                "asin": .string("ASIN\(index)"),
            ])
        }
        try await store.query("""
            UNWIND $rows AS row
            CREATE (b:Book {key: row.key, title: row.title})
            SET b.description = row.description, b.reading_status = row.status
            CREATE (i:Item {asin: row.asin, title: row.title, byline: row.byline})
            CREATE (i)-[:EDITION_OF]->(b)
            """, ["rows": .list(rows)])
        try await store.query("""
            UNWIND $rows AS row
            MATCH (b:Book {key: row.key})
            UNWIND row.authors AS name
            MERGE (a:Author {name: name})
            CREATE (b)-[:WRITTEN_BY]->(a)
            """, ["rows": .list(rows)])
        try await store.query("""
            UNWIND $rows AS row
            MATCH (b:Book {key: row.key})
            UNWIND row.subjects AS name
            MERGE (s:Subject {name: name})
            CREATE (b)-[:ABOUT]->(s)
            """, ["rows": .list(rows)])
    }

    static func count(_ store: GraphStore, _ cypher: String) async throws -> Int {
        Int(try await store.query(cypher).scalar().intValue ?? -1)
    }

    static func embeddedBooks(_ store: GraphStore) async throws -> Int {
        try await count(store, "MATCH (b:Book) WHERE b.embedding IS NOT NULL RETURN count(b) AS c")
    }

    /// key -> sorted property names, for every node with `label`.
    static func propertyKeys(_ store: GraphStore, label: String, id: String) async throws -> [String: Set<String>] {
        let result = try await store.query("MATCH (n:\(label)) RETURN n.\(id) AS id, keys(n) AS ks")
        var out: [String: Set<String>] = [:]
        for row in result.rowsView {
            out[row.string("id") ?? ""] = Set(row.strings("ks"))
        }
        return out
    }
}

/// Collects progress reports from `EmbeddingIndexer.run`.
actor ProgressRecorder {
    private(set) var reports: [IndexingProgress] = []
    func add(_ p: IndexingProgress) { reports.append(p) }
}
