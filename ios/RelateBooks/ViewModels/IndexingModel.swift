import Foundation
import Observation

/// Drives the `EmbeddingIndexer` for the UI (D3-D6, D14): the Search
/// banner and the `--wait-for-index` status line read `progress`.
///
/// - `start()` runs one pass at utility priority; a second call while it
///   runs does nothing.
/// - `pause()` cancels it (app in background); `resume()` starts a new
///   pass, which rescans: progress lives in the store.
/// - `pauseForMemoryWarning()` pauses too, then resumes on its own after a
///   delay (a warning does not change scenePhase, so nothing else would);
///   a later `pause()` (background) cancels that resume.
/// - Note adds and edits (`UserDataChange.notes`) queue
///   `indexer.embedNotes(bookKey:)` on a serial chain, so a new note is
///   searchable within about a second.
@MainActor
@Observable
final class IndexingModel {
    private(set) var progress = IndexingProgress(phase: .idle)
    /// The key of the last book `embedBook` wrote a vector for, set when the
    /// chain's embed returns true (also when that happens after the
    /// caller's timeout). Book detail reloads "More like this" when it
    /// equals its key: an incremental embed while the index is already
    /// complete does not change `isComplete` (phase 5, C13).
    private(set) var lastEmbeddedBookKey: String?
    /// Called on the main actor each time `embedBook` writes a vector
    /// (AppSession wires it to `SearchModel.bookDidEmbed`).
    @ObservationIgnored var onBookEmbedded: (@MainActor (String) -> Void)?

    @ObservationIgnored private let indexer: EmbeddingIndexer?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// A cancelled run still unwinding; the next run waits for it.
    @ObservationIgnored private var stoppingTask: Task<Void, Never>?
    /// Bumped per run and on pause, so a stale run's late updates are dropped.
    @ObservationIgnored private var runID = 0
    @ObservationIgnored private var noteTask: Task<Void, Never>?
    /// The delayed resume after a memory warning.
    @ObservationIgnored private var memoryResume: Task<Void, Never>?
    static let memoryWarningResumeDelay: Duration = .seconds(10)
    /// Passes started (tests).
    @ObservationIgnored private(set) var runsStarted = 0

    /// A nil indexer (no embedding model) makes the phase `.unavailable`.
    init(indexer: EmbeddingIndexer?, userData: UserDataController? = nil) {
        self.indexer = indexer
        if indexer == nil { progress = IndexingProgress(phase: .unavailable) }
        userData?.subscribe(self) { [weak self] change in
            if case .notes(let key) = change { self?.enqueueNotes(bookKey: key) }
        }
    }

    var isIndexing: Bool { progress.phase == .scanning || progress.phase == .indexing }
    var isComplete: Bool { progress.phase == .complete }

    /// Idempotent: does nothing while a pass runs, or when complete or unavailable.
    func start() {
        guard let indexer, runTask == nil else { return }
        switch progress.phase {
        case .complete, .unavailable: return
        default: break
        }
        runID += 1
        runsStarted += 1
        let id = runID
        let previous = stoppingTask
        stoppingTask = nil
        runTask = Task(priority: .utility) {
            await previous?.value
            do {
                let final = try await indexer.run { p in
                    await MainActor.run { if self.runID == id { self.progress = p } }
                }
                if self.runID == id { self.progress = final }
            } catch is CancellationError {
                if self.runID == id, !self.isComplete { self.progress.phase = .paused }
            } catch {
                Log.store.error("indexing failed: \(error.localizedDescription, privacy: .public)")
                if self.runID == id { self.progress.phase = .failed(error.localizedDescription) }
            }
            if self.runID == id { self.runTask = nil }
        }
    }

    /// Cancels the running pass; the phase becomes `.paused` unless complete.
    /// Also cancels a pending memory-warning resume.
    func pause() {
        memoryResume?.cancel()
        memoryResume = nil
        stop()
    }

