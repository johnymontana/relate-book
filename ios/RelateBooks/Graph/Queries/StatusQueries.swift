import Foundation
import Relate

/// Reading status, dates and rating (plan §4, phase 2). Every write is one
/// parameterized auto-commit statement on one Book; `reset` is the only
/// multi-statement write and runs in a transaction.
///
/// Status rules (one statement, D1):
/// - every change sets `reading_status` and `status_changed_on = datetime($now)`;
/// - reading: `started_on = coalesce(started_on, date($today))`;
/// - read: `finished_on = date($today)`; `started_on` is kept, not back-filled;
/// - want: both dates are kept as history (the UI hides them).
///
/// Defaults are never written: a missing `reading_status` means want, and
/// only the book the user touched gets one.
enum StatusQueries {
    /// Shared user-data columns. `BookQueries.detail` appends these (it
    /// already returns `key` and `status`).
    static let userColumns = """
        b.my_rating AS myRating, b.started_on AS startedOn, b.finished_on AS finishedOn,
        b.status_changed_on AS statusChangedOn,
        [(b)-[r:TAGGED]->(t:Tag) | {name: t.name, color: t.color, on: r.on}] AS tags,
        [(b)-[:HAS_NOTE]->(n:Note) | {id: n.id, text: n.text, createdOn: n.created_on, updatedOn: n.updated_on}] AS notes
        """

    /// One book's status, rating, dates, tags and notes (0 rows: no such book).
    static func userData(key: String) -> Statement {
        Statement("""
            MATCH (b:Book {key: $key})
            RETURN b.key AS key, coalesce(b.reading_status, 'want') AS status,
                   \(userColumns)
            """, ["key": .string(key)])
    }

    /// `$now` is `Timestamps.instant(now)`; `$today` is the user's local day
    /// in `calendar`.
    static func setStatus(key: String, status: ReadingStatus, now: Date, calendar: Calendar) -> Statement {
        Statement("""
            MATCH (b:Book {key: $key})
            SET b.reading_status = $status,
                b.status_changed_on = datetime($now),
                b.started_on = CASE WHEN $status = 'reading' THEN coalesce(b.started_on, date($today)) ELSE b.started_on END,
                b.finished_on = CASE WHEN $status = 'read' THEN date($today) ELSE b.finished_on END
            RETURN b.key AS key
            """, [
                "key": .string(key),
                "status": .string(status.rawValue),
                "now": .string(Timestamps.instant(now)),
                "today": .string(Timestamps.day(now, calendar: calendar)),
            ])
    }

    /// `rating` nil clears it (SET to null removes the property).
    static func setRating(key: String, rating: Int?) -> Statement {
        Statement("""
            MATCH (b:Book {key: $key})
            SET b.my_rating = $rating
            RETURN b.key AS key
            """, ["key": .string(key), "rating": rating.map { .int(Int64($0)) } ?? .null])
    }

    /// Deletes every Tag and Note, every book added in the app with the
    /// nodes its imports created (phase 5, D30: Authors, Subjects, Places,
    /// People, Eras and Genres carrying `added_on`; bundled nodes never have
    /// it), and removes the five user properties from every Book (DEBUG
    /// `--reset-user-data` and tests). Run as one transaction; it only
    /// deletes nodes that existed before it began, so it is clear of the
    /// Relate create-then-delete panic (LABS-1188; 0.16.1 and 1.0.1).
    static let reset: [Statement] = [
        Statement("MATCH (t:Tag) DETACH DELETE t"),
        Statement("MATCH (n:Note) DETACH DELETE n"),
        Statement("MATCH (b:Book {source: 'app'}) DETACH DELETE b"),
        Statement("""
            MATCH (n) WHERE n.added_on IS NOT NULL AND (n:Author OR n:Subject OR n:Place OR n:Person OR n:Era OR n:Genre)
            DETACH DELETE n
            """),
        Statement("""
            MATCH (b:Book)
            WHERE b.reading_status IS NOT NULL OR b.my_rating IS NOT NULL OR b.started_on IS NOT NULL
               OR b.finished_on IS NOT NULL OR b.status_changed_on IS NOT NULL
            REMOVE b.reading_status, b.my_rating, b.started_on, b.finished_on, b.status_changed_on
            """),
    ]

    static let validRatings = 1...5
}

extension GraphStore {
    /// The book's user data, or nil when there is no such book.
    func bookUserData(key: String) throws -> BookUserData? {
        try run(StatusQueries.userData(key: key), label: "bookUserData").rowsView.first.map(BookUserData.init(row:))
    }

    /// Throws `UserDataError.bookNotFound` when there is no such book.
    func setStatus(key: String, status: ReadingStatus, now: Date = Date(), calendar: Calendar = .current) throws {
        let result = try run(StatusQueries.setStatus(key: key, status: status, now: now, calendar: calendar), label: "setStatus")
        if result.rows.isEmpty { throw UserDataError.bookNotFound(key) }
    }

    /// `rating` is 1...5 or nil (clears). Throws `invalidRating`, `bookNotFound`.
    func setRating(key: String, rating: Int?) throws {
        if let rating, !StatusQueries.validRatings.contains(rating) { throw UserDataError.invalidRating(rating) }
        let result = try run(StatusQueries.setRating(key: key, rating: rating), label: "setRating")
        if result.rows.isEmpty { throw UserDataError.bookNotFound(key) }
    }

    /// Removes every tag, note, user property and app-added book, atomically.
    func resetUserData() throws {
        try transaction(StatusQueries.reset, label: "resetUserData")
    }
}
