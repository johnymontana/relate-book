import Testing
import Foundation
import Relate
@testable import RelateBooksCore

/// Fixed clock and calendar for user-data tests: 06:30 UTC on Nov 8 is
/// still Nov 7 in Los Angeles, so dates prove the local-day policy.
enum UserDataClock {
    static let t0 = ISO8601DateFormatter().date(from: "2026-11-08T06:30:00Z")!
    static let la: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    static let enUS = Locale(identifier: "en_US")
}

extension GraphStore {
    /// First column of the first row as an Int (test helper).
    func countOf(_ cypher: String, _ parameters: [String: CypherValue] = [:]) throws -> Int {
        Int(try query(cypher, parameters).scalar().intValue ?? -1)
    }
}

@Suite("User data queries")
struct UserDataQueriesTests {
    let t0 = UserDataClock.t0
    let la = UserDataClock.la

    @Test("status transitions set dates by the local day; want keeps history but shows none")
    func statusTransitions() async throws {
        let store = try await LibraryFixture.store()
        try await store.setStatus(key: "/works/OL1W", status: .reading, now: t0, calendar: la)
        var data = try #require(try await store.bookUserData(key: "/works/OL1W"))
        #expect(data.status == .reading)
        #expect(data.startedOn == LocalDay(year: 2026, month: 11, day: 7))
        #expect(data.finishedOn == nil)
        #expect(data.statusChangedOn == t0)

        let t2 = t0.addingTimeInterval(2 * 86_400)
        try await store.setStatus(key: "/works/OL1W", status: .read, now: t2, calendar: la)
        data = try #require(try await store.bookUserData(key: "/works/OL1W"))
        #expect(data.status == .read)
        #expect(data.startedOn == LocalDay(year: 2026, month: 11, day: 7))
        #expect(data.finishedOn == LocalDay(year: 2026, month: 11, day: 9))
        #expect(data.statusChangedOn == t2)

        try await store.setStatus(key: "/works/OL1W", status: .reading, now: t2.addingTimeInterval(3600), calendar: la)
        data = try #require(try await store.bookUserData(key: "/works/OL1W"))
        #expect(data.startedOn == LocalDay(year: 2026, month: 11, day: 7))
        #expect(data.finishedOn == LocalDay(year: 2026, month: 11, day: 9))
        #expect(data.visibleDates.started == LocalDay(year: 2026, month: 11, day: 7))
        #expect(data.visibleDates.finished == nil)

        try await store.setStatus(key: "/works/OL1W", status: .want, now: t2.addingTimeInterval(7200), calendar: la)
        data = try #require(try await store.bookUserData(key: "/works/OL1W"))
        #expect(data.status == .want)
        #expect(data.startedOn != nil && data.finishedOn != nil)
        #expect(data.visibleDates.started == nil && data.visibleDates.finished == nil)
        #expect(data.datesLine(calendar: la, locale: UserDataClock.enUS) == nil)

        try await store.setStatus(key: "/works/OL3W", status: .read, now: t0, calendar: la)
        let zebra = try #require(try await store.bookUserData(key: "/works/OL3W"))
        #expect(zebra.startedOn == nil)
        let line = try #require(zebra.datesLine(calendar: la, locale: UserDataClock.enUS))
        #expect(line.contains("Finished") && !line.contains("Started"))
        #expect(line.contains("Nov 7, 2026"))
    }

