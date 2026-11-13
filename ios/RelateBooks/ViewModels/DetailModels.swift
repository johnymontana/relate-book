import Foundation
import Observation

/// Book detail screen state, plus the user's status, rating, tags and notes.
///
/// User-data actions are optimistic (D8): the local `userData` changes at
/// once, the controller writes and re-reads, and the fresh value replaces
/// it. On error the snapshot is restored, the value re-read, and
/// `actionError` set for an alert. A mutation counter drops stale
/// reconcile results. Note saves are not optimistic: the editor awaits
/// `saveNote` and stays open on failure.
///
/// Read user data from `userData`, not `state`'s `BookDetail.userData`
/// (that is the value at load time).
@MainActor
@Observable
final class BookDetailModel {
    let key: String
    private let store: GraphStore
    private let controller: UserDataController?
    private let search: SearchService?
    private(set) var state: LoadState<BookDetail?> = .idle
    /// "More like this" (phase 3): the nearest books by stored embedding.
    /// Loaded with an empty list while the book is not embedded yet.
    private(set) var similar: LoadState<[BookSummary]> = .idle
    private(set) var userData: BookUserData?
    /// Every tag, for the picker (name order is up to the view).
    private(set) var allTags: [TagSummary] = []
    var actionError: String?

    @ObservationIgnored private var mutation = 0
    @ObservationIgnored private var inFlight = 0

    /// `userData` nil keeps the screen read-only (phase-1 tests); the app
    /// always passes the shared controller.
    init(key: String, store: GraphStore, userData controller: UserDataController? = nil, search: SearchService? = nil) {
        self.key = key
        self.store = store
        self.controller = controller
        self.search = search
        controller?.subscribe(self) { [weak self] change in self?.handle(change) }
    }

    /// Loads "More like this" once (again with `force`, e.g. after indexing
    /// completes). Does nothing without a search service.
    func loadSimilar(force: Bool = false) async {
        guard let search else { return }
        if similar.isLoading { return }
        if !force, case .loaded = similar { return }
        if similar.value == nil { similar = .loading }
        do {
            similar = .loaded(try await search.moreLikeThis(key: key))
        } catch {
            Log.ui.error("more like this failed: \(error.localizedDescription, privacy: .public)")
            similar = .failed(error.localizedDescription)
        }
    }

    func load() async {
        if case .loaded = state { return }
        state = .loading
        do {
            let detail = try await store.bookDetail(key: key)
            state = .loaded(detail)
            userData = detail?.userData
            Log.ui.notice("book detail \(self.key, privacy: .public): \(detail == nil ? "not found" : "loaded", privacy: .public)")
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        if controller != nil { await loadAllTags() }
    }

    // MARK: Status and rating

    /// Same status again is a no-op.
    func setStatus(_ status: ReadingStatus) async {
        guard let controller, let current = userData, current.status != status else { return }
        var optimistic = current
        let now = controller.now()
        let today = LocalDay(now, calendar: controller.calendar)
        optimistic.status = status
        optimistic.statusChangedOn = now
        if status == .reading, optimistic.startedOn == nil { optimistic.startedOn = today }
        if status == .read { optimistic.finishedOn = today }
        await perform(optimistic) { [key] in try await controller.setStatus(key: key, to: status) }
    }

    /// 1...5, or nil to clear.
    func setRating(_ rating: Int?) async {
        guard let controller, var optimistic = userData, optimistic.rating != rating else { return }
        optimistic.rating = rating
        await perform(optimistic) { [key] in try await controller.setRating(key: key, to: rating) }
    }

    // MARK: Tags

    func addTag(_ rawName: String) async {
        guard let controller, let current = userData else { return }
        let name: String
        do { name = try TagName.normalize(rawName) } catch {
            actionError = error.localizedDescription
            return
        }
        var optimistic = current
        if !current.tags.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            let existing = allTags.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            optimistic.tags = BookTag.sorted(current.tags + [BookTag(name: existing?.name ?? name, color: existing?.color, taggedOn: nil)])
        }
        await perform(optimistic) { [key] in try await controller.addTag(named: name, to: key) }
        await loadAllTags()
    }

    func removeTag(_ name: String) async {
        guard let controller, var optimistic = userData else { return }
        optimistic.tags.removeAll { $0.name == name }
        await perform(optimistic) { [key] in try await controller.removeTag(named: name, from: key) }
        await loadAllTags()
    }

