import Testing
import Foundation
import Relate
@testable import RelateBooksCore

/// The add-book state machine on an in-memory store (LibraryFixture plus
/// Project Hail Mary with Item isbn13 9780593135204 and a located "New
/// England", as in books.rl), the stub transport or
/// a FakeTransport, the stub geocoder and a FakeEmbedder indexer.
@MainActor
struct AddBookHarness {
    let store: GraphStore
    let controller: UserDataController
    let indexing: IndexingModel?
    let geocoder: StubPlaceGeocoder
    let model: AddBookModel
    let recorder: ChangeRecorder

    static let phm = "/works/OL21745884W"

    static func make(transport: any HTTPTransport = StubOpenLibraryTransport(latency: .zero),
                     geocoder: StubPlaceGeocoder = StubPlaceGeocoder(),
                     withIndexer: Bool = true, indexing: IndexingModel?? = nil,
                     placesBudget: Duration = .seconds(20), scanCooldown: Duration = .seconds(10),
                     simulatedScan: String? = nil) async throws -> AddBookHarness {
        let store = try await LibraryFixture.store()
        try await store.query("""
            CREATE (b:Book {key: '/works/OL21745884W', title: 'Project Hail Mary'})
            CREATE (i:Item {asin: 'PHM1', isbn13: '9780593135204', isbn10: '0593135202', format: 'Hardcover'})-[:EDITION_OF]->(b)
            CREATE (:Place {name: 'New England', location: point({latitude: 43.97, longitude: -71.31}),
                            geocoded_label: 'New England', geo_status: 'ok'})
            """)
        let controller = UserDataController(store: store)
        let index: IndexingModel?
        if let indexing {
            index = indexing
        } else {
            index = IndexingModel(indexer: withIndexer ? EmbeddingIndexer(store: store, embedder: FakeEmbedder()) : nil,
                                  userData: controller)
        }
        let importer = BookImporter(client: OpenLibraryClient(transport: transport, minimumInterval: .zero), store: store)
        let model = AddBookModel(importer: importer, controller: controller,
                                 locator: PlaceLocator(store: store, geocoder: geocoder), indexing: index,
                                 placesBudget: placesBudget, scanCooldown: scanCooldown, simulatedScan: simulatedScan)
        model.searchDebounce = .milliseconds(10)
        return AddBookHarness(store: store, controller: controller, indexing: index, geocoder: geocoder, model: model,
                              recorder: ChangeRecorder(controller))
    }

    func appBooks() async throws -> Int {
        try await EmbeddingFixture.count(store, "MATCH (b:Book {source: 'app'}) RETURN count(b) AS c")
    }

    func waitFor(_ phase: AddBookModel.Phase) async -> Bool {
        await waitUntil { model.phase == phase }
    }
}

@Suite("Add book model")
@MainActor
struct AddBookModelTests {
    static let fullSequence: [AddBookModel.Phase] = [
        .editing, .importing(.checkingLibrary), .importing(.lookingUp), .importing(.saving),
        .importing(.locatingPlaces(done: 0, total: 2)), .importing(.locatingPlaces(done: 1, total: 2)),
        .importing(.locatingPlaces(done: 2, total: 2)), .importing(.indexing),
    ]

    @Test("search: under 3 characters is idle; a newer query replaces one still debouncing")
    func search() async throws {
        let transport = StubOpenLibraryTransport(latency: .zero)
        let h = try await AddBookHarness.make(transport: transport)
        h.model.setSearchText("pe")
        await h.model.settle()
        #expect(h.model.searchResults.value == nil && !h.model.searchResults.isLoading)
        #expect(await transport.requestedURLs.isEmpty)
        h.model.setSearchText("perf")
        h.model.setSearchText("perfect storm")
        await h.model.settle()
        #expect(h.model.searchResults.value?.count == 19)
        let urls = await transport.requestedURLs
        #expect(urls.count == 1 && FakeTransport.key(urls[0]) == "/search.json?q=perfect storm")
        #expect(h.model.inLibraryKeys.isEmpty)
        h.model.setSearchText("p")
        #expect(h.model.searchResults.value == nil)
    }

    @Test("search results in the library are marked, and choosing one opens it")
    func inLibraryBadge() async throws {
        let transport = FakeTransport(["/search.json?q=project hail mary": [.fixture("search-isbn-phm.json")]])
        let h = try await AddBookHarness.make(transport: transport)
        h.model.setSearchText("project hail mary")
        await h.model.settle()
        let doc = try #require(h.model.searchResults.value?.first)
        #expect(h.model.inLibraryKeys == [AddBookHarness.phm])
        h.model.choose(doc)
        #expect(h.model.pendingConfirmation == nil)
        #expect(h.model.phase == .finished(.already(key: AddBookHarness.phm, title: "Project Hail Mary")))
        #expect(await transport.requestCount == 1)
    }

