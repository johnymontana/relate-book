import Foundation
import Observation

/// A screen whose content is one graph read that depends on what the user
/// has read and rated: it loads once, and a status, rating, reset or added
/// book marks it stale so the next appearance reads again.
@MainActor
@Observable
class ReadingDerivedModel<Value: Sendable> {
    private(set) var state: LoadState<Value> = .idle
    private(set) var needsReload = false
    /// Reads done (tests).
    @ObservationIgnored private(set) var loadCount = 0
    @ObservationIgnored private let fetch: @Sendable () async throws -> Value
    @ObservationIgnored private var generation = 0

    init(userData controller: UserDataController?, fetch: @escaping @Sendable () async throws -> Value) {
        self.fetch = fetch
        controller?.subscribe(self) { [weak self] change in self?.handle(change) }
    }

    /// Loads once; later calls do nothing unless a change made it stale.
    func load() async {
        if case .idle = state {
            await reload()
        } else {
            await reloadIfNeeded()
        }
    }

    func reloadIfNeeded() async {
        guard needsReload else { return }
        await reload()
    }

    func reload() async {
        needsReload = false
        generation += 1
        let mine = generation
        loadCount += 1
        if state.value == nil { state = .loading }
        do {
            let value = try await fetch()
            guard mine == generation else { return }
            state = .loaded(value)
        } catch {
            guard mine == generation, !(error is CancellationError) else { return }
            Log.ui.error("reading-derived load failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    private func handle(_ change: UserDataChange) {
        switch change {
        case .status, .rating, .reset, .bookAdded, .placesLocated:
            if case .idle = state { return }
            needsReload = true
        case .bookTags, .notes, .tags:
            break
        }
    }
}

/// "Next up": series to continue, more from authors the user rated highly,
/// and unread award winners (`GraphStore.nextUp`).
@MainActor
final class NextUpModel: ReadingDerivedModel<NextUp> {
    init(store: GraphStore, userData controller: UserDataController? = nil) {
        super.init(userData: controller) { try await store.nextUp() }
    }
}

/// The Map tab's "Near your reading" list: unread books set at or near
/// places the user has read about (`GraphStore.placesNearReading`).
@MainActor
final class NearReadingModel: ReadingDerivedModel<[NearbyReading]> {
    static let radiusMeters = 250_000.0

    init(store: GraphStore, userData controller: UserDataController? = nil) {
        super.init(userData: controller) { try await store.placesNearReading(radiusMeters: Self.radiusMeters) }
    }
}
