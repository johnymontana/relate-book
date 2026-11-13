import Testing
import Foundation
@testable import RelateBooksCore

/// A clock tests can advance (status_changed_on ordering).
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

@MainActor
@Suite("User data view models")
struct UserDataModelTests {
    let la = UserDataClock.la

    func controller(_ store: GraphStore) -> UserDataController {
        UserDataController(store: store, now: { UserDataClock.t0 }, calendar: UserDataClock.la)
    }

    @Test("BookDetailModel writes status, rating, tags and notes through the controller")
    func detailActions() async throws {
        let store = try await LibraryFixture.store()
        let model = BookDetailModel(key: "/works/OL1W", store: store, userData: controller(store))
        await model.load()
        #expect(model.userData?.status == .want)

        await model.setStatus(.read)
        #expect(model.userData?.status == .read)
        #expect(model.userData?.finishedOn == LocalDay(year: 2026, month: 11, day: 7))
        #expect(model.userData?.statusChangedOn == UserDataClock.t0)

        await model.setRating(5)
        #expect(model.userData?.rating == 5)
        await model.addTag("Favorites")
        #expect(model.userData?.tags.map(\.name) == ["Favorites"])
        #expect(model.userData?.tags.first?.taggedOn == UserDataClock.t0)
        #expect(model.allTags.map(\.name) == ["Favorites"])

        #expect(await model.saveNote(id: nil, text: "Hi"))
        let note = try #require(model.userData?.notes.first)
        #expect(model.userData?.notes.count == 1 && note.text == "Hi")
        #expect(await model.saveNote(id: note.id, text: "Hi 2"))
        #expect(model.userData?.notes.map(\.text) == ["Hi 2"])
        #expect(await model.saveNote(id: nil, text: "   ") == false)
        #expect(model.actionError == "Notes can't be empty")
        model.actionError = nil

        await model.deleteNote(id: note.id)
        #expect(model.userData?.notes.isEmpty == true)

        await model.toggleTag("favorites")              // case-insensitive match removes
        #expect(model.userData?.tags.isEmpty == true)
        await model.toggleTag("Favorites")
        #expect(model.userData?.tags.map(\.name) == ["Favorites"])
        await model.setStatus(.read)                     // no-op
        #expect(model.actionError == nil)

        let stored = try #require(try await store.bookUserData(key: "/works/OL1W"))
        #expect(stored == model.userData)

        // Without a controller the screen is read-only.
        let readOnly = BookDetailModel(key: "/works/OL3W", store: store)
        await readOnly.load()
        await readOnly.setStatus(.read)
        #expect(readOnly.userData?.status == .want)
        #expect(await readOnly.saveNote(id: nil, text: "x") == false)
    }

    @Test("a failed write restores the snapshot and reports the error")
    func reconcileOnError() async throws {
        let store = try await LibraryFixture.store()
        let model = BookDetailModel(key: "/works/OL3W", store: store, userData: controller(store))
        await model.load()
        try await store.query("MATCH (b:Book {key: '/works/OL3W'}) DETACH DELETE b")
        let before = try await store.countOf("MATCH (b:Book) WHERE b.reading_status IS NOT NULL RETURN count(b)")
        await model.setStatus(.reading)
        #expect(model.userData?.status == .want)
        #expect(model.actionError == "That book is no longer in the library")
        #expect(try await store.countOf("MATCH (b:Book) WHERE b.reading_status IS NOT NULL RETURN count(b)") == before)

        model.actionError = nil
        await model.addTag("Ghost")
        #expect(model.userData?.tags.isEmpty == true)
        #expect(model.actionError != nil)
        #expect(try await store.tags().isEmpty)
    }

    @Test("changes reach other screens: rows patch in place; sort/filter changes mark needsReload")
    func events() async throws {
        let store = try await LibraryFixture.store()
        let clock = TestClock(UserDataClock.t0)
        let shared = UserDataController(store: store, now: { clock.now }, calendar: la)
        let library = LibraryModel(store: store, userData: shared)
        await library.start()
        let count = library.list.books.count
        let detail = BookDetailModel(key: "/works/OL1W", store: store, userData: shared)
        await detail.load()

        await detail.setStatus(.reading)
        #expect(library.list.books.first { $0.key == "/works/OL1W" }?.status == .reading)
        #expect(library.list.books.count == count)
        #expect(library.needsReload == false)
        await detail.setRating(3)
        #expect(library.list.books.first { $0.key == "/works/OL1W" }?.myRating == 3)

        await library.setSort(.recentlyUpdated)
        #expect(library.list.books.first?.key == "/works/OL1W")
        let zebra = BookDetailModel(key: "/works/OL3W", store: store, userData: shared)
        await zebra.load()
        clock.advance(60)
        await zebra.setStatus(.read)
        #expect(library.needsReload)
        await library.reloadIfNeeded()
        #expect(library.needsReload == false)
        #expect(library.list.books.prefix(2).map(\.key) == ["/works/OL3W", "/works/OL1W"])

        // A change made elsewhere refreshes an open detail screen.
        clock.advance(60)
        await library.setStatus(key: "/works/OL1W", to: .read)
        #expect(library.list.books.first?.key == "/works/OL1W")
        for _ in 0..<20 where detail.userData?.status != .read { await Task.yield() }
        #expect(detail.userData?.status == .read)
    }