    @Test("typed ISBN: the full pipeline, its changes and the embed")
    func isbnPipeline() async throws {
        let h = try await AddBookHarness.make()
        h.model.setISBNText("978-0-393-33701-3")
        #expect(h.model.isbnValidation.message == "Valid ISBN-13")
        h.model.submitISBN()
        await h.model.settle()
        let result = try #require(h.model.result)
        #expect(Array(h.model.phaseHistory.dropLast()) == Self.fullSequence)
        #expect(result.key == PerfectStorm.key && !result.alreadyInLibrary && result.title == "The Perfect Storm")
        #expect(result.newPlaces == 2 && result.locatedPlaces == 2 && !result.placesPending && result.embed == .embedded)
        #expect(h.recorder.addedKeys == [PerfectStorm.key])
        let addedIndex = try #require(h.recorder.changes.firstIndex(of: .bookAdded(key: PerfectStorm.key)))
        let placesIndex = try #require(h.recorder.changes.firstIndex { if case .placesLocated = $0 { true } else { false } })
        #expect(addedIndex < placesIndex)
        #expect(Set(h.recorder.placesLocatedLabels.first ?? []) == ["Gloucester", "North Atlantic Ocean"])
        let row = try await h.store.query("MATCH (b:Book {key: $k}) RETURN b.embedding_model AS m, b.match AS match",
                                          ["k": .string(PerfectStorm.key)]).rowsView[0]
        #expect(row.string("m") == FakeEmbedder().modelID && row.string("match") == "isbn")
        #expect(h.indexing?.lastEmbeddedBookKey == PerfectStorm.key)
        #expect(!h.model.isBusy && h.model.progressText == nil)
    }

    @Test("an ISBN already in the library finishes locally, with no request")
    func alreadyLocal() async throws {
        let transport = StubOpenLibraryTransport(latency: .zero)
        let h = try await AddBookHarness.make(transport: transport)
        h.model.setISBNText("9780593135204")
        h.model.submitISBN()
        await h.model.settle()
        #expect(h.model.phase == .finished(.already(key: AddBookHarness.phm, title: "Project Hail Mary")))
        #expect(await transport.requestedURLs.isEmpty)
        #expect(try await h.appBooks() == 0)
    }

    @Test("search import: confirm, save without edition facts")
    func searchImport() async throws {
        let h = try await AddBookHarness.make()
        h.model.setSearchText("perfect storm")
        await h.model.settle()
        let doc = try #require(h.model.searchResults.value?.first)
        h.model.choose(doc)
        #expect(h.model.pendingConfirmation == doc && h.model.phase == .editing)
        h.model.cancelPending()
        #expect(h.model.pendingConfirmation == nil)
        h.model.choose(doc)
        h.model.confirmPending()
        await h.model.settle()
        #expect(h.model.result?.key == PerfectStorm.key && h.model.result?.alreadyInLibrary == false)
        let detail = try #require(try await h.store.bookDetail(key: PerfectStorm.key))
        #expect(detail.importMatch == .search && detail.appEdition == nil)
        #expect(AddedInAppText.line(addedOn: detail.addedOn, match: detail.importMatch).hasSuffix("· Open Library search"))
    }

    @Test("manual entry")
    func manual() async throws {
        let h = try await AddBookHarness.make()
        #expect(!h.model.canSubmitManual)
        h.model.manualTitle = "Field Notes from the Bitterroot"
        h.model.manualAuthors = "Jane Doe, Rana Foroohar"
        #expect(h.model.canSubmitManual)
        h.model.submitManual()
        await h.model.settle()
        let result = try #require(h.model.result)
        #expect(result.key.hasPrefix("manual:") && result.title == "Field Notes from the Bitterroot" && result.newPlaces == 0)
        let detail = try #require(try await h.store.bookDetail(key: result.key))
        #expect(detail.source == "app" && detail.importMatch == .manual && detail.authors.count == 2)
        #expect(!h.model.phaseHistory.contains(.importing(.lookingUp)))
    }

