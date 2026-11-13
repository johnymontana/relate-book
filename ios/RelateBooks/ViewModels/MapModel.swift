import Foundation
import Observation

/// A camera move the map view performs once: `setRegion(center, span)`,
/// then `MapModel.focusHandled(id)`.
struct MapFocus: Sendable, Equatable {
    let id: Int
    let center: GeoCoordinate
    let latitudeDelta: Double
    let longitudeDelta: Double
}

/// The Map tab: pins for the visible region, place search, the selected
/// place's sheet and fly-to requests.
///
/// - **Regions.** The view reports every settled region through
///   `regionDidChange`. The model fetches the visible box padded by 50 % on
///   each side, so panning and zooming in stay inside `fetchedBox` and never
///   re-query. A box outside it is fetched after `regionDidChange`'s
///   debounce; a newer region cancels the sleeping task, and a generation
///   counter drops any query that answers late (the `SearchModel` pattern;
///   store work already started is not interrupted, only ignored).
/// - **Birthplaces.** The region query returns birthplace-only pins too;
///   `showsBirthplaces` only filters `displayedPins` (no re-query).
/// - **Selection.** `select(label:)` creates a `PlaceSheetModel`; the sheet
///   view calls its `load()`. `deselect()` dismisses.
/// - **Fly-to.** `focus(on:)` (launch `--map-place`, "Show on map") and
///   `choose(_:)` (a search result) set `focus` and open the sheet.
@MainActor
@Observable
final class MapModel {
    /// Continental US: the store is US-heavy, so the first screen has pins.
    nonisolated static let initialRegion = GeoBox(center: GeoCoordinate(latitude: 40, longitude: -100),
                                      latitudeDelta: 45, longitudeDelta: 70)
    /// Degrees, latitude and longitude, of a fly-to.
    nonisolated static let focusSpan = 8.0
    /// Each side of a fetched box grows by this fraction of the visible span.
    nonisolated static let fetchPadding = 0.5

    /// Everything in the last fetched (padded) box.
    private(set) var pins: [PlacePin] = []
    private(set) var visibleBox: GeoBox = MapModel.initialRegion
    private(set) var isLoading = false
    /// True once a region fetch has landed.
    private(set) var hasLoaded = false
    private(set) var error: String?
    /// The birthplace layer; changes are local (no re-query).
    var showsBirthplaces = false
    /// A pending camera move; the view consumes it and calls `focusHandled`.
    private(set) var focus: MapFocus?
    /// Non-nil while the place sheet is presented.
    private(set) var sheet: PlaceSheetModel?
    private(set) var searchText = ""
    private(set) var searchResults: [PlacePin] = []
    /// True while a place search is debouncing or running.
    private(set) var isSearching = false
    /// A transient notice, e.g. "“Gethen” is not on the map".
    private(set) var message: String?

    @ObservationIgnored var regionDebounce: Duration = .milliseconds(300)
    @ObservationIgnored var searchDebounce: Duration = .milliseconds(250)
    /// Region queries run (tests).
    @ObservationIgnored private(set) var queryCount = 0
    /// Place searches run (tests).
    @ObservationIgnored private(set) var searchCount = 0
    /// The box `pins` cover.
    @ObservationIgnored private(set) var fetchedBox: GeoBox?
    /// The box a scheduled or in-flight fetch will cover.
    @ObservationIgnored private var pendingBox: GeoBox?
    @ObservationIgnored private var pendingRegion: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingSearch: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0
    /// The trimmed text `searchResults` answer; nil when none.
    @ObservationIgnored private var answeredSearch: String?
    @ObservationIgnored private var focusCounter = 0

    private let store: GraphStore
    private let userData: UserDataController?

    init(store: GraphStore, userData: UserDataController? = nil) {
        self.store = store
        self.userData = userData
        userData?.subscribe(self) { [weak self] change in self?.handle(change) }
    }

