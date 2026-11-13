import Foundation

enum IndexingPhase: Sendable, Equatable {
    case idle, scanning, indexing, complete, paused, unavailable
    case failed(String)
}

/// What the indexer has done so far; published after every batch.
struct IndexingProgress: Sendable, Equatable {
    var phase: IndexingPhase
    /// Books with a fresh embedding (from earlier launches plus this run).
    var embeddedBooks = 0
    var totalBooks = 0
    /// Books embedded by this run.
    var embeddedThisRun = 0
    var notesEmbeddedThisRun = 0
    /// Set when the run completes, measured from the start of the run.
    var elapsedSeconds: Double?

    init(phase: IndexingPhase, embeddedBooks: Int = 0, totalBooks: Int = 0, embeddedThisRun: Int = 0,
         notesEmbeddedThisRun: Int = 0, elapsedSeconds: Double? = nil) {
        self.phase = phase
        self.embeddedBooks = embeddedBooks
        self.totalBooks = totalBooks
        self.embeddedThisRun = embeddedThisRun
        self.notesEmbeddedThisRun = notesEmbeddedThisRun
        self.elapsedSeconds = elapsedSeconds
    }

    /// "Indexing 412 of 1,811 books…" (localized numbers).
    var bannerText: String {
        "Indexing \(embeddedBooks.formatted()) of \(totalBooks.formatted()) books…"
    }

    /// A plain-integer status line the UI tests parse (`--wait-for-index`).
    var statusLabel: String {
        switch phase {
        case .complete:
            "Index complete. \(embeddedBooks) of \(totalBooks) books embedded. "
                + "\(embeddedThisRun) embedded this launch in \(String(format: "%.1f", elapsedSeconds ?? 0)) seconds."
        case .indexing:
            "Indexing \(embeddedBooks) of \(totalBooks) books."
        case .scanning, .idle:
            "Checking index."
        case .paused:
            "Indexing paused."
        case .unavailable:
            "Semantic search unavailable."
        case .failed(let message):
            "Indexing failed: \(message)."
        }
    }

    var fractionComplete: Double {
        Double(embeddedBooks) / Double(max(totalBooks, 1))
    }
}

