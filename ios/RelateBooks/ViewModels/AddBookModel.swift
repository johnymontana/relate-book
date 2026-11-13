import Foundation
import Observation

/// How an add-book flow ended (spec A.17).
struct AddBookResult: Sendable, Equatable {
    let key: String
    let title: String
    /// The book was already in the library; nothing was written.
    let alreadyInLibrary: Bool
    /// Places this import created.
    let newPlaces: Int
    /// New places located before the flow moved on.
    let locatedPlaces: Int
    /// Geocoding still running in the background (the places budget ran out, D13).
    let placesPending: Bool
    /// nil when nothing was embedded (already in library).
    let embed: EmbedBookOutcome?

    static func already(key: String, title: String?) -> AddBookResult {
        AddBookResult(key: key, title: title ?? key, alreadyInLibrary: true, newPlaces: 0, locatedPlaces: 0,
                      placesPending: false, embed: nil)
    }
}

/// The Add Book screen (phase 5, D-I, D22-D25). Main-actor state; network
/// through `BookImporter` (OpenLibraryClient), writes through
/// `UserDataController`, geocoding through the session's shared
/// `PlaceLocator`, embedding through `IndexingModel`.
///
/// Pipelines (`→` = then; a CancellationError before saving → `.editing`):
///
/// - ISBN (typed or scanned): `.checkingLibrary` (local ISBN match, no
///   network) → `.lookingUp` (`resolve(isbn:)`) → save.
/// - Search result: `choose` (a book in the library finishes at once;
///   otherwise `pendingConfirmation`) → `confirmPending` → `.checkingLibrary`
///   → `.lookingUp` (`resolve(workKey:)`) → save.
/// - Manual: `ImportDraft.manual` → save.
/// - Save: `.saving` → (new places) `.locatingPlaces(done, total)`, waiting
///   at most `placesBudget` while geocoding goes on in the background →
///   `.indexing` (at most `embedTimeout`; skipped without an embedding
///   model) → `.finished`.
///
/// `cancel()` only stops a flow that is checking or looking up; once saving
/// starts, the pipeline runs to the end even if the view goes away (the
/// task holds the model, D24). Submit actions are ignored while busy;
/// `didScan` is stricter and ignores everything outside `.editing`, plus a
/// repeat of the last accepted payload within `scanCooldown` (C2).
@MainActor
@Observable
final class AddBookModel {
    enum Mode: String, CaseIterable, Sendable, Identifiable {
        case search, scan, manual
        var id: String { rawValue }
        /// "Search" | "Scan" | "Manual"
        var title: String {
            switch self {
            case .search: "Search"
            case .scan: "Scan"
            case .manual: "Manual"
            }
        }
    }

    enum Step: Equatable, Sendable {
        case checkingLibrary, lookingUp, saving
        case locatingPlaces(done: Int, total: Int)
        case indexing

        /// D25: "Checking your library…", "Looking up…", "Saving…",
        /// "Locating places… 1 of 2", "Indexing…".
        var label: String {
            switch self {
            case .checkingLibrary: "Checking your library…"
            case .lookingUp: "Looking up…"
            case .saving: "Saving…"
            case .locatingPlaces(let done, let total): "Locating places… \(min(done + 1, total)) of \(total)"
            case .indexing: "Indexing…"
            }
        }
    }

    enum Phase: Equatable {
        case editing
        case importing(Step)
        case finished(AddBookResult)
        case failed(String)
    }

    var mode: Mode = .search
    private(set) var phase: Phase = .editing
    private(set) var searchText = ""
    private(set) var searchResults: LoadState<[OLSearchDoc]> = .idle
    /// Result keys that are Books already ("In your library").
    private(set) var inLibraryKeys: Set<String> = []
    private(set) var isbnText = ""
    private(set) var isbnValidation: ISBNValidation = .empty
    var manualTitle = ""
    var manualAuthors = ""
    /// Non-nil while the confirm dialog for a search result is up.
    var pendingConfirmation: OLSearchDoc?
    /// "Not a book barcode." after a scan that is not an ISBN.
    private(set) var scannerMessage: String?
    @ObservationIgnored var searchDebounce: Duration = .milliseconds(400)

    /// Phases in order (tests).
    @ObservationIgnored private(set) var phaseHistory: [Phase] = [.editing]

