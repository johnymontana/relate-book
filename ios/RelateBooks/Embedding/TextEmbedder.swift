import Foundation
import Relate

/// Turns texts into unit-length vectors in one embedding space.
///
/// Implementations: `MiniLMEmbedder` (Core ML, the app) and test fakes.
protocol TextEmbedder: Sendable {
    /// Stored in `embedding_model` and mixed into `embedding_text_hash`.
    var modelID: String { get }
    var dimensions: Int { get }
    /// Loads or prewarms the model. Idempotent; cheap after the first call.
    func prepare() async throws
    /// One unit-length vector per text, in input order.
    func embed(_ texts: [String]) async throws -> [[Float]]
}

enum EmbeddingError: Error, Equatable, LocalizedError {
    /// The bundled model or vocab file is missing.
    case resourcesMissing
    /// vocab.txt did not have 30,522 lines (the count it had).
    case invalidVocabulary(Int)
    case predictionFailed(String)
    /// NaN, infinity or a zero vector.
    case nonFiniteOutput
    case dimensionMismatch(expected: Int, got: Int)

    var errorDescription: String? {
        switch self {
        case .resourcesMissing: "The embedding model is missing from the app"
        case .invalidVocabulary(let n): "The embedding vocabulary has \(n) entries, expected 30522"
        case .predictionFailed(let message): "Embedding failed: \(message)"
        case .nonFiniteOutput: "The embedding model returned an invalid vector"
        case .dimensionMismatch(let expected, let got): "Expected a \(expected)-dimension vector, got \(got)"
        }
    }
}

/// Vector helpers shared by the embedders, the indexer and search.
enum EmbeddingVector {
    /// L2-normalized copy. Throws `nonFiniteOutput` for NaN, infinity or a
    /// zero vector.
    static func normalized(_ v: [Float]) throws -> [Float] {
        var sum: Double = 0
        for x in v {
            guard x.isFinite else { throw EmbeddingError.nonFiniteOutput }
            sum += Double(x) * Double(x)
        }
        let norm = sum.squareRoot()
        guard norm > 0, norm.isFinite else { throw EmbeddingError.nonFiniteOutput }
        return v.map { Float(Double($0) / norm) }
    }

    /// Count and finiteness check before a vector is written: the engine
    /// accepts a stored vector of the wrong length and then silently skips
    /// it in search (V4).
    static func validate(_ v: [Float], dimensions: Int = EmbeddingSpace.dimensions) throws {
        guard v.count == dimensions else { throw EmbeddingError.dimensionMismatch(expected: dimensions, got: v.count) }
        guard v.allSatisfy(\.isFinite) else { throw EmbeddingError.nonFiniteOutput }
    }

    /// Cosine similarity; 0 when either vector is zero or the lengths differ.
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0, na: Double = 0, nb: Double = 0
        for i in a.indices {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y
            na += x * x
            nb += y * y
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// The vector a stored property holds (`.vector` or a numeric list).
    /// A FLOAT32 vector reads back bit-identical.
    static func floats(from value: CypherValue) -> [Float]? {
        if let vector = value.vectorValue {
            if let floats = vector.float32Values { return floats }
            if case .ints(_, let values) = vector { return values.map { Float($0) } }
            return nil
        }
        return try? [Float](cypherValue: value)
    }
}