    @Test("setStatus and setRating on a missing book throw bookNotFound and write nothing")
    func missingBook() async throws {
        let store = try await LibraryFixture.store()
        let before = try await store.countOf("MATCH (b:Book) RETURN count(b)")
        await #expect(throws: UserDataError.bookNotFound("/works/NOPE")) {
            try await store.setStatus(key: "/works/NOPE", status: .read, now: t0, calendar: la)
        }
        await #expect(throws: UserDataError.bookNotFound("/works/NOPE")) {
            try await store.setRating(key: "/works/NOPE", rating: 3)
        }
        #expect(try await store.countOf("MATCH (b:Book) RETURN count(b)") == before)
    }

    @MainActor
    @Test("loading screens never writes reading_status defaults; one write touches one book")
    func noBulkDefaults() async throws {
        let store = try await LibraryFixture.store()
        let withStatus = "MATCH (b:Book) WHERE b.reading_status IS NOT NULL RETURN count(b)"
        #expect(try await store.countOf(withStatus) == 1)        // the fixture's OL2W
        let controller = UserDataController(store: store, now: { UserDataClock.t0 }, calendar: la)
        let library = LibraryModel(store: store, userData: controller)
        await library.start()
        for key in ["/works/OL1W", "/works/OL3W", "amazon:B000UNRES"] {
            let detail = BookDetailModel(key: key, store: store, userData: controller)
            await detail.load()
            #expect(detail.userData?.status == .want)
        }
        #expect(try await store.countOf(withStatus) == 1)
        try await store.setStatus(key: "/works/OL1W", status: .reading, now: t0, calendar: la)
        #expect(try await store.countOf(withStatus) == 2)
        #expect(try await store.countOf("MATCH (b:Book) WHERE b.status_changed_on IS NOT NULL RETURN count(b)") == 1)
    }

    @Test("rating: stored, cleared with nil, validated, decoded in list rows")
    func rating() async throws {
        let store = try await LibraryFixture.store()
        try await store.setRating(key: "/works/OL1W", rating: 4)
        #expect(try await store.bookUserData(key: "/works/OL1W")?.rating == 4)
        let row = try await store.libraryPage().first { $0.key == "/works/OL1W" }
        #expect(row?.myRating == 4)
        try await store.setRating(key: "/works/OL1W", rating: nil)
        #expect(try await store.countOf("MATCH (b:Book {key: '/works/OL1W'}) WHERE b.my_rating IS NULL RETURN count(b)") == 1)
        #expect(try await store.bookUserData(key: "/works/OL1W")?.rating == nil)
        await #expect(throws: UserDataError.invalidRating(0)) { try await store.setRating(key: "/works/OL1W", rating: 0) }
        await #expect(throws: UserDataError.invalidRating(6)) { try await store.setRating(key: "/works/OL1W", rating: 6) }
    }

    @Test("tags: add, case-insensitive reuse, idempotent, order, remove, create, validation")
    func tags() async throws {
        let store = try await LibraryFixture.store()
        let fav = try await store.addTag(bookKey: "/works/OL1W", name: "Favorites", now: t0)
        #expect(fav.name == "Favorites")
        #expect(fav.color == TagColor.automatic(for: "Favorites"))
        #expect(fav.taggedOn == t0)

        let again = try await store.addTag(bookKey: "/works/OL2W", name: "  favorites ", now: t0.addingTimeInterval(60))
        #expect(again.name == "Favorites")
        var all = try await store.tags()
        #expect(all.count == 1)
        #expect(all.first?.name == "Favorites" && all.first?.bookCount == 2)

        let readd = try await store.addTag(bookKey: "/works/OL1W", name: "Favorites", now: t0.addingTimeInterval(600))
        #expect(readd.taggedOn == t0)                       // first `on` kept
        #expect(try await store.countOf("MATCH ()-[r:TAGGED]->() RETURN count(r)") == 2)

        try await store.addTag(bookKey: "/works/OL3W", name: "Alpha", now: t0)
        try await store.addTag(bookKey: "/works/OL3W", name: "beta", now: t0)
        all = try await store.tags()
        #expect(all.map(\.name) == ["Favorites", "Alpha", "beta"])
        #expect(all.map(\.bookCount) == [2, 1, 1])
        #expect(try await store.tagsForBook(key: "/works/OL3W").map(\.name) == ["Alpha", "beta"])

        #expect(try await store.removeTag(bookKey: "/works/OL3W", name: "Alpha"))
        #expect(try await store.tags().first { $0.name == "Alpha" }?.bookCount == 0)
        #expect(try await store.removeTag(bookKey: "/works/OL3W", name: "Alpha") == false)

        let empty = try await store.createTag(name: "Empty", now: t0)
        #expect(empty.bookCount == 0 && empty.name == "Empty" && empty.createdOn == t0)
        let tagCount = try await store.countOf("MATCH (t:Tag) RETURN count(t)")
        let same = try await store.createTag(name: "EMPTY", color: .red, now: t0)
        #expect(same.name == "Empty")
        #expect(same.color == TagColor.automatic(for: "Empty"))   // existing tag unchanged
        #expect(try await store.countOf("MATCH (t:Tag) RETURN count(t)") == tagCount)

        await #expect(throws: UserDataError.bookNotFound("/works/NOPE")) {
            try await store.addTag(bookKey: "/works/NOPE", name: "Ghost")
        }
        #expect(try await store.countOf("MATCH (t:Tag {name: 'Ghost'}) RETURN count(t)") == 0)
        await #expect(throws: UserDataError.emptyTagName) { try await store.addTag(bookKey: "/works/OL1W", name: "   ") }
        await #expect(throws: UserDataError.tagNameTooLong) {
            try await store.addTag(bookKey: "/works/OL1W", name: String(repeating: "x", count: 41))
        }
        try await store.addTag(bookKey: "/works/OL1W", name: String(repeating: "y", count: 40))
    }

    @Test("rename: books keep the tag; collisions refused case-insensitively; case-only rename allowed")
    func rename() async throws {
        let store = try await LibraryFixture.store()
        try await store.addTag(bookKey: "/works/OL1W", name: "Favorites", now: t0)
        try await store.addTag(bookKey: "/works/OL2W", name: "Favorites", now: t0)
        try await store.addTag(bookKey: "/works/OL3W", name: "Alpha", now: t0)

        #expect(try await store.renameTag("Favorites", to: "Loved") == "Loved")
        #expect(try await store.tagsForBook(key: "/works/OL1W").map(\.name) == ["Loved"])
        #expect(try await store.tagsForBook(key: "/works/OL2W").map(\.name) == ["Loved"])
        #expect(try await store.libraryCount(filter: LibraryFilter(tag: "Loved")) == 2)
        #expect(try await store.libraryCount(filter: LibraryFilter(tag: "Favorites")) == 0)

        await #expect(throws: UserDataError.tagNameTaken("LOVED")) { try await store.renameTag("Alpha", to: "LOVED") }
        #expect(try await store.renameTag("Loved", to: "loved") == "loved")
        #expect(try await store.renameTag("loved", to: "loved") == "loved")      // no-op
        await #expect(throws: UserDataError.tagNotFound("Nope")) { try await store.renameTag("Nope", to: "Other") }
        await #expect(throws: UserDataError.emptyTagName) { try await store.renameTag("Alpha", to: " ") }

        try await store.setTagColor(name: "loved", color: .teal)
        #expect(try await store.tags().first { $0.name == "loved" }?.color == .teal)
        await #expect(throws: UserDataError.tagNotFound("Nope")) { try await store.setTagColor(name: "Nope", color: .red) }
    }

    @Test("delete: DETACH DELETEs the tag; books stay")
    func deleteTag() async throws {
        let store = try await LibraryFixture.store()
        try await store.addTag(bookKey: "/works/OL1W", name: "loved", now: t0)
        try await store.addTag(bookKey: "/works/OL2W", name: "loved", now: t0)
        try await store.addTag(bookKey: "/works/OL3W", name: "other", now: t0)
        let books = try await store.countOf("MATCH (b:Book) RETURN count(b)")
        let tagged = try await store.countOf("MATCH ()-[r:TAGGED]->() RETURN count(r)")
        #expect(try await store.deleteTag(name: "loved"))
        #expect(try await store.countOf("MATCH (t:Tag {name: 'loved'}) RETURN count(t)") == 0)
        #expect(try await store.countOf("MATCH ()-[r:TAGGED]->() RETURN count(r)") == tagged - 2)
        #expect(try await store.countOf("MATCH (b:Book) RETURN count(b)") == books)
        #expect(try await store.bookDetail(key: "/works/OL1W")?.title == "Apple Orchards")
        #expect(try await store.bookDetail(key: "/works/OL2W")?.title == "Mango Season")
        #expect(try await store.deleteTag(name: "loved") == false)
    }

    @Test("notes: add trims, newest first, edit keeps created and moves to top, delete is idempotent")
    func notes() async throws {
        let store = try await LibraryFixture.store()
        let first = try await store.addNote(bookKey: "/works/OL1W", text: "Line one\nLine two\n", now: t0)
        #expect(first.text == "Line one\nLine two")
        #expect(first.createdOn == t0 && first.updatedOn == t0 && !first.wasEdited)
        #expect(UUID(uuidString: first.id) != nil)

        let second = try await store.addNote(bookKey: "/works/OL1W", text: "Second", now: t0.addingTimeInterval(60))
        #expect(try await store.notes(bookKey: "/works/OL1W").map(\.id) == [second.id, first.id])

        let edited = try await store.updateNote(id: first.id, text: "Edited", now: t0.addingTimeInterval(120))
        #expect(edited.createdOn == t0 && edited.updatedOn == t0.addingTimeInterval(120) && edited.wasEdited)
        #expect(edited.text == "Edited")
        let listed = try await store.notes(bookKey: "/works/OL1W")
        #expect(listed.map(\.id) == [first.id, second.id])
        #expect(try await store.bookUserData(key: "/works/OL1W")?.notes == listed)

        await #expect(throws: UserDataError.noteNotFound("missing")) { try await store.updateNote(id: "missing", text: "x") }
        await #expect(throws: UserDataError.emptyNote) { try await store.addNote(bookKey: "/works/OL1W", text: "  \n ") }
        await #expect(throws: UserDataError.emptyNote) { try await store.updateNote(id: first.id, text: "  \n ") }
        await #expect(throws: UserDataError.bookNotFound("/works/NOPE")) { try await store.addNote(bookKey: "/works/NOPE", text: "x") }
        await #expect(throws: RelateError.self) { try await store.addNote(bookKey: "/works/OL2W", text: "dup", id: first.id) }

        #expect(try await store.deleteNote(id: second.id))
        #expect(try await store.deleteNote(id: second.id) == false)
        #expect(try await store.notes(bookKey: "/works/OL1W").map(\.id) == [first.id])
        #expect(try await store.countOf("MATCH (n:Note) RETURN count(n)") == 1)
    }

    @Test("filter by tag: alone, with status, text and format; unknown tag; statement shape")
    func filterByTag() async throws {
        let store = try await LibraryFixture.store()
        try await store.addTag(bookKey: "/works/OL1W", name: "Favorites", now: t0)
        try await store.addTag(bookKey: "/works/OL2W", name: "Favorites", now: t0)
        let fav = LibraryFilter(tag: "Favorites")
        #expect(try await store.libraryPage(filter: fav).map(\.key) == ["/works/OL1W", "/works/OL2W"])
        #expect(try await store.libraryCount(filter: fav) == 2)
        #expect(try await store.libraryPage(filter: LibraryFilter(status: .read, tag: "Favorites")).map(\.key) == ["/works/OL2W"])
        #expect(try await store.libraryPage(filter: LibraryFilter(tag: "Favorites", text: "mango")).map(\.key) == ["/works/OL2W"])
        #expect(try await store.libraryCount(filter: LibraryFilter(tag: "Favorites", text: "mango")) == 1)
        let paperback = try await store.libraryPage(filter: LibraryFilter(format: "Paperback", tag: "Favorites"))
        #expect(paperback.map(\.key) == ["/works/OL1W"])
        #expect(paperback.first?.format == "Paperback")
        #expect(try await store.libraryPage(filter: LibraryFilter(tag: "Nope")).isEmpty)
        #expect(try await store.libraryCount(filter: LibraryFilter(tag: "Nope")) == 0)
        for sort in LibrarySort.allCases {
            #expect(Set(try await store.libraryPage(filter: fav, sort: sort).map(\.key)) == ["/works/OL1W", "/works/OL2W"])
        }

        let plain = LibraryQueries.page(filter: fav, sort: .title, skip: 0)
        #expect(plain.cypher.contains("MATCH (:Tag {name: $tag})<-[:TAGGED]-(b:Book)"))
        #expect(!plain.cypher.contains("EXISTS"))
        let searched = LibraryQueries.page(filter: LibraryFilter(tag: "Favorites", text: "mango"), sort: .title, skip: 0)
        #expect(searched.cypher.contains("EXISTS { MATCH (b)-[:TAGGED]->(ft:Tag) WHERE ft.name = $tag }"))
        let evil = "x'}) DETACH DELETE (b"
        let injected = LibraryQueries.page(filter: LibraryFilter(tag: evil), sort: .title, skip: 0)
        #expect(!injected.cypher.contains(evil))
        #expect(injected.parameters["tag"] == .string(evil))
        #expect(try await store.libraryPage(filter: LibraryFilter(tag: evil)).isEmpty)
        #expect(try await store.countOf("MATCH (b:Book) RETURN count(b)") == 5)
        #expect(LibraryFilter(tag: "x").activeCount == 1)
    }

    @Test("recently updated: newest status change first, untouched books last by title")
    func recentlyUpdated() async throws {
        let store = try await LibraryFixture.store()
        try await store.setStatus(key: "/works/OL3W", status: .reading, now: t0, calendar: la)
        try await store.setStatus(key: "/works/OL1W", status: .read, now: t0.addingTimeInterval(3600), calendar: la)
        try await store.setStatus(key: "amazon:B000UNRES", status: .want, now: t0.addingTimeInterval(7200), calendar: la)
        #expect(try await store.libraryPage(sort: .recentlyUpdated).map(\.key)
                == ["amazon:B000UNRES", "/works/OL1W", "/works/OL3W", "/works/OL5W", "/works/OL2W"])
        #expect(LibrarySort.recentlyUpdated.rawValue == "recent")
        #expect(LibrarySort.allCases.last == .recentlyUpdated)
    }

    @Test("status filter works with written values")
    func statusFilterWithWrites() async throws {
        let store = try await LibraryFixture.store()
        try await store.setStatus(key: "/works/OL1W", status: .reading, now: t0, calendar: la)
        #expect(try await store.libraryPage(filter: LibraryFilter(status: .reading)).map(\.key) == ["/works/OL1W"])
        let want = try await store.libraryPage(filter: LibraryFilter(status: .want)).map(\.key)
        #expect(!want.contains("/works/OL1W"))
        #expect(want == ["/works/OL5W", "amazon:B000UNRES", "/works/OL3W"])
        try await store.setStatus(key: "/works/OL3W", status: .want, now: t0, calendar: la)   // explicit want
        #expect(try await store.libraryPage(filter: LibraryFilter(status: .want)).map(\.key).contains("/works/OL3W"))
        let reading = LibraryQueries.page(filter: LibraryFilter(status: .reading), sort: .title, skip: 0)
        #expect(reading.cypher.contains("b.reading_status = $status"))
        let wantStatement = LibraryQueries.page(filter: LibraryFilter(status: .want), sort: .title, skip: 0)
        #expect(wantStatement.cypher.contains("coalesce(b.reading_status, 'want') = $status"))
    }

    @Test("reset removes all user data atomically; a failed transaction rolls back")
    func resetAndTransaction() async throws {
        let store = try await LibraryFixture.store()
        try await store.setStatus(key: "/works/OL1W", status: .read, now: t0, calendar: la)
        try await store.setRating(key: "/works/OL1W", rating: 5)
        try await store.addTag(bookKey: "/works/OL1W", name: "Favorites", now: t0)
        try await store.addTag(bookKey: "/works/OL3W", name: "Other", now: t0)
        try await store.addNote(bookKey: "/works/OL1W", text: "note", now: t0)
        let books = try await store.countOf("MATCH (b:Book) RETURN count(b)")
        let anyUserProperty = """
            MATCH (b:Book)
            WHERE b.reading_status IS NOT NULL OR b.my_rating IS NOT NULL OR b.started_on IS NOT NULL
               OR b.finished_on IS NOT NULL OR b.status_changed_on IS NOT NULL
            RETURN count(b)
            """
        for _ in 0..<2 {        // the second reset is a no-op
            try await store.resetUserData()
            #expect(try await store.countOf("MATCH (t:Tag) RETURN count(t)") == 0)
            #expect(try await store.countOf("MATCH (n:Note) RETURN count(n)") == 0)
            #expect(try await store.countOf("MATCH ()-[r:TAGGED]->() RETURN count(r)") == 0)
            #expect(try await store.countOf(anyUserProperty) == 0)      // including the fixture's OL2W status
            #expect(try await store.countOf("MATCH (b:Book) RETURN count(b)") == books)
            #expect(try await store.bookDetail(key: "/works/OL1W")?.title == "Apple Orchards")
        }

        try await store.createTag(name: "Keep", now: t0)
        await #expect(throws: RelateError.self) {
            try await store.transaction([Statement("MATCH (t:Tag) DETACH DELETE t"), Statement("RETURN 1/0 AS x")])
        }
        #expect(try await store.tags().map(\.name) == ["Keep"])
        #expect(try await store.query("RETURN 41 + 1 AS x").scalar().intValue == 42)
        let results = try await store.transaction([Statement("RETURN 1 AS x"), Statement("RETURN 2 AS x")])
        #expect(results.map { $0.rows.count } == [1, 1])
    }

    @Test("decoding: datetimes with offsets, dates, timestamps, palette")
    func decoding() throws {
        let dt = CypherValue.DateTime(year: 2026, month: 11, day: 8, hour: 13, minute: 0, second: 0,
                                      nanosecond: 123_000_000, offsetSeconds: 3600, zone: nil)
        let expected = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-11-08T12:00:00.123Z")
        let decoded = try #require(Row(["d": .dateTime(dt)]).instant("d"))
        #expect(decoded == expected)
        #expect(Row(["d": .localDateTime(.init(year: 2026, month: 11, day: 8, hour: 12, minute: 0, second: 0, nanosecond: 0))]).instant("d")
                == ISO8601DateFormatter().date(from: "2026-11-08T12:00:00Z"))
        #expect(Row(["d": .string("2026-11-08T06:30:00Z")]).instant("d") == t0)
        #expect(Row(["d": .string("2026-11-08T06:30:00.000Z")]).instant("d") == t0)
        #expect(Row(["d": .int(3)]).instant("d") == nil)
        #expect(Row(["d": .date(.init(year: 2026, month: 11, day: 8))]).day("d") == LocalDay(year: 2026, month: 11, day: 8))
        #expect(Row(["d": .string("2026-11-08")]).day("d") == LocalDay(year: 2026, month: 11, day: 8))
        #expect(Row(["d": .string("Nov 8")]).day("d") == nil)
        #expect(Timestamps.instant(t0) == "2026-11-08T06:30:00.000Z")
        #expect(Timestamps.day(t0, calendar: la) == "2026-11-07")
        #expect(LocalDay(year: 2026, month: 1, day: 2).iso == "2026-01-02")
        #expect(LocalDay(year: 2026, month: 1, day: 2) < LocalDay(year: 2026, month: 1, day: 3))
        #expect(LocalDay(year: 2026, month: 11, day: 7).date(in: la).map { LocalDay($0, calendar: la) } == LocalDay(year: 2026, month: 11, day: 7))
        let a = TagColor.automatic(for: "Favorites")
        #expect(a == TagColor.automatic(for: "Favorites") && a == TagColor.automatic(for: "FAVORITES"))
        #expect(TagColor.allCases.contains(a) && TagColor.allCases.count == 8)
        #expect(Set(["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"].map(TagColor.automatic(for:))).count > 1)
        #expect(TagColor(graphValue: nil) == nil)
        #expect(TagColor(graphValue: "chartreuse") == nil)
        #expect(TagColor(graphValue: "red") == .red)
        #expect(TagColor.teal.label == "Teal")
        #expect(UserDataError.tagNameTaken("X").errorDescription == "A tag named “X” already exists")
        #expect(UserDataError.tagNameTooLong.errorDescription == "Tag names are limited to 40 characters")
        #expect(throws: UserDataError.emptyNote) { try NoteText.normalize(" \n\t ") }
        #expect(try NoteText.normalize("\n a\n\nb \n") == "a\n\nb")
    }
}