    @ObservationIgnored private let importer: BookImporter
    @ObservationIgnored private let controller: UserDataController
    @ObservationIgnored private let locator: PlaceLocator
    @ObservationIgnored private let indexing: IndexingModel?
    @ObservationIgnored private let embedTimeout: Duration
    @ObservationIgnored private let placesBudget: Duration
    @ObservationIgnored private let scanCooldown: Duration
    @ObservationIgnored private let makeUUID: @Sendable () -> UUID
    @ObservationIgnored private var simulatedScan: String?

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0
    /// The trimmed text of the latest scheduled search; nil after a clear.
    @ObservationIgnored private var scheduledSearch: String?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var importGeneration = 0
    @ObservationIgnored private var isSaving = false
    @ObservationIgnored private var lastRequest: ImportRequest?
    @ObservationIgnored private var lastScan: (payload: String, at: ContinuousClock.Instant)?
    @ObservationIgnored private var backgroundTasks: [Task<Void, Never>] = []

    private enum ImportRequest {
        case isbn(ISBN)
        case work(OLSearchDoc)
        case manual(title: String, authors: String)
    }

    /// Stores its arguments and nothing else: no subscriptions, no tasks,
    /// no I/O. SwiftUI may build and discard extra instances, so all work
    /// starts from user actions.
    /// - placesBudget: how long the screen waits for geocoding (D13).
    /// - scanCooldown: how long a payload equal to the last accepted scan is ignored.
    /// - simulatedScan: DEBUG `--simulate-scan` payload (D28), handed out
    ///   once by `takeSimulatedScan()`.
    init(importer: BookImporter, controller: UserDataController, locator: PlaceLocator,
         indexing: IndexingModel?, embedTimeout: Duration = .seconds(15),
         placesBudget: Duration = .seconds(20), scanCooldown: Duration = .seconds(10),
         simulatedScan: String? = nil,
         makeUUID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.importer = importer
        self.controller = controller
        self.locator = locator
        self.indexing = indexing
        self.embedTimeout = embedTimeout
        self.placesBudget = placesBudget
        self.scanCooldown = scanCooldown
        self.simulatedScan = simulatedScan
        self.makeUUID = makeUUID
    }

    // MARK: Derived

    /// The phase is `.importing`.
    var isBusy: Bool {
        if case .importing = phase { return true }
        return false
    }

    /// The step label while importing.
    var progressText: String? {
        if case .importing(let step) = phase { return step.label }
        return nil
    }

    /// The message while failed.
    var errorText: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// The result once finished.
    var result: AddBookResult? {
        if case .finished(let result) = phase { return result }
        return nil
    }

    var trimmedSearchText: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Search

    /// Search-as-you-type: debounced (`searchDebounce`, 400 ms); fewer than
    /// 3 trimmed characters clears to `.idle`; a newer query cancels the
    /// older one, sleeping or in flight (D-A).
    func setSearchText(_ text: String) {
        searchText = text
        let query = trimmedSearchText
        guard query.count >= OpenLibraryClient.minimumSearchLength else {
            cancelSearch()
            searchResults = .idle
            inLibraryKeys = []
            return
        }
        guard query != scheduledSearch else { return }
        scheduleSearch(query, delay: searchDebounce)
    }

    /// Return key: searches now, even for the same text.
    func submitSearch() {
        let query = trimmedSearchText
        guard query.count >= OpenLibraryClient.minimumSearchLength else { return }
        scheduleSearch(query, delay: .zero)
    }

    /// A result row: a book already in the library finishes at once (no
    /// confirmation, no network); otherwise the confirm dialog opens.
    func choose(_ doc: OLSearchDoc) {
        guard !isBusy else { return }
        if inLibraryKeys.contains(doc.key) {
            setPhase(.finished(.already(key: doc.key, title: doc.title)))
        } else {
            pendingConfirmation = doc
        }
    }

    /// "Add to Library": imports `pendingConfirmation` (match `.search`).
    func confirmPending() {
        guard let doc = pendingConfirmation, !isBusy else { return }
        pendingConfirmation = nil
        startImport(.work(doc))
    }

    func cancelPending() {
        pendingConfirmation = nil
    }

    // MARK: Scan

    /// The typed field; updates `isbnValidation`.
    func setISBNText(_ text: String) {
        isbnText = text
        isbnValidation = ISBN.validate(text)
    }

    /// "Look Up": only with a valid ISBN (match `.isbn`).
    func submitISBN() {
        guard !isBusy, let isbn = isbnValidation.isbn else { return }
        startImport(.isbn(isbn))
    }