    /// Phase 5: an imported book may bring a new located place, geocoding
    /// may finish later, and a reset removes app places. Once pins are
    /// loaded the visible box is fetched again; before that the first
    /// fetch sees the change anyway.
    private func handle(_ change: UserDataChange) {
        switch change {
        case .bookAdded, .placesLocated, .reset:
            guard hasLoaded else { return }
            Task { [weak self] in await self?.reload() }
        default:
            break
        }
    }

    // MARK: Derived

    /// Pins shown: books > 0 always; birthplace-only pins only with
    /// `showsBirthplaces`.
    var displayedPins: [PlacePin] {
        showsBirthplaces ? pins : pins.filter { !$0.isBirthplaceOnly }
    }

    /// Displayed pins inside `visibleBox` (what the count label says).
    var pinsInView: [PlacePin] {
        let box = visibleBox
        return displayedPins.filter { box.contains($0.coordinate) }
    }

    /// "1 place in view" / "N places in view" / "No places in view".
    var countText: String {
        let n = pinsInView.count
        return n == 0 ? "No places in view" : "\(PlaceText.places(n)) in view"
    }

    var showsEmptyState: Bool { hasLoaded && !isLoading && pinsInView.isEmpty }

    var trimmedSearchText: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// "No places match": the current text (2+ characters) was searched and
    /// found nothing.
    var showsNoSearchMatches: Bool {
        !isSearching && searchResults.isEmpty && answeredSearch != nil && answeredSearch == trimmedSearchText
    }

    // MARK: Regions

    /// The first fetch, for `initialRegion` padded, without debounce. Does
    /// nothing once pins are loaded; awaits a fetch that is already pending.
    func start() async {
        guard !hasLoaded else { return }
        if pendingBox != nil {
            await pendingRegion?.value
            return
        }
        let box = visibleBox.padded(by: Self.fetchPadding)
        pendingRegion?.cancel()
        let mine = nextGeneration()
        pendingBox = box
        let task = Task { [weak self] in _ = await self?.fetch(box, generation: mine) }
        pendingRegion = task
        await task.value
    }

