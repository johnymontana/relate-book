import Foundation
import Observation

/// Infinite-scroll paging over any book list query. Main-actor state; the
/// fetch closure awaits the `GraphStore` actor. A `generation` counter drops
/// results of a page request that a reset overtook (e.g. typing fast).
@MainActor
@Observable
final class PagedBooks {
    typealias Fetch = @Sendable (_ skip: Int, _ limit: Int) async throws -> [BookSummary]

    private(set) var books: [BookSummary] = []
    private(set) var isLoading = false
    private(set) var reachedEnd = false
    private(set) var error: String?
    /// True once the first page of the current generation has arrived.
    private(set) var hasLoaded = false
    let pageSize: Int

    @ObservationIgnored private var fetch: Fetch
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var seen: Set<String> = []

    init(pageSize: Int = LibraryQueries.pageSize, fetch: @escaping Fetch) {
        self.pageSize = pageSize
        self.fetch = fetch
    }

    /// Replaces the query and loads its first page.
    func reset(fetch newFetch: Fetch? = nil) async {
        if let newFetch { fetch = newFetch }
        generation += 1
        books = []
        seen = []
        reachedEnd = false
        hasLoaded = false
        error = nil
        isLoading = false
        await loadNextPage()
    }

    /// Loads the next page unless one is in flight or the end was reached.
    func loadNextPage() async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        let requestGeneration = generation
        let skip = books.count
        do {
            let page = try await fetch(skip, pageSize)
            guard requestGeneration == generation else { return }
            let fresh = page.filter { seen.insert($0.key).inserted }
            books.append(contentsOf: fresh)
            reachedEnd = page.count < pageSize
            error = nil
        } catch is CancellationError {
            // Not loaded: leave hasLoaded alone so an empty list is not
            // shown as "no matches"; a newer reset may own the state.
            if requestGeneration == generation { isLoading = false }
            return
        } catch {
            guard requestGeneration == generation else { return }
            self.error = error.localizedDescription
            Log.ui.error("page load failed: \(error.localizedDescription, privacy: .public)")
        }
        if requestGeneration == generation {
            isLoading = false
            hasLoaded = true
        }
    }

    /// Replaces one row's status and/or rating in place (after a write), so
    /// the list keeps its rows and scroll position. `rating: .some(nil)`
    /// clears the rating.
    func patch(key: String, status: ReadingStatus? = nil, rating: Int?? = nil) {
        guard books.contains(where: { $0.key == key }) else { return }
        books = books.map { $0.key == key ? $0.with(status: status, rating: rating) : $0 }
    }

    /// Call from a row's onAppear: prefetches when the row is near the end.
    func loadMoreIfNeeded(current book: BookSummary) async {
        // Only the last 10 rows trigger a prefetch: O(10), not a scan of the list.
        guard books.suffix(10).contains(where: { $0.key == book.key }) else { return }
        await loadNextPage()
    }
}
