/// The sanitized fulltext query (D10).
///
/// Relate's fulltext indexes tokenize the query into lowercase letter/digit
/// runs, OR the terms and score by summed term frequency, and reject nothing
/// (V6). Relate 1.0.1 added one operator syntax: upper-case `AND`, `OR` and
/// `NOT` (0.16.1 treated them as words). The terms here are lower-case and
/// drop and/or/not as stopwords, so `text` never carries an operator. This
/// otherwise exists for ranking quality, not safety: it drops 1-character
/// tokens and stopwords, dedupes, keeps at most 8 terms, and gives the
/// coverage gate its terms.
struct KeywordQuery: Sendable, Equatable {
    let terms: [String]

    /// The `$text` parameter: the terms joined with spaces.
    var text: String { terms.joined(separator: " ") }

    /// nil when no term is left (both fulltext queries are skipped).
    init?(_ raw: String, maxTerms: Int = 8) {
        var seen: Set<String> = []
        var terms: [String] = []
        for token in Self.tokens(raw) where token.count >= 2 && !Self.stopwords.contains(token) {
            if seen.insert(token).inserted { terms.append(token) }
            if terms.count == maxTerms { break }
        }
        guard !terms.isEmpty else { return nil }
        self.terms = terms
    }

    init(terms: [String]) {
        self.terms = terms
    }

    /// Lowercased maximal runs of letters or digits, in order, not deduped
    /// (the engine's tokenizer).
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in s.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// True when every term is a token of the texts (tokens, not substrings:
    /// "earth" does not match "earthquake").
    func isCovered(by texts: [String?]) -> Bool {
        let available = Set(texts.compactMap { $0 }.flatMap(Self.tokens))
        return terms.allSatisfy(available.contains)
    }

    /// English stopwords plus the operator words and "book(s)".
    static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "but", "by", "can", "could", "did", "do", "does",
        "for", "from", "had", "has", "have", "he", "her", "his", "how", "i", "if", "in", "into", "is", "it",
        "its", "me", "my", "no", "not", "of", "on", "or", "our", "she", "so", "than", "that", "the", "their",
        "them", "then", "there", "these", "they", "this", "those", "to", "too", "up", "us", "was", "we", "were",
        "what", "when", "where", "which", "who", "whom", "why", "will", "with", "would", "you", "your", "about",
        "after", "all", "also", "any", "because", "before", "being", "between", "both", "each", "few", "more",
        "most", "other", "out", "over", "same", "some", "such", "through", "under", "until", "very", "while",
        "just", "only", "own", "again", "once", "here", "should", "now", "book", "books",
    ]
}