    /// The map settled on `box`. Sets `visibleBox` at once; fetches
    /// `box.padded(by: 0.5)` after `regionDebounce` unless the pins already
    /// (or about to) cover it.
    func regionDidChange(_ box: GeoBox) {
        visibleBox = box
        if let pendingBox {
            if pendingBox.contains(box) { return }
            if let fetchedBox, fetchedBox.contains(box) {
                // Back inside what is loaded: the pending fetch is no longer needed.
                cancelPendingRegion()
                return
            }
        } else if let fetchedBox, fetchedBox.contains(box) {
            return
        }
        pendingRegion?.cancel()
        let mine = nextGeneration()
        let target = box.padded(by: Self.fetchPadding)
        pendingBox = target
        let delay = regionDebounce
        pendingRegion = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.fetch(target, generation: mine)
        }
    }

    /// Re-fetches the visible box (e.g. a retry after an error).
    func reload() async {
        cancelPendingRegion()
        let box = visibleBox.padded(by: Self.fetchPadding)
        let mine = nextGeneration()
        pendingBox = box
        let task = Task { [weak self] in _ = await self?.fetch(box, generation: mine) }
        pendingRegion = task
        await task.value
    }

    /// Awaits the pending region fetch and search (tests).
    func settle() async {
        await pendingRegion?.value
        await pendingSearch?.value
    }

    // MARK: Search

    /// Search-as-you-type; fewer than 2 characters clears the results.
    func setSearchText(_ text: String) {
        searchText = text
        let query = trimmedSearchText
        pendingSearch?.cancel()
        searchGeneration += 1
        guard query.count >= PlaceQueries.minimumSearchLength else {
            searchResults = []
            answeredSearch = nil
            isSearching = false
            return
        }
        let mine = searchGeneration
        let delay = searchDebounce
        isSearching = true
        pendingSearch = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.performSearch(query, generation: mine)
        }
    }

    func clearSearch() { setSearchText("") }

    // MARK: Selection and focus

    /// A search result: fly to it, open its sheet, clear the search.
    func choose(_ pin: PlacePin) {
        requestFocus(on: pin.coordinate)
        select(label: pin.label)
        clearSearch()
    }

    /// Opens the sheet for `label` (a new `PlaceSheetModel` unless it is
    /// already the selection).
    func select(label: String) {
        guard sheet?.label != label else { return }
        sheet = PlaceSheetModel(label: label, store: store, userData: userData)
    }

    func deselect() {
        sheet = nil
    }

    /// A label or heading (launch `--map-place`, "Show on map"): flies there
    /// and opens the sheet, or sets `message` when it is not on the map.
    func focus(on text: String) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        do {
            if let place = try await store.resolvePlace(query) {
                message = nil
                requestFocus(on: place.coordinate)
                select(label: place.label)
                Log.ui.notice("map focus \(query, privacy: .public) -> \(place.label, privacy: .public)")
            } else {
                message = "“\(query)” is not on the map"
            }
        } catch {
            Log.ui.error("map focus failed: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
    }

    /// The view performed `focus` with this id.
    func focusHandled(_ id: Int) {
        if focus?.id == id { focus = nil }
    }

    func clearMessage() {
        message = nil
    }

    // MARK: Private

    private func requestFocus(on center: GeoCoordinate) {
        focusCounter += 1
        focus = MapFocus(id: focusCounter, center: center,
                         latitudeDelta: Self.focusSpan, longitudeDelta: Self.focusSpan)
    }

    private func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    private func cancelPendingRegion() {
        pendingRegion?.cancel()
        pendingRegion = nil
        pendingBox = nil
        _ = nextGeneration()
        isLoading = false
    }

    private func fetch(_ box: GeoBox, generation mine: Int) async {
        guard mine == generation else { return }
        queryCount += 1
        isLoading = true
        do {
            let result = try await store.placePins(in: box)
            guard mine == generation else { return }
            pins = result
            fetchedBox = box
            error = nil
            hasLoaded = true
            Log.ui.debug("map region: \(result.count) pins")
        } catch {
            guard mine == generation else { return }
            Log.ui.error("map region failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
        pendingBox = nil
        isLoading = false
    }

    private func performSearch(_ query: String, generation mine: Int) async {
        guard mine == searchGeneration else { return }
        searchCount += 1
        do {
            let results = try await store.searchPlaces(query)
            guard mine == searchGeneration else { return }
            searchResults = results
        } catch {
            guard mine == searchGeneration else { return }
            Log.ui.error("place search failed: \(error.localizedDescription, privacy: .public)")
            searchResults = []
        }
        answeredSearch = query
        isSearching = false
    }
}

/// The place sheet: header facts, the books set there (paged, title order)
/// and the authors born there. Status and rating changes patch book rows in
/// place, like `TermModel`.
@MainActor
@Observable
final class PlaceSheetModel: Identifiable {
    let label: String
    private(set) var summary: PlaceSummary?
    private(set) var authors: [AuthorSummary] = []
    /// True once the header has loaded (found or not).
    private(set) var hasLoadedSummary = false
    private(set) var error: String?
    let books: PagedBooks

    private let store: GraphStore

    init(label: String, store: GraphStore, userData controller: UserDataController? = nil) {
        self.label = label
        self.store = store
        self.books = PagedBooks { [store] skip, limit in
            try await store.placeBooks(label: label, skip: skip, limit: limit)
        }
        controller?.subscribe(self) { [weak self] change in
            switch change {
            case .status(let key, let status): self?.books.patch(key: key, status: status)
            case .rating(let key, let rating): self?.books.patch(key: key, rating: .some(rating))
            default: break
            }
        }
    }

    /// Loads the header, the authors and the first page of books, once.
    func load() async {
        guard !books.hasLoaded, !books.isLoading else { return }
        do {
            summary = try await store.placeSummary(label: label)
            authors = try await store.placeAuthors(label: label)
            error = nil
        } catch {
            Log.ui.error("place sheet header failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
        hasLoadedSummary = true
        await books.loadNextPage()
        Log.ui.notice("place sheet \(self.label, privacy: .public): \(self.summary?.bookCount ?? 0) books")
    }
}
