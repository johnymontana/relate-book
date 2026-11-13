import Foundation
import Observation

/// The Search tab: one text field, hybrid results, optional filters.
///
/// - `setText` debounces (350 ms) and only searches when the trimmed text
///   differs from the latest *scheduled* search; fewer than 2 characters
///   clears to `.idle`. Comparing with the latest scheduled search (not the
///   last one started) means editing back to an in-flight query inside the
///   debounce window schedules it again instead of stranding it: the
///   in-flight answer is stale by then and would be dropped.
/// - `submit` searches at once, even for the same text.
/// - A generation counter drops responses that a newer search or a cleared
///   field made stale.
/// - User-data changes patch rows in place; when they may move rows in or
///   out of an active filter, `needsRerun` is set and `rerunIfNeeded()` (on
///   appear) re-queries.
@MainActor
@Observable
final class SearchModel {
    static let exampleQueries = [
        "lonely astronaut saves earth",
        "books about habits and productivity",
        "a detective in Victorian London",
        "post-apocalyptic pandemic",
        "the history of money",
    ]
    static let minimumLength = 2

    let service: SearchService
    private(set) var text = ""
    private(set) var filter = SearchFilter()
    private(set) var state: LoadState<SearchResponse> = .idle
    private(set) var needsRerun = false

    @ObservationIgnored var searchDebounce: Duration = .milliseconds(350)
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// The trimmed text of the latest search scheduled (setText, submit,
    /// rerun); nil after a clear. Its generation is `generation`.
    @ObservationIgnored private var scheduledText: String?
    /// Searches run (tests).
    @ObservationIgnored private(set) var searchCount = 0

    init(service: SearchService, userData controller: UserDataController? = nil) {
        self.service = service
        controller?.subscribe(self) { [weak self] change in self?.handle(change) }
    }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Search-as-you-type.
    func setText(_ newText: String) {
        text = newText
        let query = trimmedText
        guard query.count >= Self.minimumLength else {
            pending?.cancel()
            clear()
            return
        }
        // The latest scheduled search (sleeping or in flight) is already for
        // this text: keep it, do not cancel it.
        guard query != scheduledText else { return }
        pending?.cancel()
        let delay = searchDebounce
        let mine = schedule(query)
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.perform(query, generation: mine)
        }
    }

    /// Return key / example query: searches now.
    func submit(_ newText: String) {
        pending?.cancel()
        text = newText
        let query = trimmedText
        guard query.count >= Self.minimumLength else {
            clear()
            return
        }
        let mine = schedule(query)
        pending = Task { [weak self] in _ = await self?.perform(query, generation: mine) }
    }

    func setFilter(_ newFilter: SearchFilter) async {
        guard newFilter != filter else { return }
        filter = newFilter
        await rerun()
    }

    /// Runs the current text again (no-op when it is too short).
    func rerun() async {
        needsRerun = false
        let query = trimmedText
        guard query.count >= Self.minimumLength else { return }
        pending?.cancel()
        let mine = schedule(query)
        let task = Task { [weak self] in _ = await self?.perform(query, generation: mine) }
        pending = task
        await task.value
    }

    /// Call when one book's vector lands (the incremental embed after an
    /// add, possibly after AddBookModel stopped waiting for it). `.bookAdded`
    /// fired at save, before the embed, so a query that re-ran then only
    /// found the book by keyword; the current query runs again so it can
    /// match semantically too. No-op without a query.
    func bookDidEmbed(key: String) async {
        guard scheduledText != nil else { return }
        await rerun()
    }

    func rerunIfNeeded() async {
        guard needsRerun else { return }
        await rerun()
    }

    /// Call when the embedding index becomes complete. Anything searched
    /// before then (loaded, loading or still debouncing) only saw the books
    /// embedded so far, so the current query runs again.
    func indexingDidComplete() async {
        guard scheduledText != nil else { return }
        await rerun()
    }

    /// Loads the model in the background so the first query is fast.
    func prepareEmbedder() {
        let service = self.service
        Task(priority: .utility) { try? await service.embedder?.prepare() }
    }

    /// Awaits the pending search (tests).
    func settle() async {
        await pending?.value
    }

    // MARK: Private

    private func clear() {
        _ = nextGeneration()
        scheduledText = nil
        state = .idle
    }

    private func schedule(_ query: String) -> Int {
        scheduledText = query
        return nextGeneration()
    }

    /// Every scheduled search (and every clear) takes a new generation, so
    /// anything scheduled earlier is stale when it answers.
    private func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    private func perform(_ query: String, generation mine: Int) async {
        guard mine == generation else { return }
        searchCount += 1
        if state.value == nil { state = .loading }
        let filter = self.filter
        do {
            let response = try await service.search(query, filter: filter)
            guard mine == generation else { return }
            state = .loaded(response)
        } catch {
            guard mine == generation, !(error is CancellationError) else { return }
            state = .failed(error.localizedDescription)
        }
    }

    private func handle(_ change: UserDataChange) {
        switch change {
        case .status(let key, let status):
            patch(key: key) { $0.with(status: status) }
            if filter.status != nil { needsRerun = true }
        case .rating(let key, let rating):
            patch(key: key) { $0.with(rating: .some(rating)) }
        case .bookTags, .tags:
            if filter.tag != nil { needsRerun = true }
        case .reset:
            if state.value != nil { needsRerun = true }
        case .bookAdded:
            // The new book may match the current query (keyword at once,
            // semantic after its incremental embed).
            if scheduledText != nil { needsRerun = true }
        case .notes, .placesLocated:
            break
        }
    }

    private func patch(key: String, _ transform: (BookSummary) -> BookSummary) {
        guard let response = state.value, response.results.contains(where: { $0.book.key == key }) else { return }
        state = .loaded(response.mapBooks { $0.key == key ? transform($0) : $0 })
    }
}