    /// D5: stop embedding (keep the model, search needs it), then `resume()`
    /// after `delay` unless `pause()` was called in between.
    func pauseForMemoryWarning(resumeAfter delay: Duration = IndexingModel.memoryWarningResumeDelay) {
        stop()
        memoryResume?.cancel()
        memoryResume = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.memoryResume = nil
            self.resume()
        }
    }

    /// Awaits a pending memory-warning resume (tests).
    func waitForMemoryResume() async {
        await memoryResume?.value
    }

    private func stop() {
        guard let task = runTask else { return }
        task.cancel()
        stoppingTask = task
        runTask = nil
        runID += 1
        if !isComplete { progress.phase = .paused }
    }

    /// Starts a new pass when paused, failed or idle.
    func resume() {
        switch progress.phase {
        case .paused, .failed, .idle: start()
        default: break
        }
    }

    /// Awaits the running pass, a cancelled one and the note chain (tests).
    func waitUntilIdle() async {
        while true {
            let notes = noteTask
            await stoppingTask?.value
            await runTask?.value
            await notes?.value
            if runTask == nil && noteTask == notes { return }
        }
    }

    /// Queues `indexer.embedBook(key:)` on the same serial chain as note
    /// embeds and waits for it at most `timeout`; the embed keeps running
    /// after a timeout (D-G, D25). `.unavailable` without an indexer. On
    /// `.embedded` while the index is complete, `totalBooks` and
    /// `embeddedBooks` go up by 1 (D27); during a running pass the pass's
    /// own totals stand, and the next launch corrects them.
    func embedBook(key: String, timeout: Duration = .seconds(15)) async -> EmbedBookOutcome {
        guard let indexer else { return .unavailable }
        let previous = noteTask
        let waiter = OneShot<EmbedBookOutcome>()
        let task = Task(priority: .utility) { [weak self] in
            await previous?.value
            let outcome: EmbedBookOutcome
            do {
                outcome = try await indexer.embedBook(key: key) ? .embedded : .notNeeded
            } catch {
                Log.store.error("book embedding failed: \(error.localizedDescription, privacy: .public)")
                outcome = .failed(error.localizedDescription)
            }
            if outcome == .embedded, let self {
                self.lastEmbeddedBookKey = key
                self.onBookEmbedded?(key)
                if self.isComplete {
                    self.progress.totalBooks += 1
                    self.progress.embeddedBooks += 1
                }
            }
            waiter.resume(outcome)
        }
        noteTask = task
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { waiter.resume(.timedOut) }
        }
        let outcome = await waiter.value()
        timer.cancel()
        return outcome
    }

    private func enqueueNotes(bookKey: String) {
        guard let indexer else { return }
        let previous = noteTask
        noteTask = Task(priority: .utility) {
            await previous?.value
            do {
                let n = try await indexer.embedNotes(bookKey: bookKey)
                if n > 0 { Log.store.debug("embedded \(n) note(s) for \(bookKey, privacy: .public)") }
            } catch {
                Log.store.error("note embedding failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// The result of `IndexingModel.embedBook(key:timeout:)`.
enum EmbedBookOutcome: Sendable, Equatable {
    /// A vector was written.
    case embedded
    /// The book was missing or already fresh.
    case notNeeded
    /// No embedding model (semantic search unavailable).
    case unavailable
    /// The wait ended first; the embed continues in the background.
    case timedOut
    case failed(String)
}

/// A value delivered once to one awaiting caller, from whichever of
/// several racing tasks finishes first (later deliveries are ignored).
/// Main-actor state, so the "resumed" flag needs no lock; no task group is
/// involved (`Task.value` would not respond to cancellation).
@MainActor
final class OneShot<Value: Sendable> {
    private var result: Value?
    private var continuation: CheckedContinuation<Value, Never>?

    init() {}

    func resume(_ value: Value) {
        guard result == nil else { return }
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }

    func value() async -> Value {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }
}