    @Test("not found fails with the D32 text; retry reruns the request")
    func notFoundAndRetry() async throws {
        let transport = FakeTransport(FakeTransport.perfectStormRoutes())
        await transport.setRoute("/search.json?q=isbn:9798999999993", [.fixture("search-notfound.json")])
        let h = try await AddBookHarness.make(transport: transport)
        h.model.setISBNText("9798999999993")
        h.model.submitISBN()
        await h.model.settle()
        #expect(h.model.errorText == "No Open Library record for ISBN 9798999999993. Check the number, or add the book manually.")
        await transport.setRoute("/search.json?q=isbn:9798999999993", [.fixture("search-isbn13.json")])
        h.model.retry()
        await h.model.settle()
        #expect(h.model.result?.key == PerfectStorm.key)
        let detail = try #require(try await h.store.bookDetail(key: PerfectStorm.key))
        #expect(detail.appEdition?.isbn13 == "9798999999993")
    }

    @Test("cancel while looking up: back to editing, nothing written")
    func cancel() async throws {
        let transport = FakeTransport(FakeTransport.perfectStormRoutes())
        await transport.hold()
        let h = try await AddBookHarness.make(transport: transport)
        h.model.setISBNText("9780393337013")
        h.model.submitISBN()
        #expect(await h.waitFor(.importing(.lookingUp)))
        #expect(await waitUntil { await transport.requestCount == 1 })
        #expect(!h.model.isScannerActive && h.model.isBusy && h.model.progressText == "Looking up…")
        h.model.cancel()
        #expect(h.model.phase == .editing && h.model.isbnText == "9780393337013")
        await transport.release()
        await h.model.settle()
        #expect(h.model.phase == .editing)
        #expect(try await h.appBooks() == 0)
    }

    @Test("an invalid ISBN cannot be submitted")
    func invalid() async throws {
        let transport = StubOpenLibraryTransport(latency: .zero)
        let h = try await AddBookHarness.make(transport: transport)
        h.model.setISBNText("9780393337014")
        #expect(h.model.isbnValidation == .badChecksum)
        h.model.submitISBN()
        await h.model.settle()
        #expect(h.model.phase == .editing && h.model.phaseHistory == [.editing])
        #expect(await transport.requestedURLs.isEmpty)
    }

    @Test("a non-book barcode only shows a message")
    func nonBookBarcode() async throws {
        let h = try await AddBookHarness.make()
        h.model.didScan(payload: "4006381333931")
        #expect(h.model.scannerMessage == "Not a book barcode." && h.model.phase == .editing)
    }

    @Test("scanned ISBN: same pipeline, saved as an ISBN scan")
    func scannedPipeline() async throws {
        let h = try await AddBookHarness.make()
        h.model.didScan(payload: "9780393337013")
        await h.model.settle()
        #expect(Array(h.model.phaseHistory.dropLast()) == Self.fullSequence)
        #expect(h.model.result?.newPlaces == 2)
        let detail = try #require(try await h.store.bookDetail(key: PerfectStorm.key))
        #expect(detail.importMatch == .isbn && detail.appEdition?.isbn13 == "9780393337013")
        #expect(AddedInAppText.line(addedOn: detail.addedOn, match: detail.importMatch).contains("ISBN scan"))
    }

    @Test("scan loop guard: a failed payload is not retried by the scanner")
    func scanLoopGuard() async throws {
        let transport = StubOpenLibraryTransport(latency: .zero)
        let h = try await AddBookHarness.make(transport: transport)
        h.model.didScan(payload: "9798999999993")
        await h.model.settle()
        guard case .failed = h.model.phase else { Issue.record("expected failed"); return }
        let chain = await transport.requestedURLs.count
        #expect(chain == 2)
        h.model.didScan(payload: "9798999999993")
        await h.model.settle()
        guard case .failed = h.model.phase else { Issue.record("expected still failed"); return }
        h.model.reset()
        h.model.didScan(payload: "9798999999993")
        await h.model.settle()
        #expect(h.model.phase == .editing)
        #expect(await transport.requestedURLs.count == chain)

        let shortTransport = StubOpenLibraryTransport(latency: .zero)
        let short = try await AddBookHarness.make(transport: shortTransport, scanCooldown: .milliseconds(50))
        short.model.didScan(payload: "9798999999993")
        await short.model.settle()
        try await Task.sleep(for: .milliseconds(100))
        short.model.reset()
        short.model.didScan(payload: "9798999999993")
        await short.model.settle()
        #expect(await shortTransport.requestedURLs.count == 2 * chain)
    }

    @Test("didScan is ignored outside editing")
    func didScanWhileBusy() async throws {
        let transport = FakeTransport(FakeTransport.perfectStormRoutes())
        await transport.hold()
        let h = try await AddBookHarness.make(transport: transport)
        #expect(h.model.isScannerActive)
        h.model.didScan(payload: "9780393337013")
        #expect(await h.waitFor(.importing(.lookingUp)))
        h.model.didScan(payload: "9780593135204")
        h.model.didScan(payload: "9798999999993")
        await transport.release()
        await h.model.settle()
        #expect(h.model.result?.key == PerfectStorm.key)
        #expect(try await h.appBooks() == 1)
        #expect(!h.model.isScannerActive)
        h.model.reset()
        #expect(h.model.isScannerActive)
    }

