import Foundation
import Relate

/// Tags (plan §4, phase 2): `(:Tag {name, color, created_on})`, name unique,
/// and `(:Book)-[:TAGGED {on}]->(:Tag)`.
///
/// Names are trimmed, 1–40 characters (`TagName.normalize`) and unique
/// case-insensitively: creating or adding "favorites" reuses an existing
/// "Favorites", and a rename may not take another tag's name in any case
/// (a case-only rename of the same tag is allowed). The `tag_name`
/// constraint backs the exact-name uniqueness.
///
/// Removing a tag's last book keeps the Tag (count 0); only delete removes it.
enum TagQueries {
    static let summaryColumns = """
        t.name AS name, t.color AS color, t.created_on AS createdOn,
        COUNT { MATCH (t)<-[:TAGGED]-(:Book) } AS bookCount
        """

    /// Every tag with its book count: count desc, then name (case-insensitive).
    static let list = Statement("""
        MATCH (t:Tag)
        RETURN \(summaryColumns)
        ORDER BY bookCount DESC, toLower(t.name), t.name
        """)

    /// One book's tags by name (case-insensitive).
    static func forBook(key: String) -> Statement {
        Statement("""
            MATCH (:Book {key: $key})-[r:TAGGED]->(t:Tag)
            RETURN t.name AS name, t.color AS color, r.on AS taggedOn
            ORDER BY toLower(t.name), t.name
            """, ["key": .string(key)])
    }

    /// Creates the tag, or returns the existing one whose name matches
    /// case-insensitively (unchanged). `name` must be normalized.
    static func create(name: String, color: TagColor, now: Date) -> Statement {
        Statement("""
            OPTIONAL MATCH (e:Tag) WHERE toLower(e.name) = toLower($name)
            WITH coalesce(min(e.name), $name) AS tagName
            MERGE (t:Tag {name: tagName})
              ON CREATE SET t.color = $color, t.created_on = datetime($now)
            RETURN \(summaryColumns)
            """, ["name": .string(name), "color": .string(color.rawValue), "now": .string(Timestamps.instant(now))])
    }

    /// Tags the book, creating the tag (or reusing a case-insensitive match).
    /// Idempotent: a second add keeps the first `on`. 0 rows: no such book
    /// (and no Tag is created).
    static func addTag(key: String, name: String, color: TagColor, now: Date) -> Statement {
        Statement("""
            MATCH (b:Book {key: $key})
            OPTIONAL MATCH (e:Tag) WHERE toLower(e.name) = toLower($name)
            WITH b, coalesce(min(e.name), $name) AS tagName
            MERGE (t:Tag {name: tagName})
              ON CREATE SET t.color = $color, t.created_on = datetime($now)
            MERGE (b)-[r:TAGGED]->(t)
              ON CREATE SET r.on = datetime($now)
            RETURN t.name AS name, t.color AS color, r.on AS taggedOn
            """, [
                "key": .string(key), "name": .string(name),
                "color": .string(color.rawValue), "now": .string(Timestamps.instant(now)),
            ])
    }

    /// Untags the book; `removed` is 0 when it was not tagged.
    static func remove(key: String, name: String) -> Statement {
        Statement("""
            MATCH (:Book {key: $key})-[r:TAGGED]->(:Tag {name: $name})
            DELETE r
            RETURN count(r) AS removed
            """, ["key": .string(key), "name": .string(name)])
    }

    /// Renames unless another tag already has `new` (case-insensitively).
    /// 0 rows: taken, or `old` does not exist (`exists` tells which).
    static func rename(old: String, new: String) -> Statement {
        Statement("""
            MATCH (t:Tag {name: $old})
            WHERE NOT EXISTS { MATCH (o:Tag) WHERE toLower(o.name) = toLower($new) AND o.name <> $old }
            SET t.name = $new
            RETURN t.name AS name
            """, ["old": .string(old), "new": .string(new)])
    }

