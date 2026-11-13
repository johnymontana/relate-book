import Foundation
import Observation

/// The Tags tab: every tag with its book count (count desc, then name).
/// Re-queries on each `load()` (about 0.1 ms) and after any tag change.
@MainActor
@Observable
final class TagsModel {
    let controller: UserDataController
    private(set) var state: LoadState<[TagSummary]> = .idle
    var actionError: String?

    /// Counts tag changes seen; a load result is applied unless a load that
    /// started after a later change already landed (drops stale results,
    /// keeps every result that is as fresh as the newest).
    @ObservationIgnored private var changes = 0
    @ObservationIgnored private var appliedChanges = 0

    init(controller: UserDataController) {
        self.controller = controller
        controller.subscribe(self) { [weak self] change in
            guard let self else { return }
            switch change {
            case .notes, .status, .rating, .bookAdded, .placesLocated:
                break
            case .bookTags, .tags, .reset:
                self.changes += 1
                Task { await self.load() }
            }
        }
    }

    func load() async {
        let seen = changes
        if state.value == nil { state = .loading }
        do {
            let tags = try await controller.tags()
            guard seen >= appliedChanges else { return }
            appliedChanges = seen
            state = .loaded(tags)
        } catch {
            if state.value == nil { state = .failed(error.localizedDescription) }
            Log.ui.error("tags failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Creates a tag (or finds the case-insensitive match). False with
    /// `actionError` set on failure.
    func create(_ name: String) async -> Bool {
        do {
            try await controller.createTag(named: name)
            await load()
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }

    /// False with `actionError` set on failure (name taken, empty, too long, gone).
    func rename(_ tag: TagSummary, to newName: String) async -> Bool {
        do {
            try await controller.renameTag(tag.name, to: newName)
            await load()
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }

    func setColor(_ tag: TagSummary, _ color: TagColor) async {
        do {
            try await controller.setTagColor(tag.name, color)
            await load()
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Optimistic: the row goes at once; on error the list is re-read.
    func delete(_ tag: TagSummary) async {
        changes += 1
        appliedChanges = changes
        if let tags = state.value { state = .loaded(tags.filter { $0.name != tag.name }) }
        do {
            try await controller.deleteTag(tag.name)
        } catch {
            actionError = error.localizedDescription
            await load()
        }
    }
}

/// One tag's books: the library page query with `LibraryFilter(tag:)`,
/// title order. Status and rating changes patch rows in place; tag changes
/// mark `needsReload` (the view calls `reloadIfNeeded()` on appear). If the
/// tag itself is renamed or deleted the list reloads empty; the view
/// should pop.
@MainActor
@Observable
final class TagBooksModel {
    let name: String
    let list: PagedBooks
    private(set) var total: Int?
    private(set) var needsReload = false
    var actionError: String?

    @ObservationIgnored private let store: GraphStore
    @ObservationIgnored private let controller: UserDataController?

    init(name: String, store: GraphStore, controller: UserDataController?) {
        self.name = name
        self.store = store
        self.controller = controller
        self.list = PagedBooks { [store] skip, limit in
            try await store.libraryPage(filter: LibraryFilter(tag: name), sort: .title, skip: skip, limit: limit)
        }
        controller?.subscribe(self) { [weak self] change in
            guard let self else { return }
            switch change {
            case .status(let key, let status): self.list.patch(key: key, status: status)
            case .rating(let key, let rating): self.list.patch(key: key, rating: .some(rating))
            case .bookTags, .tags, .reset: self.needsReload = true
            case .notes, .bookAdded, .placesLocated: break
            }
        }
    }

    /// First load (no-op once loaded).
    func load() async {
        guard !list.hasLoaded, !list.isLoading else { return }
        await reload()
    }

    func reloadIfNeeded() async {
        guard needsReload else { return }
        await reload()
    }

    /// Swipe action: patch, write, restore on error.
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
    }

    private func reload() async {
        needsReload = false
        let store = self.store, filter = LibraryFilter(tag: name)
        async let count = try? store.libraryCount(filter: filter)
        await list.reset()
        total = await count
    }
}
