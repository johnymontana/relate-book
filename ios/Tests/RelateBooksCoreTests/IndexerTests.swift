import Testing
import Foundation
import Relate
@testable import RelateBooksCore

@Suite("Embedding indexer")
struct IndexerTests {
    static let embeddingProperties: Set<String> = ["embedding", "embedding_model", "embedding_text_hash"]

    @Test("first run embeds every book with typed FLOAT32 vectors, the model id and the text hash")
    func firstRun() async throws {
        let store = try await EmbeddingFixture.store()
        let embedder = GatedEmbedder()
        let indexer = EmbeddingIndexer(store: store, embedder: embedder, batchSize: 4)
        let recorder = ProgressRecorder()
        let final = try await indexer.run { await recorder.add($0) }

        #expect(try await EmbeddingFixture.embeddedBooks(store) == 10)
        #expect(try await EmbeddingFixture.count(store, "MATCH (b:Book) WHERE b.embedding_model = 'fake-hash-384' RETURN count(b) AS c") == 10)
        let typed = try await EmbeddingFixture.count(store, """
            MATCH (b:Book) WHERE valueType(b.embedding) STARTS WITH 'VECTOR<FLOAT32' RETURN count(b) AS c
            """)
        #expect(typed == 10)
        for input in try await store.embeddingScanPage(after: "") {
            #expect(input.storedHash == BookEmbeddingText.hash(text: input.text, modelID: "fake-hash-384"))
            #expect(!input.isStale(modelID: "fake-hash-384"))
        }
        // The stored vector is the embedder's vector, exactly.
        let stored = try await store.query("MATCH (b:Book {key: '/works/E01W'}) RETURN b.embedding AS v").scalar()
        let input = try #require(try await store.embeddingScanPage(after: "").first)
        #expect(EmbeddingVector.floats(from: stored) == (try FakeEmbedder().vector(input.text)))

        #expect(final.phase == .complete)
        #expect(final.embeddedThisRun == 10 && final.embeddedBooks == 10 && final.totalBooks == 10)
        #expect(final.elapsedSeconds != nil)
        let reports = await recorder.reports
        #expect(reports.first?.phase == .scanning)
        #expect(reports.last == final)
        #expect(zip(reports, reports.dropFirst()).allSatisfy { $0.embeddedBooks <= $1.embeddedBooks })
        #expect(reports.filter { $0.phase == .indexing }.map(\.embeddedBooks) == [0, 4, 8, 10])
        #expect(await embedder.textCount == 10)
        #expect(await embedder.prepareCount == 1)
    }

    @Test("a second run is a no-op and does not load the model")
    func secondRunNoOp() async throws {
        let store = try await EmbeddingFixture.store()
        let embedder = GatedEmbedder()
        let indexer = EmbeddingIndexer(store: store, embedder: embedder, batchSize: 4)
        try await indexer.run()
        let calls = await embedder.callCount
        let second = try await indexer.run()
        #expect(second.phase == .complete)
        #expect(second.embeddedThisRun == 0 && second.embeddedBooks == 10)
        #expect(await embedder.callCount == calls)
        #expect(await embedder.prepareCount == 1)
    }

    @Test("a changed description re-embeds that book only; a new model id re-embeds all")
    func staleness() async throws {
        let store = try await EmbeddingFixture.store()
        try await EmbeddingIndexer(store: store, embedder: FakeEmbedder(), batchSize: 4).run()
        try await store.query("MATCH (b:Book {key: '/works/E03W'}) SET b.description = 'A brand new description.'")
        let embedder = GatedEmbedder()
        let again = try await EmbeddingIndexer(store: store, embedder: embedder, batchSize: 4).run()
        #expect(again.embeddedThisRun == 1)
        #expect(await embedder.textCount == 1)
        let newModel = try await EmbeddingIndexer(store: store, embedder: FakeEmbedder(modelID: "fake-v2"), batchSize: 4).run()
        #expect(newModel.embeddedThisRun == 10)
        #expect(try await EmbeddingFixture.count(store, "MATCH (b:Book) WHERE b.embedding_model = 'fake-v2' RETURN count(b) AS c") == 10)
    }

