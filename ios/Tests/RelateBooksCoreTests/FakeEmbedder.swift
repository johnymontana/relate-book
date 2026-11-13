import Foundation
@testable import RelateBooksCore

/// A deterministic bag-of-words embedder for tests: each token (the
/// fulltext tokenizer's letter/digit runs, stopwords kept) adds ±1 at bucket
/// FNV-1a(token) % dimensions, sign from bit 31; then L2-normalized. Empty
/// text gives e0. Lexically similar texts get high cosine.
struct FakeEmbedder: TextEmbedder {
    let modelID: String
    let dimensions: Int
    let overrides: [String: [Float]]

    init(modelID: String = "fake-hash-384", dimensions: Int = 384, overrides: [String: [Float]] = [:]) {
        self.modelID = modelID
        self.dimensions = dimensions
        self.overrides = overrides
    }

    func prepare() async throws {}

    func embed(_ texts: [String]) async throws -> [[Float]] {
        try texts.map { try vector($0) }
    }

    func vector(_ text: String) throws -> [Float] {
        if let override = overrides[text] { return try EmbeddingVector.normalized(override) }
        var v = [Float](repeating: 0, count: dimensions)
        let tokens = KeywordQuery.tokens(text)
        if tokens.isEmpty {
            v[0] = 1
            return v
        }
        for token in tokens {
            let h = Self.fnv1a(token)
            let bucket = Int(h % UInt32(dimensions))
            v[bucket] += (h & 0x8000_0000) != 0 ? -1 : 1
        }
        if v.allSatisfy({ $0 == 0 }) { v[0] = 1 }
        return try EmbeddingVector.normalized(v)
    }

    static func fnv1a(_ s: String) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in s.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }
}

/// Wraps a FakeEmbedder, counts embedded texts and `prepare()` calls, and
/// once `pauseAfter` texts have been embedded suspends the next `embed`
/// until `release()`. Used for cancellation and resume tests.
actor GatedEmbedder: TextEmbedder {
    nonisolated let modelID: String
    nonisolated let dimensions: Int
    private let inner: FakeEmbedder
    private let pauseAfter: Int?
    private(set) var textCount = 0
    private(set) var callCount = 0
    private(set) var prepareCount = 0
    private var released = false
    private var gate: [CheckedContinuation<Void, Never>] = []
    private var pausedWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isPaused = false

    init(_ inner: FakeEmbedder = FakeEmbedder(), pauseAfter: Int? = nil) {
        self.inner = inner
        self.modelID = inner.modelID
        self.dimensions = inner.dimensions
        self.pauseAfter = pauseAfter
    }

    func prepare() async throws { prepareCount += 1 }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        callCount += 1
        if let pauseAfter, textCount >= pauseAfter, !released {
            isPaused = true
            for waiter in pausedWaiters { waiter.resume() }
            pausedWaiters.removeAll()
            await withCheckedContinuation { gate.append($0) }
            isPaused = false
        }
        textCount += texts.count
        return try await inner.embed(texts)
    }

    /// Returns once an `embed` call is suspended at the gate.
    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { pausedWaiters.append($0) }
    }

    func release() {
        released = true
        for continuation in gate { continuation.resume() }
        gate.removeAll()
    }
}

/// Returns vectors of the wrong length.
struct WrongDimensionEmbedder: TextEmbedder {
    let modelID = "wrong-3"
    let dimensions = 3
    func prepare() async throws {}
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [1, 0, 0] }
    }
}

/// Always fails (keyword-only fallback tests).
struct FailingEmbedder: TextEmbedder {
    let modelID = "failing"
    let dimensions = 384
    func prepare() async throws { throw EmbeddingError.resourcesMissing }
    func embed(_ texts: [String]) async throws -> [[Float]] { throw EmbeddingError.resourcesMissing }
}