    static func exists(name: String) -> Statement {
        Statement("RETURN COUNT { MATCH (t:Tag {name: $name}) } AS n", ["name": .string(name)])
    }

    static func setColor(name: String, color: TagColor) -> Statement {
        Statement("MATCH (t:Tag {name: $name}) SET t.color = $color RETURN t.name AS name",
                  ["name": .string(name), "color": .string(color.rawValue)])
    }

    /// Deletes the tag and its TAGGED relationships; `deleted` is 0 when missing.
    static func delete(name: String) -> Statement {
        Statement("MATCH (t:Tag {name: $name}) DETACH DELETE t RETURN count(*) AS deleted", ["name": .string(name)])
    }
}

extension GraphStore {
    func tags() throws -> [TagSummary] {
        try run(TagQueries.list, label: "tags").rowsView.map(TagSummary.init(row:))
    }

    func tagsForBook(key: String) throws -> [BookTag] {
        try run(TagQueries.forBook(key: key), label: "tagsForBook").rowsView.map(BookTag.init(row:))
    }

    /// Creates a tag, or returns the existing case-insensitive match
    /// unchanged. `color` defaults to `TagColor.automatic(for:)`.
    @discardableResult
    func createTag(name: String, color: TagColor? = nil, now: Date = Date()) throws -> TagSummary {
        let name = try TagName.normalize(name)
        let statement = TagQueries.create(name: name, color: color ?? .automatic(for: name), now: now)
        guard let row = try run(statement, label: "createTag").rowsView.first else {
            throw GraphError.missingColumn("name")
        }
        return try TagSummary(row: row)
    }

    /// Throws `bookNotFound`, `emptyTagName`, `tagNameTooLong`.
    @discardableResult
    func addTag(bookKey: String, name: String, color: TagColor? = nil, now: Date = Date()) throws -> BookTag {
        let name = try TagName.normalize(name)
        let statement = TagQueries.addTag(key: bookKey, name: name, color: color ?? .automatic(for: name), now: now)
        guard let row = try run(statement, label: "addTag").rowsView.first else {
            throw UserDataError.bookNotFound(bookKey)
        }
        return try BookTag(row: row)
    }

    /// True when the book had the tag.
    @discardableResult
    func removeTag(bookKey: String, name: String) throws -> Bool {
        let row = try run(TagQueries.remove(key: bookKey, name: name), label: "removeTag").rowsView.first
        return (row?.int("removed") ?? 0) > 0
    }

    /// Returns the new name. Throws `tagNameTaken`, `tagNotFound`,
    /// `emptyTagName`, `tagNameTooLong`. Renaming to the same name writes nothing.
    @discardableResult
    func renameTag(_ oldName: String, to newName: String) throws -> String {
        let new = try TagName.normalize(newName)
        if new == oldName {
            guard try tagExists(oldName) else { throw UserDataError.tagNotFound(oldName) }
            return new
        }
        if let row = try run(TagQueries.rename(old: oldName, new: new), label: "renameTag").rowsView.first {
            return try row.requiredString("name")
        }
        throw try tagExists(oldName) ? UserDataError.tagNameTaken(new) : UserDataError.tagNotFound(oldName)
    }

    /// Throws `tagNotFound`.
    func setTagColor(name: String, color: TagColor) throws {
        let result = try run(TagQueries.setColor(name: name, color: color), label: "setTagColor")
        if result.rows.isEmpty { throw UserDataError.tagNotFound(name) }
    }

    /// True when a tag was deleted.
    @discardableResult
    func deleteTag(name: String) throws -> Bool {
        let row = try run(TagQueries.delete(name: name), label: "deleteTag").rowsView.first
        return (row?.int("deleted") ?? 0) > 0
    }

    private func tagExists(_ name: String) throws -> Bool {
        let row = try run(TagQueries.exists(name: name), label: "tagExists").rowsView.first
        return (row?.int("n") ?? 0) > 0
    }
}
