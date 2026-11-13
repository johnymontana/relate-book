import Testing
import Foundation
@testable import RelateBooksCore

@Suite("Launch options and view models")
struct NavigationAndModelTests {
    @Test("launch arguments become routes, in order; unknown ones are ignored")
    func parse() {
        let options = LaunchOptions.parse([
            "/path/RelateBooks", "-NSDocumentRevisionsDebugMode", "YES",
            "--open-book", "/works/OL17876078W",
            "--open-author", "/authors/OL31353A",
            "--open-term", "series=Hainish Cycle",
            "--open-term", "bogus=x",
            "--open-book",
        ])
        #expect(options.routes == [
            .book(key: "/works/OL17876078W"),
            .author(key: "/authors/OL31353A"),
            .term(kind: .series, name: "Hainish Cycle"),
        ])
        #expect(LaunchOptions.parse(["app"]).routes.isEmpty)
        #expect(LaunchOptions.parse(["app", "--open-book", "amazon:B0X"]).routes == [.book(key: "amazon:B0X")])
    }

    @Test("--reset-user-data and --open-tab")
    func userDataLaunchFlags() {
        let options = LaunchOptions.parse(["app", "--reset-user-data", "--open-tab", "tags", "--open-book", "/works/OL1W"])
        #expect(options.resetUserData)
        #expect(options.initialTab == .tags)
        #expect(options.routes == [.book(key: "/works/OL1W")])
        let bogus = LaunchOptions.parse(["app", "--open-tab", "bogus", "--open-book", "/works/OL2W"])
        #expect(bogus.initialTab == nil)
        #expect(bogus.routes == [.book(key: "/works/OL2W")])
        let none = LaunchOptions.parse(["app"])
        #expect(none.resetUserData == false && none.initialTab == nil)
        #expect(LaunchOptions.parse(["app", "--open-tab", "library"]).initialTab == .library)
    }

    @Test("--open-tab search, --search, --wait-for-index, --reset-embeddings")
    func searchLaunchFlags() {
        let tab = LaunchOptions.parse(["app", "--open-tab", "search"])
        #expect(tab.initialTab == .search && tab.searchText == nil && !tab.waitForIndex && !tab.resetEmbeddings)
        let search = LaunchOptions.parse(["app", "--search", "lonely astronaut saves earth", "--wait-for-index", "--reset-embeddings"])
        #expect(search.searchText == "lonely astronaut saves earth")
        #expect(search.initialTab == .search)
        #expect(search.waitForIndex && search.resetEmbeddings)
        let explicit = LaunchOptions.parse(["app", "--open-tab", "library", "--search", "x y"])
        #expect(explicit.initialTab == .library && explicit.searchText == "x y")
        let empty = LaunchOptions.parse(["app", "--search", "", "--open-book", "/works/OL1W"])
        #expect(empty.searchText == nil && empty.initialTab == nil)
        #expect(empty.routes == [.book(key: "/works/OL1W")])
        #expect(AppTab(rawValue: "search") == .search)
    }

    @MainActor
    @Test("AppSession without an embedder: indexing unavailable, keyword-only search")
    func sessionWithoutEmbedder() async throws {
        let store = try await LibraryFixture.store()
        let session = AppSession(store: store)
        #expect(session.embedder == nil)
        #expect(session.indexing.progress.phase == .unavailable)
        session.indexing.start()
        #expect(session.indexing.progress.phase == .unavailable)
        #expect(session.searchService.embedder == nil)
        let detail = session.bookDetailModel(key: "/works/OL1W")
        await detail.loadSimilar()
        #expect(detail.similar.value == [])                 // not embedded: an empty list, no error
    }

    @MainActor
    @Test("BookDetailModel loads More like this once, and only with a search service")
    func detailSimilar() async throws {
        let store = try await SearchServiceTests.store()
        let plain = BookDetailModel(key: "/works/S1W", store: store)
        await plain.loadSimilar()
        if case .idle = plain.similar {} else { Issue.record("expected idle without a search service") }
        let controller = UserDataController(store: store)
        let model = BookDetailModel(key: "/works/S1W", store: store, userData: controller,
                                    search: SearchService(store: store, embedder: FakeEmbedder()))
        await model.loadSimilar()
        let similar = try #require(model.similar.value)
        #expect(similar.count == 7 && !similar.contains { $0.key == "/works/S1W" })
        let other = try #require(similar.first)
        _ = try await controller.setStatus(key: other.key, to: .reading)
        #expect(model.similar.value?.first?.status == .reading)
        await model.loadSimilar(force: true)
        #expect(model.similar.value?.count == 7)
    }

    @Test("status defaults to want; titles fold case and diacritics")
    func smallHelpers() {
        #expect(ReadingStatus(graphValue: nil) == .want)
        #expect(ReadingStatus(graphValue: "bogus") == .want)
        #expect(ReadingStatus(graphValue: "read") == .read)
        #expect(BookTitles.subtitle(bookTitle: "L’étranger", itemTitle: "L'Etranger") == nil)
        #expect(BookTitles.subtitle(bookTitle: "Dune", itemTitle: "Dune: Deluxe Edition") == nil)
        #expect(BookTitles.subtitle(bookTitle: "Архипелаг ГУЛАГ", itemTitle: "The Gulag Archipelago") == "The Gulag Archipelago")
        #expect(PriceFormat.string(price: 9.5, currency: "USD", text: "x") == "$9.50")
        #expect(PriceFormat.string(price: nil, currency: nil, text: nil) == nil)
        #expect(LibraryFilter(text: "   ").isEmpty)
        #expect(LibraryFilter(text: " a ").normalizedText == nil)     // one letter does not search
        #expect(LibraryFilter(text: " Le ").normalizedText == "le")
        #expect(LibraryFilter(format: "Paperback", unresolvedOnly: true).activeCount == 2)
    }

    @MainActor
    @Test("LibraryModel loads pages, filters, sorts and searches")
    func libraryModel() async throws {
        let store = try await LibraryFixture.store()
        try await LibraryFixture.addFillers(60, to: store)
        let model = LibraryModel(store: store)
        model.searchDebounce = .zero
        await model.start()
        #expect(model.list.books.count == 40)
        #expect(model.total == 65)
        #expect(model.totalBooks == 65)
        #expect(model.formats.first?.name == "Paperback")

        await model.list.loadMoreIfNeeded(current: model.list.books[35])
        #expect(model.list.books.count == 65)
        #expect(model.list.reachedEnd)
        await model.list.loadNextPage()                      // no-op at the end
        #expect(model.list.books.count == 65)

        await model.toggleUnresolved()
        #expect(model.list.books.map(\.key) == ["amazon:B000UNRES"])
        #expect(model.total == 1)
        await model.toggleUnresolved()

        await model.setSort(.wishlist)
        #expect(model.list.books.first?.key == "/works/OL1W")

        model.setSearchText("camus")
        await model.settleSearch()
        #expect(model.list.books.map(\.key) == ["/works/OL5W"])
        #expect(model.filter.text == "camus")

        await model.toggleFormat("Kindle Edition")
        #expect(model.list.books.isEmpty)
        #expect(model.total == 0)
        await model.clearFilters()
        #expect(model.filter.format == nil && model.filter.text == "camus")
    }

    @MainActor
    @Test("detail models load, and report a missing entity as loaded(nil)")
    func detailModels() async throws {
        let store = try await LibraryFixture.store()
        let book = BookDetailModel(key: "/works/OL1W", store: store)
        await book.load()
        #expect(book.state.value??.title == "Apple Orchards")
        let missing = BookDetailModel(key: "/works/NOPE", store: store)
        await missing.load()
        if case .loaded(let value) = missing.state { #expect(value == nil) } else { Issue.record("expected loaded(nil)") }

        let author = AuthorModel(key: "/authors/OL4A", store: store)
        await author.load()
        #expect(author.state.value??.books.map(\.key) == ["/works/OL5W"])

        let term = TermModel(kind: .series, name: "Orchard Cycle", store: store)
        await term.load()
        #expect(term.list.books.map(\.key) == ["/works/OL3W", "/works/OL1W"])
        #expect(term.summary?.bookCount == 2)
    }
}
