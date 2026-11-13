import Testing
import Foundation
import CoreML
@testable import RelateBooksCore

/// The bundled Core ML model against the sentence-transformers reference
/// embeddings in embedding_fixtures.json (20 sentences).
@Suite("MiniLM embedder", .serialized)
struct EmbedderTests {
    enum Units: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case all, cpuOnly
        var computeUnits: MLComputeUnits { self == .all ? .all : .cpuOnly }
        var testDescription: String { rawValue }
    }

    /// One embedder per compute-unit setting; each loads its model once.
    static let embedders: [Units: MiniLMEmbedder] = {
        var out: [Units: MiniLMEmbedder] = [:]
        for units in Units.allCases {
            if let e = MiniLMEmbedder.bundled(computeUnits: units.computeUnits) { out[units] = e }
        }
        return out
    }()

    static func embedder(_ units: Units) throws -> MiniLMEmbedder {
        try #require(embedders[units], "MiniLMEmbedder.bundled() found no model in Bundle.module")
    }

    static func norm(_ v: [Float]) -> Double {
        v.reduce(0) { $0 + Double($1) * Double($1) }.squareRoot()
    }

    @Test("cosine >= 0.99 with the Python reference, unit length",
          arguments: Units.allCases, 0..<FixtureFiles.embedding.cases.count)
    func reference(units: Units, index: Int) async throws {
        try await HeavyTestGate.exclusive {
            let embedder = try Self.embedder(units)
            let fixture = FixtureFiles.embedding.cases[index]
            #expect(try await embedder.encode(fixture.text).inputIDs == fixture.input_ids)
            let vector = try #require(try await embedder.embed([fixture.text]).first)
            #expect(vector.count == FixtureFiles.embedding.dimensions)
            let cosine = EmbeddingVector.cosine(vector, fixture.embedding)
            #expect(cosine >= FixtureFiles.embedding.min_cosine, "cosine \(cosine) for \(fixture.text.prefix(40))")
            #expect(abs(Self.norm(vector) - 1) < 1e-4)
            if index == 0 || cosine < 0.9999 {
                print(String(format: "MINILM parity [%@] case %d cosine %.6f", units.rawValue, index, cosine))
            }
        }
    }

    @Test("20 reference embeddings; model id matches the fixture")
    func identity() throws {
        #expect(FixtureFiles.embedding.cases.count == 20)
        let embedder = try Self.embedder(.all)
        #expect(embedder.modelID == FixtureFiles.embedding.embedding_model_id)
        #expect(embedder.modelID == EmbeddingSpace.modelID)
        #expect(embedder.dimensions == 384)
    }

    @Test("a batch returns vectors in input order")
    func batchOrder() async throws {
        try await HeavyTestGate.exclusive {
            let embedder = try Self.embedder(.cpuOnly)
            let texts = Array(FixtureFiles.embedding.cases.prefix(3).map(\.text))
            let batch = try await embedder.embed(texts)
            #expect(batch.count == 3)
            for (i, text) in texts.enumerated() {
                let single = try #require(try await embedder.embed([text]).first)
                #expect(EmbeddingVector.cosine(batch[i], single) > 0.9999)
            }
        }
    }

    @Test("minimum cosine over all references, per compute unit (printed)")
    func parityReport() async throws {
        try await HeavyTestGate.exclusive {
            for units in Units.allCases {
                let embedder = try Self.embedder(units)
                var worst = 1.0
                var worstNorm = 0.0
                for fixture in FixtureFiles.embedding.cases {
                    let v = try #require(try await embedder.embed([fixture.text]).first)
                    worst = min(worst, EmbeddingVector.cosine(v, fixture.embedding))
                    worstNorm = max(worstNorm, abs(Self.norm(v) - 1))
                }
                print(String(format: "MINILM parity [%@]: min cosine %.6f over %d references; max |norm-1| %.2e",
                             units.rawValue, worst, FixtureFiles.embedding.cases.count, worstNorm))
                #expect(worst >= 0.99)
            }
        }
    }

    @Test("time per text on this Mac (printed, no assertion)")
    func timing() async throws {
        try await HeavyTestGate.exclusive {
            let texts = FixtureFiles.tokenizer.cases.map(\.text)
            for units in Units.allCases {
                let embedder = try Self.embedder(units)
                let loadStart = ContinuousClock.now
                try await embedder.prepare()
                let loadMs = (ContinuousClock.now - loadStart).milliseconds
                var times: [Double] = []
                for text in texts {
                    let start = ContinuousClock.now
                    _ = try await embedder.embed([text])
                    times.append((ContinuousClock.now - start).milliseconds)
                }
                times.sort()
                print(String(format: "MINILM per-text median %.2f ms, p90 %.2f ms (%@), %d texts; prepare() %.0f ms",
                             times[times.count / 2], times[times.count * 9 / 10], units.rawValue, times.count, loadMs))
            }
        }
    }
}