    @Test("a cancelled run keeps whole batches and the next run resumes")
    func resumeAfterCancellation() async throws {
        let store = try await EmbeddingFixture.store()
        let gated = GatedEmbedder(FakeEmbedder(), pauseAfter: 6)
        let indexer = EmbeddingIndexer(store: store, embedder: gated, batchSize: 4, embedChunk: 2)
        let task = Task { try await indexer.run() }
        await gated.waitUntilPaused()
        task.cancel()
        await gated.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await EmbeddingFixture.embeddedBooks(store) == 4)

        let resumed = try await EmbeddingIndexer(store: store, embedder: FakeEmbedder(), batchSize: 4).run()
        #expect(resumed.embeddedThisRun == 6)
        #expect(resumed.embeddedBooks == 10)
        #expect(try await EmbeddingFixture.embeddedBooks(store) == 10)
    }

    @Test("only embedding, embedding_model and embedding_text_hash change on books and notes")
    func onlyThreeProperties() async throws {
        let store = try await EmbeddingFixture.store()
        try await store.addNote(bookKey: "/works/E02W", text: "A note about the second book.")
        let booksBefore = try await EmbeddingFixture.propertyKeys(store, label: "Book", id: "key")
        let notesBefore = try await EmbeddingFixture.propertyKeys(store, label: "Note", id: "id")
        let progress = try await EmbeddingIndexer(store: store, embedder: FakeEmbedder(), batchSize: 4).run()
        #expect(progress.notesEmbeddedThisRun == 1)
        let booksAfter = try await EmbeddingFixture.propertyKeys(store, label: "Book", id: "key")
        let notesAfter = try await EmbeddingFixture.propertyKeys(store, label: "Note", id: "id")
        #expect(booksBefore.keys.sorted() == booksAfter.keys.sorted())
        for (key, before) in booksBefore {
            #expect(before.symmetricDifference(booksAfter[key] ?? []) == Self.embeddingProperties, "\(key)")
        }
        #expect(notesBefore.count == 1)
        for (id, before) in notesBefore {
            #expect(before.symmetricDifference(notesAfter[id] ?? []) == Self.embeddingProperties)
        }
    }

    @Test("notes: embedNotes after add and edit; a write for old text is skipped")
    func notes() async throws {
        let store = try await EmbeddingFixture.store()
        let indexer = EmbeddingIndexer(store: store, embedder: FakeEmbedder())
        let note = try await store.addNote(bookKey: "/works/E01W", text: "Loved the winter crossing of the Gobrin Ice.")
        #expect(try await indexer.embedNotes(bookKey: "/works/E01W") == 1)
        let stored = try #require(try await store.noteEmbeddingInputs(bookKey: "/works/E01W").first)
        #expect(stored.hasEmbedding && stored.storedModel == "fake-hash-384")
        #expect(stored.storedHash == BookEmbeddingText.hash(text: note.text, modelID: "fake-hash-384"))
        #expect(try await indexer.embedNotes(bookKey: "/works/E01W") == 0)

        try await store.updateNote(id: note.id, text: "Edited: the ice crossing was the best part.")
        #expect(try await indexer.scanNotes(bookKey: "/works/E01W").count == 1)
        #expect(try await indexer.embedNotes(bookKey: "/works/E01W") == 1)
        #expect(try await indexer.scanNotes().isEmpty)

        let vector = try FakeEmbedder().vector("stale text")
        let written = try await store.writeNoteEmbeddings(
            [NoteEmbeddingRow(id: note.id, text: "stale text", vector: vector, hash: "x")], model: "fake-hash-384")
        #expect(written == 0)
        #expect(try await store.noteEmbeddingInputs().first?.storedHash != "x")
    }

    @MainActor
    @Test("IndexingModel embeds a note added through UserDataController")
    func modelEmbedsNewNotes() async throws {
        let store = try await EmbeddingFixture.store()
        let controller = UserDataController(store: store)
        let model = IndexingModel(indexer: EmbeddingIndexer(store: store, embedder: FakeEmbedder()), userData: controller)
        _ = try await controller.addNote(text: "The steam trains through the Alps.", to: "/works/E05W")
        await model.waitUntilIdle()
        let note = try #require(try await store.noteEmbeddingInputs(bookKey: "/works/E05W").first)
        #expect(note.hasEmbedding && !note.isStale(modelID: "fake-hash-384"))
        #expect(model.progress.phase == .idle)                   // notes never start a book pass
    }

    @Test("an embedder with the wrong dimension fails the run and writes nothing")
    func wrongDimension() async throws {
        let store = try await EmbeddingFixture.store()
        await #expect(throws: EmbeddingError.dimensionMismatch(expected: 384, got: 3)) {
            try await EmbeddingIndexer(store: store, embedder: WrongDimensionEmbedder(), batchSize: 4).run()
        }
        #expect(try await EmbeddingFixture.embeddedBooks(store) == 0)
    }

    @Test("writeBookEmbeddings rejects NaN and wrong lengths before the engine")
    func writeValidation() async throws {
        let store = try await EmbeddingFixture.store()
        var nan = [Float](repeating: 0.05, count: 384)
        nan[7] = .nan
        await #expect(throws: EmbeddingError.nonFiniteOutput) {
            try await store.writeBookEmbeddings([BookEmbeddingRow(key: "/works/E01W", vector: nan, hash: "h")], model: "m")
        }
        await #expect(throws: EmbeddingError.dimensionMismatch(expected: 384, got: 383)) {
            try await store.writeBookEmbeddings(
                [BookEmbeddingRow(key: "/works/E01W", vector: [Float](repeating: 0.05, count: 383), hash: "h")], model: "m")
        }
        #expect(try await EmbeddingFixture.embeddedBooks(store) == 0)
        #expect(throws: EmbeddingError.nonFiniteOutput) { try EmbeddingVector.normalized([0, 0, 0]) }
    }

    @Test("resetEmbeddings removes the three properties from books and notes")
    func reset() async throws {
        let store = try await EmbeddingFixture.store()
        try await store.addNote(bookKey: "/works/E01W", text: "note")
        let before = try await EmbeddingFixture.propertyKeys(store, label: "Book", id: "key")
        try await EmbeddingIndexer(store: store, embedder: FakeEmbedder()).run()
        try await store.resetEmbeddings()
        #expect(try await EmbeddingFixture.embeddedBooks(store) == 0)
        #expect(try await EmbeddingFixture.propertyKeys(store, label: "Book", id: "key") == before)
        #expect(try await store.noteEmbeddingInputs().allSatisfy { !$0.hasEmbedding && $0.storedModel == nil })
    }

    // MARK: IndexingModel

    @MainActor
    @Test("IndexingModel: start is idempotent and completes")
    func modelStart() async throws {
        let store = try await EmbeddingFixture.store()
        let model = IndexingModel(indexer: EmbeddingIndexer(store: store, embedder: FakeEmbedder(), batchSize: 4), userData: nil)
        #expect(model.progress.phase == .idle)
        model.start()
        model.start()
        #expect(model.runsStarted == 1)
        await model.waitUntilIdle()
        #expect(model.isComplete && !model.isIndexing)
        #expect(model.progress.embeddedBooks == 10 && model.progress.embeddedThisRun == 10)
        model.start()                                              // complete: no new pass
        #expect(model.runsStarted == 1)
    }

    @MainActor
    @Test("IndexingModel: pause makes the phase paused; resume completes")
    func modelPauseResume() async throws {
        let store = try await EmbeddingFixture.store()
        let gated = GatedEmbedder(FakeEmbedder(), pauseAfter: 4)
        let model = IndexingModel(indexer: EmbeddingIndexer(store: store, embedder: gated, batchSize: 4, embedChunk: 2), userData: nil)
        model.start()
        await gated.waitUntilPaused()
        #expect(model.isIndexing)
        model.pause()
        #expect(model.progress.phase == .paused)
        await gated.release()
        await model.waitUntilIdle()
        #expect(model.progress.phase == .paused)
        #expect(try await EmbeddingFixture.embeddedBooks(store) == 4)
        model.resume()
        await model.waitUntilIdle()
        #expect(model.isComplete)
        #expect(model.progress.embeddedBooks == 10 && model.progress.embeddedThisRun == 6)
        #expect(try await EmbeddingFixture.embeddedBooks(store) == 10)
    }

    @MainActor
    @Test("IndexingModel: a memory warning pauses, then resumes by itself; background cancels that resume")
    func modelMemoryWarning() async throws {
        let store = try await EmbeddingFixture.store()
        let gated = GatedEmbedder(FakeEmbedder(), pauseAfter: 4)
        let model = IndexingModel(indexer: EmbeddingIndexer(store: store, embedder: gated, batchSize: 4, embedChunk: 2), userData: nil)
        model.start()
        await gated.waitUntilPaused()
        model.pauseForMemoryWarning(resumeAfter: .milliseconds(50))
        #expect(model.progress.phase == .paused)
        await gated.release()
        await model.waitForMemoryResume()
        #expect(model.runsStarted == 2)
        await model.waitUntilIdle()
        #expect(model.isComplete)
        #expect(try await EmbeddingFixture.embeddedBooks(store) == 10)

        // A pause (app in background) after the warning wins: no auto-resume.
        let store2 = try await EmbeddingFixture.store()
        let gated2 = GatedEmbedder(FakeEmbedder(), pauseAfter: 4)
        let model2 = IndexingModel(indexer: EmbeddingIndexer(store: store2, embedder: gated2, batchSize: 4, embedChunk: 2), userData: nil)
        model2.start()
        await gated2.waitUntilPaused()
        model2.pauseForMemoryWarning(resumeAfter: .milliseconds(50))
        model2.pause()
        await gated2.release()
        try await Task.sleep(for: .milliseconds(150))
        await model2.waitUntilIdle()
        #expect(model2.runsStarted == 1 && model2.progress.phase == .paused)
    }

    @MainActor
    @Test("IndexingModel without an indexer is unavailable; a failing embedder fails")
    func modelUnavailableAndFailed() async throws {
        let model = IndexingModel(indexer: nil, userData: nil)
        #expect(model.progress.phase == .unavailable)
        model.start()
        #expect(model.progress.phase == .unavailable && model.runsStarted == 0)
        #expect(model.progress.statusLabel == "Semantic search unavailable.")

        let store = try await EmbeddingFixture.store()
        let failing = IndexingModel(indexer: EmbeddingIndexer(store: store, embedder: FailingEmbedder()), userData: nil)
        failing.start()
        await failing.waitUntilIdle()
        #expect(failing.progress.phase == .failed(EmbeddingError.resourcesMissing.localizedDescription))
        #expect(failing.progress.statusLabel == "Indexing failed: The embedding model is missing from the app.")
    }

    @Test("status label and banner formats")
    func labels() {
        let complete = IndexingProgress(phase: .complete, embeddedBooks: 1811, totalBooks: 1811, embeddedThisRun: 1811,
                                        elapsedSeconds: 92.44)
        #expect(complete.statusLabel
                == "Index complete. 1811 of 1811 books embedded. 1811 embedded this launch in 92.4 seconds.")
        let relaunch = IndexingProgress(phase: .complete, embeddedBooks: 1811, totalBooks: 1811, embeddedThisRun: 0,
                                        elapsedSeconds: 0.03)
        #expect(relaunch.statusLabel == "Index complete. 1811 of 1811 books embedded. 0 embedded this launch in 0.0 seconds.")
        let indexing = IndexingProgress(phase: .indexing, embeddedBooks: 412, totalBooks: 1811)
        #expect(indexing.statusLabel == "Indexing 412 of 1811 books.")
        #expect(indexing.bannerText == "Indexing \(412.formatted()) of \(1811.formatted()) books…")
        #expect(abs(indexing.fractionComplete - 412.0 / 1811.0) < 1e-12)
        #expect(IndexingProgress(phase: .scanning).statusLabel == "Checking index.")
        #expect(IndexingProgress(phase: .idle).statusLabel == "Checking index.")
        #expect(IndexingProgress(phase: .paused).statusLabel == "Indexing paused.")
        #expect(IndexingProgress(phase: .failed("boom")).statusLabel == "Indexing failed: boom.")
        #expect(IndexingProgress(phase: .idle).fractionComplete == 0)
    }
}