    /// Adds the tag, or removes it when the book has it (case-insensitive match).
    func toggleTag(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = userData?.tags.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            await removeTag(match.name)
        } else {
            await addTag(name)
        }
    }

    func loadAllTags() async {
        do {
            allTags = try await store.tags()
        } catch {
            Log.ui.error("tags failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Notes

    /// Adds (`id` nil) or edits a note. Not optimistic: returns true once
    /// saved; on failure sets `actionError` and returns false so the editor
    /// can stay open with the text.
    func saveNote(id: String?, text: String) async -> Bool {
        guard let controller else { return false }
        mutation += 1
        let mine = mutation
        inFlight += 1
        defer { inFlight -= 1 }
        do {
            let fresh = if let id {
                try await controller.updateNote(id: id, text: text, bookKey: key)
            } else {
                try await controller.addNote(text: text, to: key)
            }
            if mine == mutation { userData = fresh }
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }

    func deleteNote(id: String) async {
        guard let controller, var optimistic = userData else { return }
        optimistic.notes.removeAll { $0.id == id }
        await perform(optimistic) { [key] in try await controller.deleteNote(id: id, bookKey: key) }
    }

    /// Re-reads the user data (nil result: the book is gone; the current
    /// value is kept).
    func refreshUserData() async {
        let mine = mutation
        do {
            if let fresh = try await store.bookUserData(key: key), mine == mutation { userData = fresh }
        } catch {
            Log.ui.error("user data refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Private

    private func perform(_ optimistic: BookUserData, _ write: () async throws -> BookUserData) async {
        mutation += 1
        let mine = mutation
        let snapshot = userData
        inFlight += 1
        defer { inFlight -= 1 }
        userData = optimistic
        do {
            let fresh = try await write()
            if mine == mutation { userData = fresh }
        } catch {
            if mine == mutation { userData = snapshot }
            actionError = error.localizedDescription
            await refreshUserData()
        }
    }

    /// Changes made elsewhere (library swipe, Tags tab rename/delete, reset).
    /// Changes this model made itself arrive while `inFlight > 0` and are
    /// reconciled by `perform` instead.
    private func handle(_ change: UserDataChange) {
        patchSimilar(change)
        guard inFlight == 0, userData != nil else { return }
        switch change {
        case .status(let k, _), .rating(let k, _), .bookTags(let k), .notes(let k):
            guard k == key else { return }
            Task { await refreshUserData() }
        case .tags, .reset:
            Task {
                await refreshUserData()
                await loadAllTags()
            }
        case .bookAdded, .placesLocated:
            break
        }
    }
}

extension BookDetailModel {
    /// Status and rating changes patch the "More like this" rows in place.
    fileprivate func patchSimilar(_ change: UserDataChange) {
        guard case .loaded(let books) = similar else { return }
        switch change {
        case .status(let k, let status) where books.contains(where: { $0.key == k }):
            similar = .loaded(books.map { $0.key == k ? $0.with(status: status) : $0 })
        case .rating(let k, let rating) where books.contains(where: { $0.key == k }):
            similar = .loaded(books.map { $0.key == k ? $0.with(rating: .some(rating)) : $0 })
        default:
            break
        }
    }
}

/// Author page state: header plus the author's books.
@MainActor
@Observable
final class AuthorModel {
    struct Content: Sendable {
        let detail: AuthorDetail
        let books: [BookSummary]
    }

    let key: String
    private let store: GraphStore
    private(set) var state: LoadState<Content?> = .idle

    init(key: String, store: GraphStore, userData controller: UserDataController? = nil) {
        self.key = key
        self.store = store
        controller?.subscribe(self) { [weak self] change in
            switch change {
            case .status(let key, let status): self?.patch(key: key, status: status)
            case .rating(let key, let rating): self?.patch(key: key, rating: .some(rating))
            default: break
            }
        }
    }

    func load() async {
        if case .loaded = state { return }
        state = .loading
        do {
            guard let detail = try await store.authorDetail(key: key) else {
                state = .loaded(nil)
                return
            }
            let books = try await store.authorBooks(key: key)
            state = .loaded(Content(detail: detail, books: books))
            Log.ui.notice("author \(self.key, privacy: .public): \(books.count) books")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func patch(key: String, status: ReadingStatus? = nil, rating: Int?? = nil) {
        guard case .loaded(let content?) = state, content.books.contains(where: { $0.key == key }) else { return }
        let books = content.books.map { $0.key == key ? $0.with(status: status, rating: rating) : $0 }
        state = .loaded(Content(detail: content.detail, books: books))
    }
}

/// Term page state: header counts, linked authors and the paged books.
@MainActor
@Observable
final class TermModel {
    let kind: TermKind
    let name: String
    private let store: GraphStore
    private(set) var summary: TermSummary?
    private(set) var authors: [AuthorSummary] = []
    /// Place terms only (phase 4): whether the heading has a map pin, for
    /// "Show on map". nil until loaded, for other kinds, or on failure.
    private(set) var placeLocation: PlaceLocation?
    let list: PagedBooks

    init(kind: TermKind, name: String, store: GraphStore, userData controller: UserDataController? = nil) {
        self.kind = kind
        self.name = name
        self.store = store
        self.list = PagedBooks { [store] skip, limit in
            try await store.termBooks(kind, name: name, skip: skip, limit: limit)
        }
        controller?.subscribe(self) { [weak self] change in
            switch change {
            case .status(let key, let status): self?.list.patch(key: key, status: status)
            case .rating(let key, let rating): self?.list.patch(key: key, rating: .some(rating))
            default: break
            }
        }
    }

    func load() async {
        guard !list.hasLoaded, !list.isLoading else { return }
        do {
            summary = try await store.termSummary(kind, name: name)
            authors = try await store.termAuthors(kind, name: name)
        } catch {
            Log.ui.error("term header failed: \(error.localizedDescription, privacy: .public)")
        }
        if kind == .place {
            do {
                placeLocation = try await store.placeLocation(name: name)
            } catch {
                Log.ui.error("place location failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        await list.loadNextPage()
    }
}
