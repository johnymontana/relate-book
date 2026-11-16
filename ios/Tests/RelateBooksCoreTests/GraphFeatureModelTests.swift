import Testing
import Foundation
import Relate
@testable import RelateBooksCore

@Suite("Graph feature models")
@MainActor
struct GraphFeatureModelTests {
    typealias F = ConnectionFixture

    @Test("Next up loads once, goes stale on a status or rating change, and reads again on the next appearance")
    func nextUpModel() async throws {
        let store = try await F.store()
        let controller = UserDataController(store: store)
        let model = NextUpModel(store: store, userData: controller)
        // A change before the first load is not "stale": the first load sees it anyway.
        _ = try await controller.setRating(key: F.x1, to: 2)
        #expect(!model.needsReload && model.loadCount == 0)
        await model.load()
        #expect(model.loadCount == 1 && model.state.value?.series.isEmpty == true)
        await model.load()
        #expect(model.loadCount == 1)

        _ = try await controller.setStatus(key: F.h1, to: .read)
        _ = try await controller.setRating(key: F.h1, to: 5)
        #expect(model.needsReload)
        // The value on screen stays until the screen appears again.
        #expect(model.state.value?.series.isEmpty == true)
        await model.load()
        #expect(model.loadCount == 2 && !model.needsReload)
        let next = try #require(model.state.value)
        #expect(next.series.map(\.book.key) == [F.h2])
        #expect(next.authors.map(\.authorName) == ["Ursula K. Le Guin"])

        // Tags and notes do not change what is suggested.
        _ = try await controller.addTag(named: "Favorites", to: F.h1)
        _ = try await controller.addNote(text: "A note", to: F.h1)
        #expect(!model.needsReload)
        try await controller.resetUserData()
        #expect(model.needsReload)
        await model.reloadIfNeeded()
        #expect(model.state.value?.series.isEmpty == true && model.loadCount == 3)
    }

    @Test("Near your reading follows the same rules, on the place fixture")
    func nearReadingModel() async throws {
        let store = try await PlaceFixture.store()
        let controller = UserDataController(store: store)
        let model = NearReadingModel(store: store, userData: controller)
        await model.load()
        #expect(model.state.value?.isEmpty == true)
        _ = try await controller.setStatus(key: "/works/B1", to: .read)
        #expect(model.needsReload)
        await model.load()
        // Butte itself, and Montana about 265 km away is outside the 250 km radius.
        #expect(model.state.value?.map(\.label) == ["Butte"])
        #expect(NearReadingModel.radiusMeters == 250_000)
    }

    @Test("Book detail: links to the user's reading, refreshed when another book is read; what similar books share")
    func bookDetailLinks() async throws {
        let store = try await F.store()
        try await EmbeddingIndexer(store: store, embedder: FakeEmbedder()).run()
        let controller = UserDataController(store: store)
        let search = SearchService(store: store, embedder: FakeEmbedder())
        let model = BookDetailModel(key: F.h2, store: store, userData: controller, search: search)
        await model.load()
        #expect(model.readingLinks.isEmpty)

        _ = try await controller.setRating(key: F.h1, to: 5)
        // The change handler reloads in a task; wait for it.
        for _ in 0..<200 where model.readingLinks.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.readingLinks.map(\.connection.kind) == [.series])
        #expect(model.readingLinks.first?.phrase == "Same series as The Left Hand of Darkness, which you rated 5")

        await model.loadSimilar()
        let similar = try #require(model.similar.value)
        #expect(similar.count == 5)
        // The strongest shared node is named; a book that shares only a hub has no caption.
        #expect(model.similarLinks[F.h1]?.shortPhrase == "Same series")
        #expect(model.similarLinks[F.h3]?.shortPhrase == "Same author")
        #expect(model.similarLinks[F.x1] == nil && model.similarLinks[F.w2] == nil)
    }

    @Test("--open-next-up pushes the Next Up screen")
    func launchOption() {
        #expect(LaunchOptions.parse(["app", "--open-next-up"]).routes == [.nextUp])
        #expect(LaunchOptions.parse(["app", "--open-book", "k", "--open-next-up"]).routes == [.book(key: "k"), .nextUp])
    }
}
