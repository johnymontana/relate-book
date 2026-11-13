import Foundation

/// The token ids for one text: `[CLS] wordpieces… [SEP]`, unpadded.
struct TokenizedText: Sendable, Equatable {
    /// With [CLS] (101) and [SEP] (102); at most `maxLength` entries.
    let inputIDs: [Int32]
    /// True when wordpieces were dropped to fit `maxLength`.
    let truncated: Bool
    /// Wordpiece count + 2, before truncation.
    let untruncatedLength: Int

    /// `inputIDs` padded with [PAD] (0) to `n` (or cut to `n`).
    func paddedIDs(to n: Int) -> [Int32] {
        var ids = Array(inputIDs.prefix(n))
        if ids.count < n { ids.append(contentsOf: repeatElement(WordPieceTokenizer.padID, count: n - ids.count)) }
        return ids
    }

    /// 1 for each real token (including [CLS] and [SEP]), then 0 up to `n`.
    func attentionMask(to n: Int) -> [Int32] {
        let ones = min(inputIDs.count, n)
        return Array(repeating: 1, count: ones) + Array(repeating: 0, count: n - ones)
    }
}

/// An exact port of the slow `transformers.BertTokenizer` (4.56.2) as
/// configured for all-MiniLM-L6-v2: uncased (lowercase + strip accents),
/// CJK ideographs split, `##` continuation pieces, at most 100 scalars per
/// word.
///
/// Everything works on `Unicode.Scalar`s, never `Character`s (grapheme
/// clusters would merge combining marks and ZWJ sequences), and the
/// vocabulary is keyed by UTF-8 bytes: Swift `String` equality uses
/// canonical equivalence and Python's does not.
///
/// `tokenizer_fixtures.json` (written by `scripts/convert_embedding_model.py`)
/// pins the behaviour; `TokenizerTests` checks all 50 cases.
struct WordPieceTokenizer: Sendable {
    static let padID: Int32 = 0
    static let unkID: Int32 = 100
    static let clsID: Int32 = 101
    static let sepID: Int32 = 102
    static let maskID: Int32 = 103
    static let vocabularySize = 30522
    static let maxInputCharsPerWord = 100
    /// Literal strings the added-token trie splits out of the raw text
    /// wherever they occur (even inside a word), before any normalization.
    /// Case-sensitive: "[mask]" is ordinary text.
    static let specialTokens: [String] = ["[PAD]", "[UNK]", "[CLS]", "[SEP]", "[MASK]"]
    private static let specialTokenScalars: [[Unicode.Scalar]] = specialTokens.map { Array($0.unicodeScalars) }

    private let ids: [[UInt8]: Int32]
    let count: Int
    /// The longest vocabulary entry in scalars; longer substrings cannot
    /// match, so the greedy search starts there (same result, less work).
    private let maxPieceScalars: Int

    /// `vocabulary[i]` gets id `i`; a duplicate token keeps its first id.
    init(vocabulary: [String]) {
        var ids: [[UInt8]: Int32] = [:]
        ids.reserveCapacity(vocabulary.count)
        var longest = 1
        for (index, token) in vocabulary.enumerated() {
            let bytes = Array(token.utf8)
            if ids[bytes] == nil { ids[bytes] = Int32(index) }
            longest = max(longest, token.unicodeScalars.count)
        }
        self.ids = ids
        self.count = vocabulary.count
        self.maxPieceScalars = longest
    }