    @Test("LibraryModel.setStatus under a status filter drops the row after reload")
    func libraryStatusWithFilter() async throws {
        let store = try await LibraryFixture.store()
        let library = LibraryModel(store: store, userData: controller(store))
        await library.start()
        await library.toggleStatus(.want)
        let total = try #require(library.total)
        #expect(library.list.books.contains { $0.key == "/works/OL1W" })
        await library.setStatus(key: "/works/OL1W", to: .read)
        #expect(!library.list.books.contains { $0.key == "/works/OL1W" })
        #expect(library.total == total - 1)
        #expect(library.actionError == nil)

        await library.setStatus(key: "/works/NOPE", to: .read)
        #expect(library.actionError != nil)
    }

    @Test("tags flow: list, rename, delete; a deleted filter tag is cleared")
    func tagsFlow() async throws {
        let store = try await LibraryFixture.store()
        let shared = controller(store)
        try await store.addTag(bookKey: "/works/OL1W", name: "Old")
        try await store.addTag(bookKey: "/works/OL2W", name: "Old")
        try await store.addTag(bookKey: "/works/OL3W", name: "Other")
        let tags = TagsModel(controller: shared)
        await tags.load()
        #expect(tags.state.value?.map(\.name) == ["Old", "Other"])
        #expect(tags.state.value?.map(\.bookCount) == [2, 1])

        let library = LibraryModel(store: store, userData: shared)
        await library.start()
        #expect(library.tags.map(\.name) == ["Old", "Other"])
        let all = try #require(library.total)

        let old = try #require(tags.state.value?.first)
        #expect(await tags.rename(old, to: "New"))
        #expect(tags.state.value?.map(\.name) == ["New", "Other"])
        await library.settleUserDataChanges()
        #expect(library.tags.map(\.name) == ["New", "Other"])
        await library.toggleTag("New")
        #expect(library.filter.tag == "New")
        #expect(library.total == 2)

        let other = try #require(tags.state.value?.last)
        #expect(await tags.rename(other, to: "new") == false)
        #expect(tags.actionError == "A tag named “new” already exists")
        #expect(await tags.create("") == false)

        let renamed = try #require(tags.state.value?.first)
        await tags.delete(renamed)
        #expect(tags.state.value?.map(\.name) == ["Other"])
        #expect(try await store.tags().map(\.name) == ["Other"])
        await library.settleUserDataChanges()
        #expect(library.filter.tag == nil)
        #expect(library.total == all)
        #expect(library.list.books.count == all)

        #expect(await tags.create("Fresh"))
        #expect(tags.state.value?.map(\.name).contains("Fresh") == true)
        let fresh = try #require(tags.state.value?.first { $0.name == "Fresh" })
        await tags.setColor(fresh, .pink)
        #expect(tags.state.value?.first { $0.name == "Fresh" }?.color == .pink)
    }

    @Test("TagBooksModel lists the tag's books and patches rows")
    func tagBooks() async throws {
        let store = try await LibraryFixture.store()
        let shared = controller(store)
        try await store.addTag(bookKey: "/works/OL1W", name: "Favorites")
        try await store.addTag(bookKey: "/works/OL2W", name: "Favorites")
        let model = TagBooksModel(name: "Favorites", store: store, controller: shared)
        await model.load()
        #expect(model.list.books.count == 2)
        #expect(model.total == 2)
        await model.setStatus(key: "/works/OL1W", to: .reading)
        #expect(model.list.books.first { $0.key == "/works/OL1W" }?.status == .reading)
        _ = try await shared.addTag(named: "Favorites", to: "/works/OL3W")
        #expect(model.needsReload)
        await model.reloadIfNeeded()
        #expect(model.total == 3 && model.list.books.count == 3)
    }

    @Test("AppSession shares one controller")
    func session() async throws {
        let store = try await LibraryFixture.store()
        let session = AppSession(store: store)
        await session.library.start()
        let detail = BookDetailModel(key: "/works/OL1W", store: store, userData: session.userData)
        await detail.load()
        await detail.addTag("Shared")
        for _ in 0..<20 where session.tags.state.value == nil { await Task.yield() }
        await session.tags.load()
        #expect(session.tags.state.value?.map(\.name) == ["Shared"])
        await session.library.settleUserDataChanges()
        #expect(session.library.tags.map(\.name) == ["Shared"])
    }
}
