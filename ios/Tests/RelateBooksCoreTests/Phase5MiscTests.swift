import Testing
import Foundation
import Relate
@testable import RelateBooksCore

@Suite("Phase 5 navigation, text and embedding")
struct Phase5MiscTests {
    @Test("launch flags --stub-network and --simulate-scan")
    func launchOptions() {
        #expect(LaunchOptions.parse(["app", "--stub-network"]).stubNetwork)
        #expect(!LaunchOptions.parse(["app"]).stubNetwork)
        let scan = LaunchOptions.parse(["app", "--stub-network", "--simulate-scan", "9780393337013"])
        #expect(scan.stubNetwork && scan.simulateScan == "9780393337013")
        #expect(LaunchOptions.parse(["app", "--simulate-scan"]).simulateScan == nil)
        let mixed = LaunchOptions.parse(["app", "--reset-user-data", "--stub-network", "--open-tab", "map"])
        #expect(mixed.resetUserData && mixed.stubNetwork && mixed.initialTab == .map)
    }

    @Test("term targets: the extension's label/rel pairs in order")
    func termTargets() {
        #expect(ImportQueries.termTargets.map(\.label) == ["Subject", "Place", "Person", "Era", "Genre"])
        #expect(ImportQueries.termTargets.map(\.relationship) == ["ABOUT", "SET_IN", "FEATURES", "SET_DURING", "IN_GENRE"])
        let terms = ImportTerms(subjects: ["s"], places: ["p"], people: ["h"], eras: ["e"], genres: ["g"])
        #expect(TermTarget.allCases.map { $0.names(in: terms) } == [["s"], ["p"], ["h"], ["e"], ["g"]])
    }

    @Test("save statements: W1, W2 only with authors, W3 only for non-empty lists")
    func saveStatements() throws {
        let draft = try PerfectStorm.draft()
        let statements = ImportQueries.saveStatements(draft, now: Date(timeIntervalSince1970: 0))
        #expect(statements.count == 4)
        #expect(statements[0].cypher.hasPrefix("MERGE (b:Book {key: $key})"))
        #expect(statements[2].cypher.contains("MERGE (t:Subject {name: name})") && statements[3].cypher.contains("[:SET_IN]"))
        #expect(statements.allSatisfy { !$0.cypher.contains("DELETE") })
        #expect(statements[0].parameters["now"] == .string("1970-01-01T00:00:00.000Z"))
        let manual = try ImportDraft.manual(title: "T", authors: "", uuid: UUID())
        #expect(ImportQueries.saveStatements(manual, now: Date()).count == 1)
    }

    @Test("routes and notices")
    func routes() {
        let a = Route.addedBook(key: "/works/OL2670211W", notice: .added)
        #expect(Set([a, a, .addedBook(key: "/works/OL2670211W", notice: .alreadyInLibrary), .addBook]).count == 3)
        #expect(AddedBookNotice.added.text == "Added to your library")
        #expect(AddedBookNotice.alreadyInLibrary.text == "Already in your library")
    }

    @Test("Added in app text (D33)")
    func addedInAppText() throws {
        let date = try Date("2026-11-08T20:30:00.123Z", strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true))
        let utc = TimeZone(identifier: "UTC")!
        #expect(AddedInAppText.line(addedOn: date, match: .isbn, timeZone: utc) == "Added Nov 8, 2026 · ISBN scan")
        #expect(AddedInAppText.line(addedOn: date, match: .search, timeZone: utc) == "Added Nov 8, 2026 · Open Library search")
        #expect(AddedInAppText.line(addedOn: date, match: .manual, timeZone: utc) == "Added Nov 8, 2026 · entered manually")
        #expect(AddedInAppText.line(addedOn: date, match: .isbn, timeZone: TimeZone(identifier: "Asia/Tokyo")!) == "Added Nov 9, 2026 · ISBN scan")
        #expect(AddedInAppText.line(addedOn: nil, match: nil) == "Added in app")
        let edition = AppEdition(isbn13: "9780393337013", isbn10: "0393337014", publisher: "W.W. Norton & Company",
                                 publishDate: "2009", publishYear: 2009)
        #expect(AddedInAppText.details(edition) == ["ISBN 9780393337013", "W.W. Norton & Company · 2009"])
        #expect(AddedInAppText.details(AppEdition(pages: 233, physicalFormat: "Paperback")) == ["233 pages", "Paperback"])
        #expect(AddedInAppText.details(nil).isEmpty)
    }

    @Test("row trailing text: price wins, then Added in app")
    func trailingText() {
        #expect(BookSummary(key: "a", title: "A", price: 10, currency: "USD", source: "app").trailingText == "$10.00")
        #expect(BookSummary(key: "b", title: "B", source: "app").trailingText == "Added in app")
        #expect(BookSummary(key: "c", title: "C", source: "amazon").trailingText == nil)
        let app = BookSummary(key: "d", title: "D", source: "app", addedOn: Date(timeIntervalSince1970: 5))
        #expect(app.with(status: .read).isAppAdded && app.with(status: .read).addedOn == app.addedOn)
    }

    @Test("embedBook: writes once, then is fresh; an unknown key loads no model")
    func embedBook() async throws {
        let store = try await EmbeddingFixture.store()
        let embedder = GatedEmbedder()
        let indexer = EmbeddingIndexer(store: store, embedder: embedder)
        #expect(try await indexer.embedBook(key: "/works/NOPE") == false)
        #expect(await embedder.prepareCount == 0)
        #expect(try await indexer.embedBook(key: "/works/E01W") == true)
        #expect(try await indexer.embedBook(key: "/works/E01W") == false)
        #expect(await embedder.prepareCount == 1)
        #expect(await embedder.textCount == 1)
        let input = try #require(try await store.embeddingInput(key: "/works/E01W"))
        #expect(!input.isStale(modelID: embedder.modelID))
        #expect(try await store.embeddingInput(key: "/works/NOPE") == nil)
    }
}