    /// One token per line, id = 0-based line index. Requires 30,522 entries.
    static func load(contentsOf url: URL) throws -> WordPieceTokenizer {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
        }
        if lines.last == "" { lines.removeLast() }
        guard lines.count == vocabularySize else { throw EmbeddingError.invalidVocabulary(lines.count) }
        return WordPieceTokenizer(vocabulary: lines)
    }

    /// The id of an exact token, if it is in the vocabulary.
    func id(of token: String) -> Int32? { ids[Array(token.utf8)] }

    // MARK: Encode

    /// `[CLS] + first (maxLength - 2) wordpiece ids + [SEP]`.
    func encode(_ text: String, maxLength: Int = EmbeddingSpace.maxTokens) -> TokenizedText {
        let pieces = wordpieceIDs(text)
        let room = max(0, maxLength - 2)
        let kept = pieces.count > room ? Array(pieces.prefix(room)) : pieces
        return TokenizedText(inputIDs: [Self.clsID] + kept + [Self.sepID],
                             truncated: pieces.count + 2 > maxLength,
                             untruncatedLength: pieces.count + 2)
    }

    /// The wordpieces as strings, without [CLS]/[SEP] (tests, debugging).
    func tokenize(_ text: String) -> [String] {
        var out: [String] = []
        for unit in units(text) {
            guard case .word(let token) = unit else {
                if case .special(let special) = unit { out.append(special) }
                continue
            }
            for piece in wordpieces(token) {
                switch piece {
                case .unknown: out.append("[UNK]")
                case .piece(let start, let end):
                    let body = String(String.UnicodeScalarView(token[start..<end]))
                    out.append(start > 0 ? "##" + body : body)
                }
            }
        }
        return out
    }

    private func wordpieceIDs(_ text: String) -> [Int32] {
        var out: [Int32] = []
        for unit in units(text) {
            guard case .word(let token) = unit else {
                if case .special(let special) = unit { out.append(id(of: special) ?? Self.unkID) }
                continue
            }
            for piece in wordpieces(token) {
                switch piece {
                case .unknown: out.append(Self.unkID)
                case .piece(let start, let end):
                    out.append(ids[pieceBytes(token, start, end)] ?? Self.unkID)
                }
            }
        }
        return out
    }

    // MARK: Special tokens

    private enum Unit {
        case special(String)
        case word([Unicode.Scalar])
    }

    /// `PreTrainedTokenizer.tokenize`: special tokens are cut out of the raw
    /// text first; every segment between them goes through the basic
    /// tokenizer on its own.
    private func units(_ text: String) -> [Unit] {
        var out: [Unit] = []
        for segment in Self.splitOnSpecialTokens(text) {
            switch segment {
            case .special(let special): out.append(.special(special))
            case .text(let body): out.append(contentsOf: basicTokens(body).map(Unit.word))
            }
        }
        return out
    }

    enum Segment: Equatable {
        case text(String)
        case special(String)
    }

    /// The added-token trie split: leftmost match wins, scanning the raw
    /// scalars (the five literals share no prefixes, so longest = only).
    static func splitOnSpecialTokens(_ text: String) -> [Segment] {
        let scalars = Array(text.unicodeScalars)
        var out: [Segment] = []
        var start = 0
        var i = 0
        func flush(_ end: Int) {
            if end > start { out.append(.text(String(String.UnicodeScalarView(scalars[start..<end])))) }
        }
        while i < scalars.count {
            if scalars[i] == "[",
               let match = specialTokenScalars.firstIndex(where: { special in
                   i + special.count <= scalars.count && scalars[i..<(i + special.count)].elementsEqual(special)
               }) {
                flush(i)
                out.append(.special(specialTokens[match]))
                i += specialTokenScalars[match].count
                start = i
            } else {
                i += 1
            }
        }
        flush(scalars.count)
        return out
    }

    // MARK: WordPiece

    private enum Piece {
        case piece(start: Int, end: Int)
        case unknown
    }

    private func pieceBytes(_ token: [Unicode.Scalar], _ start: Int, _ end: Int) -> [UInt8] {
        var bytes: [UInt8] = start > 0 ? [0x23, 0x23] : []   // "##"
        for scalar in token[start..<end] { bytes.append(contentsOf: UTF8.encode(scalar)!) }
        return bytes
    }

    /// Greedy longest-match-first. A token with an unmatchable remainder,
    /// or longer than 100 scalars, becomes a single [UNK].
    private func wordpieces(_ token: [Unicode.Scalar]) -> [Piece] {
        let n = token.count
        if n > Self.maxInputCharsPerWord { return [.unknown] }
        var pieces: [Piece] = []
        var start = 0
        while start < n {
            var end = min(n, start + maxPieceScalars)
            var found = false
            while start < end {
                if ids[pieceBytes(token, start, end)] != nil {
                    found = true
                    break
                }
                end -= 1
            }
            if !found { return [.unknown] }
            pieces.append(.piece(start: start, end: end))
            start = end
        }
        return pieces
    }

    // MARK: Basic tokenizer

    /// BasicTokenizer.tokenize on one segment between special tokens: clean,
    /// space out CJK, NFC, whitespace split, then per token lowercase + strip
    /// accents + punctuation split. (Python lowercases the raw text one
    /// character at a time before this runs, so an uppercase special token
    /// can never reach BasicTokenizer's never_split check; the per-scalar
    /// `lowercased` here gives the same result in a different order.)
    func basicTokens(_ text: String) -> [[Unicode.Scalar]] {
        // 1. Clean + 2. CJK spacing.
        var cleaned = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 0 || v == 0xFFFD || Self.isControl(scalar) { continue }
            if Self.isWhitespace(scalar) {
                cleaned.append(" ")
            } else if Self.isCJK(v) {
                cleaned.append(" ")
                cleaned.append(scalar)
                cleaned.append(" ")
            } else {
                cleaned.append(scalar)
            }
        }
        // 3. NFC.
        let nfc = String(cleaned).precomposedStringWithCanonicalMapping
        // 4. Whitespace split.
        var output: [[Unicode.Scalar]] = []
        for token in Self.splitOnWhitespace(Array(nfc.unicodeScalars)) {
            // 5a. Lowercase, 5b. NFD + drop Mn.
            let lowered = Self.lowercased(token)
            let nfd = String(String.UnicodeScalarView(lowered)).decomposedStringWithCanonicalMapping
            let stripped = nfd.unicodeScalars.filter { $0.properties.generalCategory != .nonspacingMark }
            // 5c. Punctuation split, 6. whitespace split again (drops empties).
            var current: [Unicode.Scalar] = []
            for scalar in stripped {
                if Self.isPunctuation(scalar) {
                    if !current.isEmpty { output.append(contentsOf: Self.splitOnWhitespace(current)); current = [] }
                    output.append([scalar])
                } else {
                    current.append(scalar)
                }
            }
            if !current.isEmpty { output.append(contentsOf: Self.splitOnWhitespace(current)) }
        }
        return output
    }

    /// Python `str.split()` after cleaning: the whitespace left is U+0020,
    /// U+2028 and U+2029 (every other Python whitespace is Cc or Zs).
    static func splitOnWhitespace(_ scalars: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
        var out: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        for scalar in scalars {
            if isPythonSpace(scalar) {
                if !current.isEmpty { out.append(current); current = [] }
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func isPythonSpace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x20, 0x09...0x0D, 0x1C...0x1F, 0x85, 0x2028, 0x2029: return true
        default: return s.properties.generalCategory == .spaceSeparator
        }
    }

    /// `_is_whitespace`: space, \t, \n, \r, or category Zs.
    static func isWhitespace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x20, 0x09, 0x0A, 0x0D: return true
        default: return s.properties.generalCategory == .spaceSeparator
        }
    }

    /// `_is_control`: category C* except \t, \n, \r.
    static func isControl(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09, 0x0A, 0x0D: return false
        default:
            switch s.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned: return true
            default: return false
            }
        }
    }

    /// `_is_punctuation`: all non-alphanumeric printable ASCII, or category P*.
    static func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 33...47, 58...64, 91...96, 123...126: return true
        default:
            switch s.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .otherPunctuation:
                return true
            default:
                return false
            }
        }
    }

    /// `_is_chinese_char`: the CJK Unified Ideographs blocks (not kana or Hangul).
    static func isCJK(_ v: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
            || (0x20000...0x2A6DF).contains(v) || (0x2A700...0x2B73F).contains(v)
            || (0x2B740...0x2B81F).contains(v) || (0x2B820...0x2CEAF).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0x2F800...0x2FA1F).contains(v)
    }

    /// Python `c.lower()` applied to one character at a time (what
    /// `PreTrainedTokenizer.tokenize` does when `do_lower_case` is set): the
    /// full lowercase mapping per scalar, with no context rules, so a
    /// word-final capital Σ becomes σ, never ς (the fast tokenizer agrees).
    static func lowercased(_ token: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(token.count)
        for scalar in token {
            out.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
        }
        return out
    }
}
