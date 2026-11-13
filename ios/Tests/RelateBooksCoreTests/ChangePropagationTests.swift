import Testing
import Foundation
import Relate
@testable import RelateBooksCore

@Suite("Change propagation (phase 5)")
@MainActor
struct ChangePropagationTests {
    static func manualDraft(_ title: String = "Apple Pie Atlas") throws -> ImportDraft {
        try ImportDraft.manual(title: title, authors: "Jane Doe", uuid: UUID())
    }

    @Test("Library: facets and total reload at once, the list on reloadIfNeeded")
    func library() async throws {
        let store = try await LibraryFixture.store()
        let controller = UserDataController(store: store)
        let library = LibraryModel(store: store, userData: controller)
        await library.start()
        #expect(library.totalBooks == 5 && !library.needsReload)
        let draft = try Self.manualDraft()
        _ = try await controller.saveImportedBook(draft)
        await library.settleUserDataChanges()
        #expect(library.needsReload && library.totalBooks == 6)
        await library.reloadIfNeeded()
        #expect(library.list.books.contains { $0.key == draft.key && $0.trailingText == "Added in app" })
        #expect(!library.needsReload)
    }

    @Test("Search: a book added while a query is active marks it for a rerun")
    func search() async throws {
        let store = try await EmbeddingFixture.store(EmbeddingFixture.searchBooks)
        let controller = UserDataController(store: store)
        let idle = SearchModel(service: SearchService(store: store, embedder: nil), userData: controller)
        let search = SearchModel(service: SearchService(store: store, embedder: nil), userData: controller)
        search.submit("money")
        await search.settle()
        #expect(search.state.value?.results.count == 1)
        _ = try await controller.saveImportedBook(try Self.manualDraft("The Money Atlas"))
        #expect(search.needsRerun && !idle.needsRerun)
        await search.rerunIfNeeded()
        #expect(search.state.value?.results.contains { $0.book.title == "The Money Atlas" && $0.book.isAppAdded } == true)
    }

    @Test("Search: an embed landing after the add re-runs the active query (session wiring)")
    func searchRerunsOnEmbed() async throws {
        let store = try await EmbeddingFixture.store(EmbeddingFixture.searchBooks)
        let session = AppSession(store: store, embedder: FakeEmbedder(),
                                 openLibrary: OpenLibraryClient(transport: FakeTransport([:])),
                                 geocoder: StubPlaceGeocoder())
        let idle = SearchModel(service: SearchService(store: store, embedder: nil))
        await idle.bookDidEmbed(key: "x")
        #expect(idle.searchCount == 0)
        session.search.submit("money")
        await session.search.settle()
        let draft = try Self.manualDraft("The Money Atlas")
        _ = try await session.userData.saveImportedBook(draft)
        // The rerun for .bookAdded is consumed (as when the Search tab
        // appears) before the embed finishes.
        await session.search.rerunIfNeeded()
        #expect(!session.search.needsRerun)
        let before = session.search.searchCount
        #expect(await session.indexing.embedBook(key: draft.key) == .embedded)
        #expect(await waitUntil { session.search.searchCount == before + 1 })
        await session.search.settle()
        #expect(session.search.state.value?.results.contains { $0.book.key == draft.key } == true)
    }

    @Test("Map: reloads on .placesLocated / .bookAdded / .reset once loaded, never before")
    func map() async throws {
        let store = try await GraphStore.inMemory()
        try await store.query("CREATE (:Place {name: 'Gloucester (Mass.)'})")
        let controller = UserDataController(store: store)
        let unloaded = MapModel(store: store, userData: controller)
        let map = MapModel(store: store, userData: controller)
        await map.start()
        #expect(map.queryCount == 1)
        let outcomes = await controller.locatePlaces(["Gloucester (Mass.)"],
                                                     with: PlaceLocator(store: store, geocoder: StubPlaceGeocoder()))
        #expect(outcomes.first?.label == "Gloucester")
        #expect(await waitUntil { map.queryCount == 2 })
        await map.settle()
        _ = try await controller.saveImportedBook(try Self.manualDraft())
        #expect(await waitUntil { map.queryCount == 3 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(unloaded.queryCount == 0)
    }

