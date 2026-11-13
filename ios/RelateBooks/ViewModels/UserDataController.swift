import Foundation

/// What a user-data write changed; published by `UserDataController` so
/// every screen can patch or reload its copy.
enum UserDataChange: Sendable, Equatable {
    case status(key: String, status: ReadingStatus)
    case rating(key: String, rating: Int?)
    /// The book's tag set changed (always followed by `.tags`).
    case bookTags(key: String)
    case notes(key: String)
    /// Tags were created, renamed, recoloured or deleted, or a book count changed.
    case tags
    /// Every piece of user data was removed (and, phase 5, every app-added book).
    case reset
    /// A book was imported (phase 5, D26). Lists reload; Search reruns.
    case bookAdded(key: String)
    /// Geocoding located at least one new place (phase 5); the map reloads.
    case placesLocated(labels: [String])
}

/// Performs every user-data write and tells subscribers what changed
/// (D9). Book-scoped writes re-read the book's `BookUserData` after the
/// write and return it, so callers reconcile optimistic state with the
/// store.
///
/// `now` and `calendar` are injectable: `started_on` / `finished_on` are
/// the local day in `calendar` (tests pin both).
@MainActor
final class UserDataController {
    let store: GraphStore
    /// The clock every write uses.
    let now: @Sendable () -> Date
    let calendar: Calendar

    private struct Subscriber {
        weak var owner: AnyObject?
        let handler: @MainActor (UserDataChange) -> Void
    }
    private var subscribers: [Subscriber] = []

    init(store: GraphStore, now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current) {
        self.store = store
        self.now = now
        self.calendar = calendar
    }

    /// Calls `handler` on the main actor after every write, synchronously,
    /// until `owner` is released. Hold `owner` weakly in the handler too.
    func subscribe(_ owner: AnyObject, _ handler: @escaping @MainActor (UserDataChange) -> Void) {
        subscribers.append(Subscriber(owner: owner, handler: handler))
    }

    // MARK: Book-scoped writes

    func setStatus(key: String, to status: ReadingStatus) async throws -> BookUserData {
        try await store.setStatus(key: key, status: status, now: now(), calendar: calendar)
        let fresh = try await reread(key)
        publish(.status(key: key, status: status))
        return fresh
    }

    func setRating(key: String, to rating: Int?) async throws -> BookUserData {
        try await store.setRating(key: key, rating: rating)
        let fresh = try await reread(key)
        publish(.rating(key: key, rating: rating))
        return fresh
    }

    func addTag(named name: String, to key: String) async throws -> BookUserData {
        try await store.addTag(bookKey: key, name: name, now: now())
        let fresh = try await reread(key)
        publish(.bookTags(key: key))
        publish(.tags)
        return fresh
    }

    func removeTag(named name: String, from key: String) async throws -> BookUserData {
        try await store.removeTag(bookKey: key, name: name)
        let fresh = try await reread(key)
        publish(.bookTags(key: key))
        publish(.tags)
        return fresh
    }

    func addNote(text: String, to key: String) async throws -> BookUserData {
        try await store.addNote(bookKey: key, text: text, now: now())
        let fresh = try await reread(key)
        publish(.notes(key: key))
        return fresh
    }

    func updateNote(id: String, text: String, bookKey: String) async throws -> BookUserData {
        try await store.updateNote(id: id, text: text, now: now())
        let fresh = try await reread(bookKey)
        publish(.notes(key: bookKey))
        return fresh
    }

    func deleteNote(id: String, bookKey: String) async throws -> BookUserData {
        try await store.deleteNote(id: id)
        let fresh = try await reread(bookKey)
        publish(.notes(key: bookKey))
        return fresh
    }

    // MARK: Reads

    func userData(key: String) async throws -> BookUserData? {
        try await store.bookUserData(key: key)
    }

    func tags() async throws -> [TagSummary] {
        try await store.tags()
    }

    // MARK: Tag writes

    @discardableResult
    func createTag(named name: String, color: TagColor? = nil) async throws -> TagSummary {
        let tag = try await store.createTag(name: name, color: color, now: now())
        publish(.tags)
        return tag
    }

    @discardableResult
    func renameTag(_ oldName: String, to newName: String) async throws -> String {
        let name = try await store.renameTag(oldName, to: newName)
        if name != oldName { publish(.tags) }
        return name
    }

    func setTagColor(_ name: String, _ color: TagColor) async throws {
        try await store.setTagColor(name: name, color: color)
        publish(.tags)
    }

    func deleteTag(_ name: String) async throws {
        try await store.deleteTag(name: name)
        publish(.tags)
    }

    /// Tests; the app resets through the store before any model exists.
    func resetUserData() async throws {
        try await store.resetUserData()
        publish(.reset)
    }

    // MARK: Imports (phase 5)

    /// `store.saveImport(draft, now: now())`; publishes `.bookAdded(key:)`
    /// when the book was created.
    func saveImportedBook(_ draft: ImportDraft) async throws -> ImportSaveResult {
        let result = try await store.saveImport(draft, now: now())
        if case .created(let key, _) = result { publish(.bookAdded(key: key)) }
        return result
    }

    /// Runs `locator.locate(names)`, forwarding progress on the main actor,
    /// and publishes `.placesLocated(labels:)` (unique labels, first-seen
    /// order) when any place was located.
    func locatePlaces(_ names: [String], with locator: PlaceLocator,
                      progress: @escaping @MainActor (Int, Int) -> Void = { _, _ in }) async -> [PlaceGeocodeOutcome] {
        let outcomes = await locator.locate(names) { done, total in
            await MainActor.run { progress(done, total) }
        }
        var labels: [String] = []
        for label in outcomes.compactMap(\.label) where !labels.contains(label) { labels.append(label) }
        if !labels.isEmpty { publish(.placesLocated(labels: labels)) }
        return outcomes
    }

    // MARK: Private

    private func reread(_ key: String) async throws -> BookUserData {
        guard let fresh = try await store.bookUserData(key: key) else { throw UserDataError.bookNotFound(key) }
        return fresh
    }

    private func publish(_ change: UserDataChange) {
        subscribers.removeAll { $0.owner == nil }
        for subscriber in subscribers where subscriber.owner != nil {
            subscriber.handler(change)
        }
    }
}