    @Test("a double submit in one turn starts one import: busy at once, one request chain")
    func doubleSubmit() async throws {
        let transport = FakeTransport(FakeTransport.perfectStormRoutes())
        let h = try await AddBookHarness.make(transport: transport)
        h.model.setISBNText("9780393337013")
        h.model.submitISBN()
        #expect(h.model.isBusy && h.model.progressText == "Checking your library…")
        #expect(!h.model.isScannerActive)
        h.model.submitISBN()
        h.model.didScan(payload: "9798999999993")
        h.model.manualTitle = "Something Else"
        #expect(!h.model.canSubmitManual)
        h.model.submitManual()
        await h.model.settle()
        #expect(h.model.result?.key == PerfectStorm.key)
        #expect(h.model.phaseHistory.filter { $0 == .importing(.checkingLibrary) }.count == 1)
        #expect(Array(h.model.phaseHistory.dropLast()) == Self.fullSequence)
        let keys = await transport.paths
        #expect(Set(keys).count == keys.count)
        #expect(try await h.appBooks() == 1)
    }

    @Test("manual entry goes straight to saving, recorded once")
    func manualSavingOnce() async throws {
        let h = try await AddBookHarness.make()
        h.model.manualTitle = "Field Notes"
        h.model.submitManual()
        #expect(h.model.isBusy && h.model.progressText == "Saving…")
        await h.model.settle()
        #expect(h.model.phaseHistory.filter { $0 == .importing(.saving) }.count == 1)
        #expect(h.model.result?.title == "Field Notes")
    }

    @Test("isScannerActive is false once failed")
    func scannerInactiveWhenFailed() async throws {
        let h = try await AddBookHarness.make()
        h.model.setISBNText("9798999999993")
        h.model.submitISBN()
        await h.model.settle()
        #expect(h.model.errorText != nil && !h.model.isScannerActive)
    }

    @Test("the simulated scan payload is handed out once")
    func simulatedScan() async throws {
        let h = try await AddBookHarness.make(simulatedScan: "9780393337013")
        #expect(h.model.takeSimulatedScan() == "9780393337013")
        #expect(h.model.takeSimulatedScan() == nil)
        #expect(try await AddBookHarness.make().model.takeSimulatedScan() == nil)
    }

    @Test("places budget: the flow moves on, geocoding finishes in the background")
    func placesBudget() async throws {
        let h = try await AddBookHarness.make(geocoder: StubPlaceGeocoder(delay: .milliseconds(200)),
                                              placesBudget: .milliseconds(50))
        h.model.setISBNText("9780393337013")
        h.model.submitISBN()
        #expect(await waitUntil(timeout: .seconds(10)) { h.model.result != nil })
        let result = try #require(h.model.result)
        #expect(result.placesPending && result.locatedPlaces < 2)
        await h.model.settle()
        #expect(try await h.store.placeLocation(name: "Gloucester (Mass.)").isOnMap)
        #expect(try await h.store.placeLocation(name: "North Atlantic Ocean").isOnMap)
        #expect(!h.recorder.placesLocatedLabels.isEmpty)
        // A late progress report never replaces the finished phase.
        #expect(h.model.phase == .finished(result))
    }

    @Test("step labels (D25)")
    func labels() {
        typealias S = AddBookModel.Step
        #expect(S.locatingPlaces(done: 0, total: 2).label == "Locating places… 1 of 2")
        #expect(S.locatingPlaces(done: 1, total: 2).label == "Locating places… 2 of 2")
        #expect(S.locatingPlaces(done: 2, total: 2).label == "Locating places… 2 of 2")
        #expect(S.checkingLibrary.label == "Checking your library…")
        #expect(S.lookingUp.label == "Looking up…")
        #expect(S.saving.label == "Saving…")
        #expect(S.indexing.label == "Indexing…")
        #expect(AddBookModel.Mode.allCases.map(\.title) == ["Search", "Scan", "Manual"])
    }

    @Test("without an embedding model the indexing step is skipped")
    func noIndexer() async throws {
        for harness in [try await AddBookHarness.make(withIndexer: false), try await AddBookHarness.make(indexing: .some(nil))] {
            harness.model.didScan(payload: "9780393337013")
            await harness.model.settle()
            #expect(harness.model.result?.embed == .unavailable)
            #expect(!harness.model.phaseHistory.contains(.importing(.indexing)))
        }
    }
}