    /// A barcode payload from the camera (or DEBUG `--simulate-scan`).
    /// Ignored unless editing, and when equal to the last accepted payload
    /// less than `scanCooldown` ago (`reset()` does not clear this, so a
    /// barcode still in view after a failure cannot loop). A non-ISBN sets
    /// `scannerMessage`.
    func didScan(payload: String) {
        guard phase == .editing else { return }
        let now = ContinuousClock.now
        if let last = lastScan, last.payload == payload, now - last.at < scanCooldown { return }
        guard let isbn = ISBN.fromBarcode(payload) else {
            scannerMessage = "Not a book barcode."
            return
        }
        lastScan = (payload, now)
        scannerMessage = nil
        startImport(.isbn(isbn))
    }

    /// True only while editing; the camera scans only then.
    var isScannerActive: Bool { phase == .editing }

    /// The `--simulate-scan` payload the first time it is called; nil afterwards.
    func takeSimulatedScan() -> String? {
        defer { simulatedScan = nil }
        return simulatedScan
    }

    // MARK: Manual

    /// A non-empty trimmed title, and not busy.
    var canSubmitManual: Bool {
        !isBusy && !manualTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func submitManual() {
        guard canSubmitManual else { return }
        startImport(.manual(title: manualTitle, authors: manualAuthors))
    }

    // MARK: Flow control

    /// From `.failed`: runs the last request again.
    func retry() {
        guard case .failed = phase, let request = lastRequest else { return }
        startImport(request)
    }

    /// Cancels the search and an import still checking or looking up
    /// (→ `.editing`, inputs kept). Saving and later steps are unaffected.
    func cancel() {
        cancelSearch()
        guard !isSaving, case .importing(let step) = phase,
              step == .checkingLibrary || step == .lookingUp else { return }
        importTask?.cancel()
        importGeneration += 1
        setPhase(.editing)
    }

    /// `.finished` / `.failed` → `.editing` (inputs kept).
    func reset() {
        switch phase {
        case .finished, .failed: setPhase(.editing)
        default: break
        }
    }

    /// Awaits the pending search, the import, and any geocoding still
    /// running in the background after the places budget (tests).
    func settle() async {
        await searchTask?.value
        await importTask?.value
        for task in backgroundTasks { await task.value }
    }

    // MARK: Private: search

    private func scheduleSearch(_ query: String, delay: Duration) {
        searchTask?.cancel()
        searchGeneration += 1
        let mine = searchGeneration
        scheduledSearch = query
        searchTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            await self.performSearch(query, generation: mine)
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchGeneration += 1
        scheduledSearch = nil
        if searchResults.isLoading { searchResults = .idle }
    }

    private func performSearch(_ query: String, generation mine: Int) async {
        guard mine == searchGeneration else { return }
        if searchResults.value == nil { searchResults = .loading }
        do {
            let docs = try await importer.client.search(text: query)
            guard mine == searchGeneration else { return }
            let keys = (try? await importer.localKeys(docs.map(\.key))) ?? []
            guard mine == searchGeneration else { return }
            inLibraryKeys = keys
            searchResults = .loaded(docs)
        } catch {
            guard mine == searchGeneration, !(error is CancellationError) else { return }
            searchResults = .failed(error.localizedDescription)
        }
    }

    // MARK: Private: import

    private func setPhase(_ newPhase: Phase) {
        phase = newPhase
        phaseHistory.append(newPhase)
    }

    private func startImport(_ request: ImportRequest) {
        cancelSearch()
        lastRequest = request
        pendingConfirmation = nil
        importGeneration += 1
        let mine = importGeneration
        // The first step is set synchronously so `isBusy` is true before
        // this returns: a second tap (or scan) in the same run-loop turn
        // is refused by the callers' guards instead of starting a second
        // run. A stale task (never one that is saving) is cancelled.
        if !isSaving { importTask?.cancel() }
        switch request {
        case .isbn, .work: setPhase(.importing(.checkingLibrary))
        case .manual: setPhase(.importing(.saving))
        }
        // Holds the model strongly: once saving starts the pipeline must
        // finish even if the view is gone (D24).
        importTask = Task { await self.runImport(request, generation: mine) }
    }

    /// Throws CancellationError when `cancel()` (or a newer import) made
    /// this run stale.
    private func checkCurrent(_ mine: Int) throws {
        if mine != importGeneration || Task.isCancelled { throw CancellationError() }
    }

    private func runImport(_ request: ImportRequest, generation mine: Int) async {
        do {
            let draft: ImportDraft
            switch request {
            case .isbn(let isbn):
                if let local = try await importer.localBook(isbn: isbn) {
                    try checkCurrent(mine)
                    setPhase(.finished(.already(key: local.key, title: local.title)))
                    return
                }
                try checkCurrent(mine)
                setPhase(.importing(.lookingUp))
                switch try await importer.resolve(isbn: isbn) {
                case .alreadyInLibrary(let key):
                    try checkCurrent(mine)
                    setPhase(.finished(.already(key: key, title: nil)))
                    return
                case .draft(let resolved):
                    draft = resolved
                }
            case .work(let doc):
                if try await importer.localKeys([doc.key]).contains(doc.key) {
                    try checkCurrent(mine)
                    setPhase(.finished(.already(key: doc.key, title: doc.title)))
                    return
                }
                try checkCurrent(mine)
                setPhase(.importing(.lookingUp))
                switch try await importer.resolve(workKey: doc.key) {
                case .alreadyInLibrary(let key):
                    try checkCurrent(mine)
                    setPhase(.finished(.already(key: key, title: doc.title)))
                    return
                case .draft(let resolved):
                    draft = resolved
                }
            case .manual(let title, let authors):
                draft = try ImportDraft.manual(title: title, authors: authors, uuid: makeUUID())
            }
            try checkCurrent(mine)
            await save(draft)
        } catch is CancellationError {
            if mine == importGeneration { setPhase(.editing) }
        } catch let error as ImportError {
            if mine == importGeneration { setPhase(.failed(error.errorDescription ?? "Import failed.")) }
        } catch let error as OpenLibraryError {
            if mine == importGeneration { setPhase(.failed(error.errorDescription ?? "Import failed.")) }
        } catch {
            if mine == importGeneration { setPhase(.failed("Couldn't save: \(error.localizedDescription)")) }
        }
    }

    /// Past the cancel point: save, locate new places (budgeted), embed.
    private func save(_ draft: ImportDraft) async {
        isSaving = true
        defer { isSaving = false }
        // A manual entry is already at `.saving` (set by startImport).
        if phase != .importing(.saving) { setPhase(.importing(.saving)) }
        let saved: ImportSaveResult
        do {
            saved = try await controller.saveImportedBook(draft)
        } catch {
            setPhase(.failed("Couldn't save: \(error.localizedDescription)"))
            return
        }
        guard case .created(let key, let newPlaces) = saved else {
            setPhase(.finished(.already(key: draft.key, title: draft.title)))
            return
        }

        var located = 0
        var pending = false
        if !newPlaces.isEmpty {
            let total = min(newPlaces.count, locator.maxPlaces)
            setPhase(.importing(.locatingPlaces(done: 0, total: total)))
            let waiter = OneShot<[PlaceGeocodeOutcome]?>()
            let controller = self.controller, locator = self.locator
            let task = Task { [weak self] in
                let outcomes = await controller.locatePlaces(newPlaces, with: locator) { done, total in
                    guard let self, case .importing(.locatingPlaces) = self.phase else { return }
                    self.setPhase(.importing(.locatingPlaces(done: done, total: total)))
                }
                waiter.resume(outcomes)
            }
            backgroundTasks.append(task)
            let budget = placesBudget
            let timer = Task {
                try? await Task.sleep(for: budget)
                if !Task.isCancelled { waiter.resume(nil) }
            }
            let outcomes = await waiter.value()
            timer.cancel()
            if let outcomes {
                located = outcomes.filter(\.isLocated).count
            } else {
                pending = true
                located = await locatedCount(newPlaces)
            }
        }

        var embed: EmbedBookOutcome = .unavailable
        if let indexing, indexing.progress.phase != .unavailable {
            setPhase(.importing(.indexing))
            embed = await indexing.embedBook(key: key, timeout: embedTimeout)
        }
        setPhase(.finished(AddBookResult(key: key, title: draft.title, alreadyInLibrary: false,
                                         newPlaces: newPlaces.count, locatedPlaces: located,
                                         placesPending: pending, embed: embed)))
    }

    /// How many of `names` are on the map now (the places budget ran out).
    private func locatedCount(_ names: [String]) async -> Int {
        var n = 0
        for name in names where (try? await controller.store.placeLocation(name: name))?.isOnMap == true { n += 1 }
        return n
    }
}
