import Relate

/// One Book vector to write.
struct BookEmbeddingRow: Sendable, Equatable {
    let key: String
    let vector: [Float]
    let hash: String
}

/// One Note vector to write. `text` is the text it was computed from; the
/// write only lands while the note still has that text.
struct NoteEmbeddingRow: Sendable, Equatable {
    let id: String
    let text: String
    let vector: [Float]
    let hash: String
}

/// Cypher for the embedding indexer (plan §4, D2, D3).
///
/// The indexer writes exactly three properties on Book and Note:
/// `embedding` (VECTOR<FLOAT32>(384)), `embedding_model` and
/// `embedding_text_hash`. Nothing else, no timestamps.
enum EmbeddingQueries {
    /// One page of books in key order with what `BookEmbeddingText` needs.
    /// Start with `after: ""`; the next page starts after the last key; the
    /// scan ends at a page shorter than `limit`.
    static func scanBooks(after: String, limit: Int = 200) throws -> Statement {
        try Statement("""
            MATCH (b:Book)
            WHERE b.key > $after
            WITH b ORDER BY b.key LIMIT $limit
            RETURN b.key AS key, b.title AS title, b.description AS description,
                   b.embedding_model AS model, b.embedding_text_hash AS hash, b.embedding IS NOT NULL AS hasEmbedding,
                   [(b)-[:WRITTEN_BY]->(a:Author) | a.name] AS authors,
                   [(b)-[:ABOUT]->(s:Subject) | s.name] AS subjects
            """, ["after": after, "limit": max(0, limit)])
    }

    /// One book with what `BookEmbeddingText` needs (the incremental embed
    /// after an import, D-G); 0 rows when there is no such book.
    static func scanBook(key: String) throws -> Statement {
        try Statement("""
            MATCH (b:Book {key: $key})
            RETURN b.key AS key, b.title AS title, b.description AS description,
                   b.embedding_model AS model, b.embedding_text_hash AS hash, b.embedding IS NOT NULL AS hasEmbedding,
                   [(b)-[:WRITTEN_BY]->(a:Author) | a.name] AS authors,
                   [(b)-[:ABOUT]->(s:Subject) | s.name] AS subjects
            """, ["key": key])
    }

    /// Every note (`bookKey` nil) or one book's notes.
    static func scanNotes(bookKey: String?) -> Statement {
        let match = bookKey == nil ? "MATCH (n:Note)" : "MATCH (:Book {key: $key})-[:HAS_NOTE]->(n:Note)"
        let parameters: [String: CypherValue] = bookKey.map { ["key": .string($0)] } ?? [:]
        return Statement("""
            \(match)
            RETURN n.id AS id, n.text AS text, n.embedding_model AS model, n.embedding_text_hash AS hash,
                   n.embedding IS NOT NULL AS hasEmbedding
            ORDER BY n.id
            """, parameters)
    }

    /// One batch (at most 32 rows) in one statement: it commits whole or not at all.
    static func writeBooks(_ rows: [BookEmbeddingRow], model: String) throws -> Statement {
        let values = try rows.map { row in
            CypherValue.map(["key": .string(row.key), "vector": try CypherValue(vector: row.vector), "hash": .string(row.hash)])
        }
        return try Statement("""
            UNWIND $rows AS row
            MATCH (b:Book {key: row.key})
            SET b.embedding = row.vector, b.embedding_model = $model, b.embedding_text_hash = row.hash
            RETURN count(b) AS written
            """, ["rows": values, "model": model])
    }

    /// Guarded by `n.text = row.text`: a vector computed from old text never
    /// lands on edited text (D6).
    static func writeNotes(_ rows: [NoteEmbeddingRow], model: String) throws -> Statement {
        let values = try rows.map { row in
            CypherValue.map(["id": .string(row.id), "text": .string(row.text),
                             "vector": try CypherValue(vector: row.vector), "hash": .string(row.hash)])
        }
        return try Statement("""
            UNWIND $rows AS row
            MATCH (n:Note {id: row.id})
            WHERE n.text = row.text
            SET n.embedding = row.vector, n.embedding_model = $model, n.embedding_text_hash = row.hash
            RETURN count(n) AS written
            """, ["rows": values, "model": model])
    }

    /// Removes the three properties from every Book and Note (DEBUG
    /// `--reset-embeddings`, tests). Removes properties only, so it is safe
    /// in one transaction (LABS-1188 is about deleting created nodes).
    static let reset: [Statement] = [
        Statement("""
            MATCH (b:Book)
            WHERE b.embedding IS NOT NULL OR b.embedding_model IS NOT NULL OR b.embedding_text_hash IS NOT NULL
            REMOVE b.embedding, b.embedding_model, b.embedding_text_hash
            """),
        Statement("""
            MATCH (n:Note)
            WHERE n.embedding IS NOT NULL OR n.embedding_model IS NOT NULL OR n.embedding_text_hash IS NOT NULL
            REMOVE n.embedding, n.embedding_model, n.embedding_text_hash
            """),
    ]
}

extension GraphStore {
    func embeddingScanPage(after: String, limit: Int = 200) async throws -> [BookEmbeddingInput] {
        try await read(EmbeddingQueries.scanBooks(after: after, limit: limit))
            .rowsView.map(BookEmbeddingInput.init(row:))
    }

    /// One book's embedding input, or nil when there is no such book.
    func embeddingInput(key: String) async throws -> BookEmbeddingInput? {
        try await read(EmbeddingQueries.scanBook(key: key)).rowsView.first.map(BookEmbeddingInput.init(row:))
    }

    func noteEmbeddingInputs(bookKey: String? = nil) async throws -> [NoteEmbeddingInput] {
        try await read(EmbeddingQueries.scanNotes(bookKey: bookKey))
            .rowsView.map(NoteEmbeddingInput.init(row:))
    }

    /// Validates every vector first (count 384, all finite): the engine
    /// would store a bad vector and search would silently skip it (V4).
    @discardableResult
    func writeBookEmbeddings(_ rows: [BookEmbeddingRow], model: String) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        for row in rows { try EmbeddingVector.validate(row.vector) }
        return try countColumn(await write(EmbeddingQueries.writeBooks(rows, model: model)), "written")
    }

    @discardableResult
    func writeNoteEmbeddings(_ rows: [NoteEmbeddingRow], model: String) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        for row in rows { try EmbeddingVector.validate(row.vector) }
        return try countColumn(await write(EmbeddingQueries.writeNotes(rows, model: model)), "written")
    }

    func resetEmbeddings() async throws {
        try await write(EmbeddingQueries.reset)
    }

    private func countColumn(_ result: QueryResult, _ column: String) throws -> Int {
        guard let row = result.rowsView.first else { return 0 }
        guard let n = row.int(column) else { throw GraphError.missingColumn(column) }
        return n
    }
}
