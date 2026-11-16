import Foundation
import Relate

/// Notes (plan §4, phase 2): `(:Note {id, text, created_on, updated_on})`,
/// id unique (a UUID string generated in Swift), and
/// `(:Book)-[:HAS_NOTE]->(:Note)`. Plain multi-line text, trimmed
/// (`NoteText.normalize`). Newest first: an edit moves a note to the top.
enum NoteQueries {
    static let columns = "n.id AS id, n.text AS text, n.created_on AS createdOn, n.updated_on AS updatedOn"

    static func list(bookKey: String) throws -> Statement {
        try Statement("""
            MATCH (:Book {key: $key})-[:HAS_NOTE]->(n:Note)
            RETURN \(columns)
            ORDER BY n.updated_on DESC, n.created_on DESC, n.id
            """, ["key": bookKey])
    }

    /// 0 rows: no such book. A duplicate id violates `note_id`.
    static func add(bookKey: String, id: String, text: String, now: Date) throws -> Statement {
        try Statement("""
            MATCH (b:Book {key: $key})
            CREATE (b)-[:HAS_NOTE]->(n:Note {id: $id, text: $text, created_on: $now, updated_on: $now})
            RETURN \(columns)
            """, ["key": bookKey, "id": id, "text": text, "now": now])
    }

    /// Keeps created_on. 0 rows: no such note.
    static func update(id: String, text: String, now: Date) throws -> Statement {
        try Statement("""
            MATCH (n:Note {id: $id})
            SET n.text = $text, n.updated_on = $now
            RETURN \(columns)
            """, ["id": id, "text": text, "now": now])
    }

    /// Idempotent; `deleted` is 0 when missing.
    static func delete(id: String) throws -> Statement {
        try Statement("MATCH (n:Note {id: $id}) DETACH DELETE n RETURN count(*) AS deleted", ["id": id])
    }
}

extension GraphStore {
    func notes(bookKey: String) async throws -> [BookNote] {
        try await read(NoteQueries.list(bookKey: bookKey)).rowsView.map(BookNote.init(row:))
    }

    /// Throws `emptyNote`, `bookNotFound`.
    @discardableResult
    func addNote(bookKey: String, text: String, id: String = UUID().uuidString, now: Date = Date()) async throws -> BookNote {
        let text = try NoteText.normalize(text)
        guard let row = try await write(NoteQueries.add(bookKey: bookKey, id: id, text: text, now: now)).rowsView.first else {
            throw UserDataError.bookNotFound(bookKey)
        }
        return try BookNote(row: row)
    }

    /// Throws `emptyNote`, `noteNotFound`.
    @discardableResult
    func updateNote(id: String, text: String, now: Date = Date()) async throws -> BookNote {
        let text = try NoteText.normalize(text)
        guard let row = try await write(NoteQueries.update(id: id, text: text, now: now)).rowsView.first else {
            throw UserDataError.noteNotFound(id)
        }
        return try BookNote(row: row)
    }

    /// True when a note was deleted.
    @discardableResult
    func deleteNote(id: String) async throws -> Bool {
        let row = try await write(NoteQueries.delete(id: id)).rowsView.first
        return (row?.int("deleted") ?? 0) > 0
    }
}