/// Embeds every Book (and Note) whose vector is missing or stale (D3).
///
/// - A pass scans books in pages of 200 plus all notes; no model is needed
///   to find what is stale (hash of the text + model id).
/// - When nothing is stale it reports `.complete` without loading the model.
/// - Otherwise it loads the model, embeds stale notes, then stale books in
///   batches of 32 in key order. The embedder is called in chunks of 8, so
///   a search query waits for at most one chunk. Each batch is one UNWIND
///   statement, so it commits whole or not at all.
/// - Progress lives in the store: a cancelled or killed run resumes on the
///   next pass by rescanning.
/// - It writes only `embedding`, `embedding_model` and
///   `embedding_text_hash`, and never removes anything.
actor EmbeddingIndexer {
    struct BookScan: Sendable {
        let stale: [BookEmbeddingInput]
        let total: Int
        let fresh: Int
    }

    let store: GraphStore
    let embedder: any TextEmbedder
    let batchSize: Int
    let embedChunk: Int
    let scanPageSize: Int

    init(store: GraphStore, embedder: any TextEmbedder, batchSize: Int = 32, embedChunk: Int = 8, scanPageSize: Int = 200) {
        self.store = store
        self.embedder = embedder
        self.batchSize = max(1, batchSize)
        self.embedChunk = max(1, embedChunk)
        self.scanPageSize = max(1, scanPageSize)
    }

    func scanBooks() async throws -> BookScan {
        let modelID = embedder.modelID
        var stale: [BookEmbeddingInput] = []
        var total = 0
        var after = ""
        while true {
            try Task.checkCancellation()
            let page = try await store.embeddingScanPage(after: after, limit: scanPageSize)
            total += page.count
            stale.append(contentsOf: page.filter { $0.isStale(modelID: modelID) })
            guard page.count == scanPageSize, let last = page.last else { break }
            after = last.key
        }
        return BookScan(stale: stale, total: total, fresh: total - stale.count)
    }

    /// Stale notes, of one book or all.
    func scanNotes(bookKey: String? = nil) async throws -> [NoteEmbeddingInput] {
        let modelID = embedder.modelID
        return try await store.noteEmbeddingInputs(bookKey: bookKey).filter { $0.isStale(modelID: modelID) }
    }

    /// One full pass. Throws `CancellationError` when cancelled (the batch in
    /// flight is either written whole or not at all).
    @discardableResult
    func run(progress: @Sendable (IndexingProgress) async -> Void = { _ in }) async throws -> IndexingProgress {
        let started = ContinuousClock.now
        let modelID = embedder.modelID
        var state = IndexingProgress(phase: .scanning)
        await progress(state)

        let scan = try await scanBooks()
        let notes = try await scanNotes()
        state.embeddedBooks = scan.fresh
        state.totalBooks = scan.total

        if scan.stale.isEmpty && notes.isEmpty {
            state.phase = .complete
            state.elapsedSeconds = (ContinuousClock.now - started).milliseconds / 1000
            await progress(state)
            Self.logComplete(state)
            return state
        }

        state.phase = .indexing
        await progress(state)
        try await embedder.prepare()

        var wroteAnything = false
        if !notes.isEmpty {
            let written = try await embedAndWriteNotes(notes)
            state.notesEmbeddedThisRun += written
            wroteAnything = wroteAnything || written > 0
        }

        var index = 0
        while index < scan.stale.count {
            let batch = Array(scan.stale[index..<min(index + batchSize, scan.stale.count)])
            index += batch.count
            let texts = batch.map(\.text)
            let vectors = try await embedChecked(texts)
            try Task.checkCancellation()
            let rows = zip(batch, zip(texts, vectors)).map { input, pair in
                BookEmbeddingRow(key: input.key, vector: pair.1, hash: BookEmbeddingText.hash(text: pair.0, modelID: modelID))
            }
            let written = try await store.writeBookEmbeddings(rows, model: modelID)
            wroteAnything = wroteAnything || written > 0
            state.embeddedThisRun += written
            state.embeddedBooks += written
            await progress(state)
        }

        if wroteAnything { try await store.checkpoint() }
        state.phase = .complete
        state.elapsedSeconds = (ContinuousClock.now - started).milliseconds / 1000
        await progress(state)
        Self.logComplete(state)
        return state
    }

    /// Embeds one book's stale notes (after an add or edit). Returns how many
    /// were written; 0 without loading the model when none are stale.
    @discardableResult
    func embedNotes(bookKey: String) async throws -> Int {
        let notes = try await scanNotes(bookKey: bookKey)
        guard !notes.isEmpty else { return 0 }
        try await embedder.prepare()
        return try await embedAndWriteNotes(notes)
    }

    /// Embeds one book (after an import, D-G). Returns true when a vector
    /// was written; false when the book is missing or already fresh (no
    /// model load then). Runs on this actor, so it never interleaves with a
    /// batch write of `run` mid-statement; a pass that already scanned the
    /// book may embed it again, which writes the same vector.
    @discardableResult
    func embedBook(key: String) async throws -> Bool {
        let modelID = embedder.modelID
        guard let input = try await store.embeddingInput(key: key), input.isStale(modelID: modelID) else { return false }
        try await embedder.prepare()
        let text = input.text
        let vectors = try await embedChecked([text])
        try Task.checkCancellation()
        guard let vector = vectors.first else { return false }
        let row = BookEmbeddingRow(key: key, vector: vector, hash: BookEmbeddingText.hash(text: text, modelID: modelID))
        return try await store.writeBookEmbeddings([row], model: modelID) > 0
    }

    // MARK: Private

    private func embedAndWriteNotes(_ notes: [NoteEmbeddingInput]) async throws -> Int {
        let modelID = embedder.modelID
        var written = 0
        var index = 0
        while index < notes.count {
            let batch = Array(notes[index..<min(index + batchSize, notes.count)])
            index += batch.count
            let vectors = try await embedChecked(batch.map(\.text))
            try Task.checkCancellation()
            let rows = zip(batch, vectors).map { note, vector in
                NoteEmbeddingRow(id: note.id, text: note.text, vector: vector,
                                 hash: BookEmbeddingText.hash(text: note.text, modelID: modelID))
            }
            written += try await store.writeNoteEmbeddings(rows, model: modelID)
        }
        return written
    }

    /// Embeds in chunks of `embedChunk`, checking cancellation before each
    /// chunk and every vector's length.
    private func embedChecked(_ texts: [String]) async throws -> [[Float]] {
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        var index = 0
        while index < texts.count {
            try Task.checkCancellation()
            let chunk = Array(texts[index..<min(index + embedChunk, texts.count)])
            index += chunk.count
            let out = try await embedder.embed(chunk)
            guard out.count == chunk.count else {
                throw EmbeddingError.predictionFailed("expected \(chunk.count) vectors, got \(out.count)")
            }
            for vector in out where vector.count != EmbeddingSpace.dimensions {
                throw EmbeddingError.dimensionMismatch(expected: EmbeddingSpace.dimensions, got: vector.count)
            }
            vectors.append(contentsOf: out)
        }
        return vectors
    }

    private static func logComplete(_ state: IndexingProgress) {
        let line = String(format: "RelateBooks: index complete: %d/%d books, %d embedded this launch in %.1f s",
                          state.embeddedBooks, state.totalBooks, state.embeddedThisRun, state.elapsedSeconds ?? 0)
        print(line)
        Log.store.notice("\(line, privacy: .public)")
    }
}
