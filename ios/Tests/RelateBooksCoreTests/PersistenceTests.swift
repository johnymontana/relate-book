import Testing
import Foundation
@testable import RelateBooksCore

/// User data written to a file-backed store survives releasing it and
/// reopening the file. No checkpoint is taken after the writes: durability
/// must come from the WAL.
@Suite("Persistence across reopen", .serialized)
struct PersistenceTests {
    let t0 = UserDataClock.t0
    let la = UserDataClock.la

    /// A temp dir holding the fixture `books.rl` (bundled) and the target
    /// `Support/library.rl` path (not yet created).
    static func paths() throws -> (dir: URL, bundled: URL, target: URL) {
        let dir = try Fixtures.tempDirectory()
        let bundled = dir.appendingPathComponent("books.rl")
        try Fixtures.makeFixtureStore(at: bundled)
        return (dir, bundled, dir.appendingPathComponent("Support/library.rl"))
    }

    @Test("status, rating, tag and note survive a reopen")
    func statusTagNote() async throws {
        let (dir, bundled, target) = try Self.paths()
        defer { try? FileManager.default.removeItem(at: dir) }

        let noteID: String
        do {
            let store = try await GraphStore.bootstrap(bundledStore: bundled, storeURL: target)
            try await store.setStatus(key: "/works/OL1W", status: .read, now: t0, calendar: la)
            try await store.setRating(key: "/works/OL1W", rating: 4)
            try await store.addTag(bookKey: "/works/OL1W", name: "Favorites", now: t0)
            let note = try await store.addNote(bookKey: "/works/OL1W", text: "Persist me", now: t0)
            noteID = note.id
        }

        let store = try await GraphStore.bootstrap(bundledStore: bundled, storeURL: target)
        let data = try #require(try await store.bookUserData(key: "/works/OL1W"))
        #expect(data.status == .read)
        #expect(data.rating == 4)
        #expect(data.finishedOn == LocalDay(year: 2026, month: 11, day: 7))
        #expect(data.statusChangedOn == t0)
        #expect(data.tags.map(\.name) == ["Favorites"])
        #expect(data.notes.map(\.id) == [noteID])
        #expect(data.notes.map(\.text) == ["Persist me"])
        let tags = try await store.tags()
        #expect(tags.map(\.name) == ["Favorites"] && tags.map(\.bookCount) == [1])
        #expect(try await store.libraryPage(filter: LibraryFilter(tag: "Favorites")).map(\.key) == ["/works/OL1W"])
        // Untouched books still have no status.
        #expect(try await store.countOf("MATCH (b:Book) WHERE b.reading_status IS NOT NULL RETURN count(b)") == 1)
    }

    @Test("rename, edit and delete survive a reopen")
    func renameEditDelete() async throws {
        let (dir, bundled, target) = try Self.paths()
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            let store = try await GraphStore.bootstrap(bundledStore: bundled, storeURL: target)
            try await store.addTag(bookKey: "/works/OL1W", name: "Favorites", now: t0)
            let note = try await store.addNote(bookKey: "/works/OL1W", text: "Persist me", now: t0)
            try await store.checkpoint()
            try await store.renameTag("Favorites", to: "Loved")
            try await store.updateNote(id: note.id, text: "Edited", now: t0.addingTimeInterval(60))
            let extra = try await store.addNote(bookKey: "/works/OL1W", text: "Temporary", now: t0.addingTimeInterval(120))
            try await store.deleteNote(id: extra.id)
        }

        let store = try await GraphStore.bootstrap(bundledStore: bundled, storeURL: target)
        let tags = try await store.tags()
        #expect(tags.map(\.name) == ["Loved"] && tags.map(\.bookCount) == [1])
        #expect(try await store.notes(bookKey: "/works/OL1W").map(\.text) == ["Edited"])
        #expect(try await store.countOf("MATCH (n:Note) RETURN count(n)") == 1)
    }
}
