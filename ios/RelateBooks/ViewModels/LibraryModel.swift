import Foundation
import Observation

/// The Library tab: filter, sort, search text, facets and the paged list.
@MainActor
@Observable
final class LibraryModel {
    let store: GraphStore
    private(set) var filter = LibraryFilter()
    private(set) var sort: LibrarySort = .title
    /// Matching books for the current filter (the list header).
    private(set) var total: Int?
    private(set) var totalBooks: Int?
    private(set) var formats: [FacetValue] = []
    private(set) var genres: [FacetValue] = []
    /// Tag chips (Tags-tab order: count desc, then name).
    private(set) var tags: [TagSummary] = []
    let list: PagedBooks
    /// Set by a failed swipe status change (alert text).
    var actionError: String?
    /// A user-data change may have moved rows in or out of the current
    /// filter or sort; rows were patched in place, and `reloadIfNeeded()`
    /// (on appear, or after a swipe) re-queries.
    private(set) var needsReload = false

    @ObservationIgnored private let controller: UserDataController?
    @ObservationIgnored private var changeTask: Task<Void, Never>?

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// Delay before a search-text change queries (search-as-you-type).
    @ObservationIgnored var searchDebounce: Duration = .milliseconds(200)

    init(store: GraphStore, userData controller: UserDataController? = nil) {
        self.store = store
        self.controller = controller
        let initialFilter = LibraryFilter()
        self.list = PagedBooks { [store] skip, limit in
            try await store.libraryPage(filter: initialFilter, sort: .title, skip: skip, limit: limit)
        }
        controller?.subscribe(self) { [weak self] change in self?.handle(change) }
    }

    /// First load: facets, totals and page one.
    func start() async {
        guard !list.hasLoaded, !list.isLoading else { return }
        async let facets: Void = loadFacets()
        await reload()
        await facets
        await loadTagFacets()
    }

    func loadTagFacets() async {
        do {
            tags = try await store.tags()
        } catch {
            Log.ui.error("tag facets failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Swipe action: patches the row at once, writes, and restores the row
    /// on error; then reloads if the change moved rows.
    func setStatus(key: String, to status: ReadingStatus) async {
        guard let controller else { return }
        let old = list.books.first { $0.key == key }?.status
        list.patch(key: key, status: status)
        do {
            _ = try await controller.setStatus(key: key, to: status)
        } catch {
            if let old { list.patch(key: key, status: old) }
            actionError = error.localizedDescription
        }
        await reloadIfNeeded()
    }

    func reloadIfNeeded() async {
        guard needsReload else { return }
        needsReload = false
        await reload()
    }

    /// Awaits the reload a tag or reset change started (tests).
    func settleUserDataChanges() async {
        await changeTask?.value
    }

    private func handle(_ change: UserDataChange) {
        switch change {
        case .status(let key, let status):
            list.patch(key: key, status: status)
            if filter.status != nil || sort == .recentlyUpdated { needsReload = true }
        case .rating(let key, let rating):
            list.patch(key: key, rating: .some(rating))
        case .bookTags:
            if filter.tag != nil { needsReload = true }
        case .tags:
            let previous = changeTask
            changeTask = Task { [weak self] in
                await previous?.value
                await self?.tagsChanged()
            }
        case .reset:
            let previous = changeTask
            changeTask = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                await self.loadFacets()
                await self.loadTagFacets()
                self.needsReload = false
                await self.reload()
            }
        case .bookAdded:
            // A new row (and maybe a new format chip, and the total): the
            // facets reload now, the list on appear (`reloadIfNeeded`).
            let previous = changeTask
            changeTask = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                await self.loadFacets()
                self.needsReload = true
            }
        case .notes, .placesLocated:
            break
        }
    }

    /// Reloads the tag chips; a filtered tag that was deleted or renamed
    /// is cleared.
    private func tagsChanged() async {
        await loadTagFacets()
        if let tag = filter.tag, !tags.contains(where: { $0.name == tag }) {
            var f = filter
            f.tag = nil
            needsReload = false
            await setFilter(f)
        }
    }

    func loadFacets() async {
        do {
            formats = try await store.formatFacets()
            genres = try await store.genreFacets()
            totalBooks = try await store.bookCount()
        } catch {
            Log.ui.error("facets failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-queries with the current filter and sort from page one.
    func reload() async {
        needsReload = false
        let filter = self.filter, sort = self.sort, store = self.store
        async let count = try? store.libraryCount(filter: filter)
        await list.reset { skip, limit in
            try await store.libraryPage(filter: filter, sort: sort, skip: skip, limit: limit)
        }
        let n = await count
        if filter == self.filter { total = n }
    }

    func setSort(_ newSort: LibrarySort) async {
        guard newSort != sort else { return }
        sort = newSort
        await reload()
    }

    func setFilter(_ newFilter: LibraryFilter) async {
        guard newFilter != filter else { return }
        filter = newFilter
        await reload()
    }

    func toggleStatus(_ status: ReadingStatus) async {
        var f = filter
        f.status = f.status == status ? nil : status
        await setFilter(f)
    }

    func toggleFormat(_ format: String) async {
        var f = filter
        f.format = f.format == format ? nil : format
        await setFilter(f)
    }

    func toggleGenre(_ genre: String) async {
        var f = filter
        f.genre = f.genre == genre ? nil : genre
        await setFilter(f)
    }

    func toggleTag(_ name: String) async {
        var f = filter
        f.tag = f.tag == name ? nil : name
        await setFilter(f)
    }

    func toggleUnresolved() async {
        var f = filter
        f.unresolvedOnly.toggle()
        await setFilter(f)
    }

    func clearFilters() async {
        await setFilter(LibraryFilter(text: filter.text))
    }

    /// Search-as-you-type: debounced; a newer keystroke cancels the older query.
    func setSearchText(_ text: String) {
        // Cancel first: typing "t" then deleting it within the debounce must
        // also drop the pending "…t" search, even though the text is back to
        // the applied filter.
        searchTask?.cancel()
        guard text != filter.text else { return }
        let delay = searchDebounce
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            var f = self.filter
            f.text = text
            await self.setFilter(f)
        }
    }

    /// Awaits the pending debounced search (tests).
    func settleSearch() async {
        await searchTask?.value
    }
}
