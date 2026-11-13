import CoreML
import Foundation

/// all-MiniLM-L6-v2 on Core ML (plan §3.3, D1).
///
/// The compiled model takes `input_ids` and `attention_mask` (int32,
/// [1, 256]) and returns `embedding` (float32, [1, 384]): mean pooling over
/// the mask and L2 normalization are part of the graph. Swift tokenizes,
/// rejects non-finite output and renormalizes to exact unit length.
///
/// The model and tokenizer live inside this actor, so predictions run on
/// its executor and never on the main actor. `init` only stores URLs; the
/// model loads once, in `prepare()` (about 800 ms with `.all` on a Mac the
/// first time, mostly Neural Engine compilation; 15-90 ms with `.cpuOnly`).
actor MiniLMEmbedder: TextEmbedder {
    nonisolated let modelID = EmbeddingSpace.modelID
    nonisolated let dimensions = EmbeddingSpace.dimensions

    nonisolated let modelURL: URL
    nonisolated let vocabURL: URL
    nonisolated let computeUnits: MLComputeUnits

    private var model: MLModel?
    private var tokenizer: WordPieceTokenizer?
    private var loadError: Error?

    init(modelURL: URL, vocabURL: URL, computeUnits: MLComputeUnits = .all) {
        self.modelURL = modelURL
        self.vocabURL = vocabURL
        self.computeUnits = computeUnits
    }

    /// The model shipped in the bundle (see `EmbeddingResources`), or nil
    /// when the files are missing.
    static func bundled(computeUnits: MLComputeUnits = .all) -> MiniLMEmbedder? {
        guard let model = EmbeddingResources.modelURL(), let vocab = EmbeddingResources.vocabURL() else {
            Log.store.error("embedding model resources are missing from the bundle")
            return nil
        }
        return MiniLMEmbedder(modelURL: model, vocabURL: vocab, computeUnits: computeUnits)
    }

    /// Loads the vocabulary and the model once. A load failure is cached
    /// and rethrown on every later call.
    func prepare() throws {
        if model != nil, tokenizer != nil { return }
        if let loadError { throw loadError }
        let start = ContinuousClock.now
        do {
            let tokenizer = try WordPieceTokenizer.load(contentsOf: vocabURL)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = computeUnits
            let model = try MLModel(contentsOf: modelURL, configuration: configuration)
            self.tokenizer = tokenizer
            self.model = model
        } catch {
            loadError = error
            Log.store.error("embedding model failed to load: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let ms = (ContinuousClock.now - start).milliseconds
        let line = String(format: "RelateBooks: embedding model loaded in %.0f ms (%@)", ms, Self.describe(computeUnits))
        print(line)
        Log.store.notice("\(line, privacy: .public)")
    }

    func embed(_ texts: [String]) throws -> [[Float]] {
        try prepare()
        guard let model, let tokenizer else { throw EmbeddingError.resourcesMissing }
        return try texts.map { try embedOne($0, model: model, tokenizer: tokenizer) }
    }

    /// The tokenizer's output for `text` (tests).
    func encode(_ text: String) throws -> TokenizedText {
        try prepare()
        guard let tokenizer else { throw EmbeddingError.resourcesMissing }
        return tokenizer.encode(text)
    }

    private func embedOne(_ text: String, model: MLModel, tokenizer: WordPieceTokenizer) throws -> [Float] {
        let length = EmbeddingSpace.maxTokens
        let tokens = tokenizer.encode(text, maxLength: length)
        let ids = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        let padded = tokens.paddedIDs(to: length)
        let attention = tokens.attentionMask(to: length)
        ids.withUnsafeMutableBufferPointer(ofType: Int32.self) { buffer, _ in
            for i in 0..<length { buffer[i] = padded[i] }
        }
        mask.withUnsafeMutableBufferPointer(ofType: Int32.self) { buffer, _ in
            for i in 0..<length { buffer[i] = attention[i] }
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: ids),
            "attention_mask": MLFeatureValue(multiArray: mask),
        ])
        let output: MLFeatureProvider
        do {
            output = try model.prediction(from: input)
        } catch {
            throw EmbeddingError.predictionFailed(error.localizedDescription)
        }
        guard let array = output.featureValue(for: "embedding")?.multiArrayValue else {
            throw EmbeddingError.predictionFailed("no 'embedding' output")
        }
        let vector = try Self.read(array)
        guard vector.count == dimensions else {
            throw EmbeddingError.dimensionMismatch(expected: dimensions, got: vector.count)
        }
        return try EmbeddingVector.normalized(vector)
    }

    /// The last axis of a [1, n] (or [n]) array as Floats.
    private static func read(_ array: MLMultiArray) throws -> [Float] {
        let shape = array.shape.map(\.intValue)
        guard let n = shape.last, n > 0 else { throw EmbeddingError.predictionFailed("empty output") }
        let stride = array.strides.last?.intValue ?? 1
        if array.dataType == .float32 {
            return array.withUnsafeBufferPointer(ofType: Float.self) { buffer in
                (0..<n).map { buffer[$0 * stride] }
            }
        }
        // .float16 / .double: the NSNumber path is slow but exact enough and portable.
        return (0..<n).map { array[$0 * stride].floatValue }
    }

    nonisolated static func describe(_ units: MLComputeUnits) -> String {
        switch units {
        case .all: "all"
        case .cpuOnly: "cpuOnly"
        case .cpuAndGPU: "cpuAndGPU"
        case .cpuAndNeuralEngine: "cpuAndNeuralEngine"
        @unknown default: "unknown"
        }
    }
}

extension Duration {
    /// The duration in milliseconds as a Double.
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}
