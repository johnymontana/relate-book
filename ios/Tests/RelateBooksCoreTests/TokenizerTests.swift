import Testing
import Foundation
@testable import RelateBooksCore

/// The Swift WordPiece port against the Python BertTokenizer output in
/// tokenizer_fixtures.json (50 cases).
@Suite("WordPiece tokenizer")
struct TokenizerTests {
    static let tokenizer: WordPieceTokenizer = {
        let url = EmbeddingResources.vocabURL()!
        return try! WordPieceTokenizer.load(contentsOf: url)
    }()

    @Test("matches the Python BertTokenizer fixture", arguments: FixtureFiles.tokenizer.cases)
    func fixture(_ c: FixtureFiles.TokenizerCase) {
        let encoded = Self.tokenizer.encode(c.text, maxLength: FixtureFiles.tokenizer.max_length)
        #expect(encoded.inputIDs == c.input_ids, "\(c.name)")
        #expect(encoded.inputIDs.count == c.length)
        #expect(encoded.truncated == c.truncated)
        #expect(encoded.untruncatedLength == c.untruncated_length)
        if let tokens = c.tokens {
            // Drop the outer [CLS] and [SEP] only: special_tokens_inline has more inside.
            let expected = Array(tokens.dropFirst().dropLast())
            #expect(Array(Self.tokenizer.tokenize(c.text).prefix(c.length - 2)) == expected, "\(c.name)")
        }
    }

    @Test("all 50 fixtures are present")
    func fixtureCount() {
        #expect(FixtureFiles.tokenizer.cases.count == 50)
    }

    @Test("vocabulary size and special token ids")
    func vocabulary() throws {
        #expect(Self.tokenizer.count == 30522)
        #expect(FixtureFiles.tokenizer.vocab_size == 30522)
        let expected: [String: Int32] = ["[PAD]": 0, "[UNK]": 100, "[CLS]": 101, "[SEP]": 102, "[MASK]": 103]
        for (token, id) in expected {
            #expect(Self.tokenizer.id(of: token) == id)
            #expect(FixtureFiles.tokenizer.special_tokens[token] == id)
        }
    }

    @Test("padding and attention mask")
    func paddingAndMask() {
        let encoded = Self.tokenizer.encode("hello world")
        #expect(encoded.inputIDs == [101, 7592, 2088, 102])
        let padded = encoded.paddedIDs(to: 256)
        let mask = encoded.attentionMask(to: 256)
        #expect(padded.count == 256 && mask.count == 256)
        #expect(Array(padded.prefix(4)) == encoded.inputIDs)
        #expect(padded.dropFirst(4).allSatisfy { $0 == 0 })
        #expect(mask.filter { $0 == 1 }.count == 4)
        #expect(Array(mask.prefix(4)) == [1, 1, 1, 1] && mask[4] == 0)
        let empty = Self.tokenizer.encode("   ")
        #expect(empty.inputIDs == [101, 102] && empty.attentionMask(to: 256).reduce(0, +) == 2)
    }

    @Test("a vocabulary with the wrong line count is rejected")
    func badVocabulary() throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("vocab.txt")
        try "[PAD]\n[UNK]\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: EmbeddingError.invalidVocabulary(2)) { try WordPieceTokenizer.load(contentsOf: url) }
    }

    @Test("capital sigma lowercases per character (σ, never the final ς), like transformers")
    func finalSigma() {
        #expect(WordPieceTokenizer.lowercased(Array("ΟΔΟΣ".unicodeScalars)) == Array("οδοσ".unicodeScalars))
        #expect(WordPieceTokenizer.lowercased(Array("ΣΑ".unicodeScalars)) == Array("σα".unicodeScalars))
        // ids from Python BertTokenizer (slow and fast agree): ... "##σ" 29733, not "##ς" 19579.
        #expect(Self.tokenizer.encode("ΟΔΟΣ").inputIDs == [101, 1169, 29722, 29730, 29733, 102])
        #expect(Self.tokenizer.encode("ΟΔΥΣΣΕΥΣ").inputIDs.dropLast().last == 29733)
    }

    @Test("special tokens are split out of the raw text, even inside a word")
    func specialTokensInline() {
        typealias S = WordPieceTokenizer.Segment
        #expect(WordPieceTokenizer.splitOnSpecialTokens("hello[SEP]world") == [S.text("hello"), .special("[SEP]"), .text("world")])
        #expect(WordPieceTokenizer.splitOnSpecialTokens("[SEP][SEP]") == [S.special("[SEP]"), .special("[SEP]")])
        #expect(WordPieceTokenizer.splitOnSpecialTokens("[mask] [MASK") == [S.text("[mask] [MASK")])
        // ids from Python BertTokenizer (slow and fast agree).
        #expect(Self.tokenizer.encode("hello[SEP]world [UNK]x").inputIDs == [101, 7592, 102, 2088, 100, 1060, 102])
        #expect(Self.tokenizer.encode("x[CLS]y [MASK] [mask] [PAD]z").inputIDs
                == [101, 1060, 101, 1061, 103, 1031, 7308, 1033, 0, 1062, 102])
        #expect(Self.tokenizer.encode("[SEP][SEP]").inputIDs == [101, 102, 102, 102])
        // A special token broken by a format character is ordinary text (Python: "[", "sep", "]").
        #expect(Self.tokenizer.encode("a [SE\u{200B}P] b").inputIDs == [101, 1037, 1031, 19802, 1033, 1038, 102])
    }
}
