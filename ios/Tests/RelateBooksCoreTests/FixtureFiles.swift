import Foundation
import Testing
@testable import RelateBooksCore

/// The JSON fixtures `scripts/convert_embedding_model.py` writes into
/// Tests/RelateBooksCoreTests/Fixtures/ (excluded from the target; read
/// through #filePath).
enum FixtureFiles {
    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)
    }

    struct TokenizerCase: Decodable, Sendable, CustomTestStringConvertible {
        let name: String
        let text: String
        let input_ids: [Int32]
        let length: Int
        let truncated: Bool
        let untruncated_length: Int
        let tokens: [String]?
        var testDescription: String { name }
    }

    struct TokenizerFile: Decodable, Sendable {
        let max_length: Int
        let vocab_size: Int
        let special_tokens: [String: Int32]
        let cases: [TokenizerCase]
    }

    struct EmbeddingCase: Decodable, Sendable {
        let text: String
        let input_ids: [Int32]
        let embedding: [Float]
    }

    struct EmbeddingFile: Decodable, Sendable {
        let dimensions: Int
        let max_length: Int
        let min_cosine: Double
        let embedding_model_id: String
        let cases: [EmbeddingCase]
    }

    static func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: directory.appendingPathComponent(name)))
    }

    /// Loaded once; a missing file fails the tests that read it.
    static let tokenizer: TokenizerFile = try! load("tokenizer_fixtures.json", as: TokenizerFile.self)
    static let embedding: EmbeddingFile = try! load("embedding_fixtures.json", as: EmbeddingFile.self)

    // MARK: Phase 5: recorded Open Library responses (Fixtures/OpenLibrary/)

    static var openLibraryDirectory: URL { directory.appendingPathComponent("OpenLibrary", isDirectory: true) }

    /// The raw bytes of a recorded Open Library response, e.g. "search-isbn13.json".
    static func openLibrary(_ name: String) throws -> Data {
        try Data(contentsOf: openLibraryDirectory.appendingPathComponent(name))
    }

    static func openLibraryJSON(_ name: String) throws -> JSONValue {
        try JSONValue.parse(openLibrary(name))
    }
}