    @Test("locatePlaces publishes unique labels only when something was located")
    func placesLocated() async throws {
        let store = try await GraphStore.inMemory()
        try await store.query("UNWIND ['Gloucester (Mass.)', 'Gethen', 'Nowhere'] AS n CREATE (:Place {name: n})")
        let controller = UserDataController(store: store)
        let recorder = ChangeRecorder(controller)
        let locator = PlaceLocator(store: store, geocoder: StubPlaceGeocoder())
        var progress: [[Int]] = []
        _ = await controller.locatePlaces(["Gethen", "Nowhere"], with: locator) { progress.append([$0, $1]) }
        #expect(recorder.changes.isEmpty && progress == [[1, 2], [2, 2]])
        _ = await controller.locatePlaces(["Gloucester (Mass.)"], with: locator)
        #expect(recorder.changes == [.placesLocated(labels: ["Gloucester"])])
    }

    @Test("an existing book publishes nothing; a detail for another key ignores the change")
    func noChange() async throws {
        let store = try await LibraryFixture.store()
        let controller = UserDataController(store: store)
        let recorder = ChangeRecorder(controller)
        let detail = BookDetailModel(key: "/works/OL1W", store: store, userData: controller)
        await detail.load()
        let hijack = ImportDraft(key: "/works/OL1W", match: .manual, title: "X", properties: ["title": .string("X")],
                                 authors: [], terms: ImportTerms())
        #expect(try await controller.saveImportedBook(hijack) == .existing(key: "/works/OL1W"))
        #expect(recorder.changes.isEmpty)
        _ = try await controller.saveImportedBook(try Self.manualDraft())
        #expect(recorder.addedKeys.count == 1)
        guard case .loaded(let book?) = detail.state else { Issue.record("detail not loaded"); return }
        #expect(book.title == "Apple Orchards")
    }

    @Test("embedBook after a complete index bumps the counters and sets lastEmbeddedBookKey")
    func indexCounters() async throws {
        let store = try await EmbeddingFixture.store()
        let controller = UserDataController(store: store)
        let indexing = IndexingModel(indexer: EmbeddingIndexer(store: store, embedder: FakeEmbedder()), userData: controller)
        indexing.start()
        await indexing.waitUntilIdle()
        #expect(indexing.isComplete && indexing.progress.totalBooks == 10)
        let draft = try Self.manualDraft()
        _ = try await controller.saveImportedBook(draft)
        #expect(await indexing.embedBook(key: draft.key) == .embedded)
        #expect(indexing.progress.totalBooks == 11 && indexing.progress.embeddedBooks == 11)
        #expect(indexing.lastEmbeddedBookKey == draft.key)
        #expect(await indexing.embedBook(key: draft.key) == .notNeeded)
        #expect(indexing.progress.totalBooks == 11)
        #expect(await IndexingModel(indexer: nil).embedBook(key: draft.key) == .unavailable)
    }

    @Test("embedBook stops waiting after its timeout; the embed still lands")
    func embedTimeout() async throws {
        let store = try await EmbeddingFixture.store()
        let embedder = GatedEmbedder(pauseAfter: 0)
        let indexing = IndexingModel(indexer: EmbeddingIndexer(store: store, embedder: embedder))
        let draft = try Self.manualDraft()
        _ = try await store.saveImport(draft, now: Date())
        #expect(await indexing.embedBook(key: draft.key, timeout: .milliseconds(1)) == .timedOut)
        #expect(indexing.lastEmbeddedBookKey == nil)
        await embedder.release()
        await indexing.waitUntilIdle()
        #expect(indexing.lastEmbeddedBookKey == draft.key)
        #expect(try await EmbeddingFixture.embeddedBooks(store) == 1)
    }
}
