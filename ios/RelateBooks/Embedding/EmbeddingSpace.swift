/// The one embedding space the app stores and searches (plan §3.3, D2).
///
/// `modelID` is written to `Book.embedding_model` / `Note.embedding_model`
/// and mixed into `embedding_text_hash`, so a different model or conversion
/// makes every stored vector stale.
enum EmbeddingSpace {
    /// all-MiniLM-L6-v2, Core ML, fp16, fixed sequence length 256. The same
    /// id is in the model's user metadata and in embedding_fixtures.json.
    static let modelID = "all-MiniLM-L6-v2-coreml-fp16-256"
    /// Vector length; both vector indexes are declared with it.
    static let dimensions = 384
    /// Sequence length including [CLS] and [SEP].
    static let maxTokens = 256
}
