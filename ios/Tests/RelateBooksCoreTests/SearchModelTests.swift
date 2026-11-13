import Testing
import Foundation
@testable import RelateBooksCore

@MainActor
@Suite("Search model")
struct SearchModelTests {
    static func model(debounce: Duration = .milliseconds(30)) async throws -> (SearchModel, UserDataController, GraphStore) {
        let store = try await SearchServiceTests.store()
        let controller = UserDataController(store: store)
        let model = SearchModel(service: SearchService(store: store, embedder: FakeEmbedder()), userData: controller)
        model.searchDebounce = debounce
        return (model, controller, store)
    }

    @Test("typing is debounced into one search")
    func debounce() async throws {
        let (model, _, _) = try await Self.model()
        model.setText("as")
        model.setText("astr")
        model.setText("astronaut")
        await model.settle()
        #expect(model.searchCount == 1)
        #expect(model.state.value?.query == "astronaut")
        #expect(model.state.value?.results.first?.book.key == "/works/S1W")
        model.setText("astronaut ")                    // same trimmed text: no new search
        await model.settle()
        #expect(model.searchCount == 1)
    }

    @Test("submit bypasses the debounce and repeats the same text")
    func submit() async throws {
        let (model, _, _) = try await Self.model(debounce: .seconds(60))
        model.submit("astronaut")
        await model.settle()
        #expect(model.state.value?.query == "astronaut")
        model.submit("astronaut")
        await model.settle()
        #expect(model.searchCount == 2)
    }

    @Test("short text clears to idle; a stale response is dropped")
    func shortAndStale() async throws {
        let (model, _, _) = try await Self.model()
        model.setText("a")
        #expect(isIdle(model.state))
        model.submit("astronaut")
        model.setText("a")                             // cleared before the search answered
        await model.settle()
        #expect(isIdle(model.state))
        #expect(model.text == "a")
    }

    @Test("a status change patches the row; with a status filter it asks for a rerun")
    func userDataChanges() async throws {
        let (model, controller, _) = try await Self.model()
        model.submit("pasta recipes")
        await model.settle()
        #expect(model.state.value?.results.first?.book.key == "/works/S6W")
        _ = try await controller.setStatus(key: "/works/S6W", to: .reading)
        #expect(model.state.value?.results.first { $0.book.key == "/works/S6W" }?.book.status == .reading)
        #expect(!model.needsRerun)

        await model.setFilter(SearchFilter(status: .reading))
        #expect(Set(model.state.value?.results.map(\.book.key) ?? []) == ["/works/S3W", "/works/S6W"])
        _ = try await controller.setStatus(key: "/works/S3W", to: .read)
        #expect(model.needsRerun)
        await model.rerunIfNeeded()
        #expect(!model.needsRerun)
        #expect(model.state.value?.results.map(\.book.key) == ["/works/S6W"])
    }

    @Test("editing back to an in-flight query inside the debounce still lands a result")
    func editBackWhileInFlight() async throws {
        let store = try await SearchServiceTests.store()
        let gated = GatedEmbedder(pauseAfter: 0)        // the first query embedding waits for release()
        let model = SearchModel(service: SearchService(store: store, embedder: gated))
        model.searchDebounce = .milliseconds(30)
        model.setText("astronaut")
        await gated.waitUntilPaused()                  // "astronaut" is in flight
        model.setText("astronauts")                    // schedules another search...
        model.setText("astronaut")                     // ...and edits back before its debounce fires
        await gated.release()
        await model.settle()
        #expect(model.state.value?.query == "astronaut")
        #expect(model.state.value?.results.first?.book.key == "/works/S1W")
    }

    @Test("a trailing space does not cancel or repeat the in-flight search")
    func trailingSpaceWhileInFlight() async throws {
        let store = try await SearchServiceTests.store()
        let gated = GatedEmbedder(pauseAfter: 0)
        let model = SearchModel(service: SearchService(store: store, embedder: gated))
        model.searchDebounce = .milliseconds(30)
        model.setText("astronaut")
        await gated.waitUntilPaused()
        model.setText("astronaut ")
        await gated.release()
        await model.settle()
        #expect(model.searchCount == 1)
        #expect(model.state.value?.query == "astronaut")
    }

    @Test("indexing completion reruns the current query, and nothing when the field is cleared")
    func rerunWhenIndexCompletes() async throws {
        let (model, _, _) = try await Self.model()
        await model.indexingDidComplete()              // nothing searched yet
        #expect(model.searchCount == 0)
        model.submit("astronaut")
        await model.settle()
        #expect(model.searchCount == 1)
        await model.indexingDidComplete()
        #expect(model.searchCount == 2)
        #expect(model.state.value?.query == "astronaut")
        model.setText("a")                             // cleared
        await model.indexingDidComplete()
        #expect(model.searchCount == 2)
    }

    @Test("example queries")
    func examples() {
        #expect(SearchModel.exampleQueries.first == "lonely astronaut saves earth")
        #expect(SearchModel.exampleQueries.count == 5)
    }

    private func isIdle(_ state: LoadState<SearchResponse>) -> Bool {
        if case .idle = state { return true }
        return false
    }
}
