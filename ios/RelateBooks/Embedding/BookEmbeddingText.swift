import CryptoKit
import Foundation

/// The text a Book is embedded from (D12), and its staleness hash (D2).
///
/// `title · authors · up to 15 subjects · description (first 800 scalars)`,
/// joined with " · " and with empty parts dropped. Books without a
/// description fall back to the first three parts. The model truncates at
/// 256 tokens.
///
/// Subjects are filtered (no `nyt:` / `collection:` tags, no call numbers,
/// no catalogue boilerplate), deduped case-insensitively and sorted, which
/// keeps the text deterministic. A real-model run over the whole store
/// chose this rule: Project Hail Mary scored cosine 0.587 for "lonely
/// astronaut saves earth" against 0.452 for the runner-up.
enum BookEmbeddingText {
    static let separator = " \u{00B7} "
    static let maxSubjects = 15
    static let descriptionScalars = 800

    /// Catalogue subjects that say nothing about the book (lowercased).
    static let subjectStoplist: Set<String> = [
        "fiction", "nonfiction", "general", "new york times bestseller", "new york times reviewed",
        "large type books", "accessible book", "protected daisy", "in library", "lending library",
        "long now manual for civilization", "open library staff picks", "popular print disabled books",
        "overdrive",
    ]

    /// Trimmed, non-empty, deduped case-insensitively (first spelling kept),
    /// sorted.
    static func normalizedAuthors(_ names: [String]) -> [String] {
        sortedUnique(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    /// Trimmed and filtered (see the type comment), deduped, sorted, at most 15.
    static func normalizedSubjects(_ names: [String]) -> [String] {
        let kept = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { name in
                !name.isEmpty && !name.contains(":") && !name.contains("=")
                    && name.unicodeScalars.contains(where: isLetter)
                    && !subjectStoplist.contains(name.lowercased())
            }
        return Array(sortedUnique(kept).prefix(maxSubjects))
    }

    /// Joins already-normalized parts (no normalization here, so it also
    /// reproduces the Python fixture strings).
    static func join(title: String, authors: [String], subjects: [String], description: String?) -> String {
        [title, authors.joined(separator: ", "), subjects.joined(separator: ", "), description ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }

    static func text(for input: BookEmbeddingInput) -> String {
        let trimmedTitle = input.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = trimmedTitle.isEmpty ? input.key : trimmedTitle
        var description: String?
        if let raw = input.description?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            description = prefix(raw, scalars: descriptionScalars)
        }
        return join(title: title, authors: normalizedAuthors(input.authors),
                    subjects: normalizedSubjects(input.subjects), description: description)
    }

    /// Lowercase hex SHA-256 of UTF-8 "<modelID>\n<text>".
    static func hash(text: String, modelID: String) -> String {
        let digest = SHA256.hash(data: Data("\(modelID)\n\(text)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The first `n` Unicode scalars (Python `s[:n]`).
    static func prefix(_ s: String, scalars n: Int) -> String {
        let scalars = s.unicodeScalars
        guard scalars.count > n else { return s }
        return String(String.UnicodeScalarView(scalars.prefix(n)))
    }

    private static func isLetter(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    /// Dedupe by `lowercased()` keeping the first, then sort by
    /// (lowercased, raw).
    private static func sortedUnique(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        var unique: [String] = []
        for name in names where seen.insert(name.lowercased()).inserted {
            unique.append(name)
        }
        return unique.sorted { a, b in
            let la = a.lowercased(), lb = b.lowercased()
            return la != lb ? la < lb : a < b
        }
    }
}

/// One Book as the embedding scan reads it (`EmbeddingQueries.scanBooks`).
struct BookEmbeddingInput: Sendable, Equatable {
    let key: String
    let title: String?
    let authors: [String]
    let subjects: [String]
    let description: String?
    let storedModel: String?
    let storedHash: String?
    let hasEmbedding: Bool

    init(key: String, title: String?, authors: [String] = [], subjects: [String] = [], description: String? = nil,
         storedModel: String? = nil, storedHash: String? = nil, hasEmbedding: Bool = false) {
        self.key = key
        self.title = title
        self.authors = authors
        self.subjects = subjects
        self.description = description
        self.storedModel = storedModel
        self.storedHash = storedHash
        self.hasEmbedding = hasEmbedding
    }

    init(row: Row) throws {
        self.init(key: try row.requiredString("key"),
                  title: row["title"].stringValue,
                  authors: row.strings("authors"),
                  subjects: row.strings("subjects"),
                  description: row["description"].stringValue,
                  storedModel: row["model"].stringValue,
                  storedHash: row["hash"].stringValue,
                  hasEmbedding: row.bool("hasEmbedding") ?? false)
    }

    var text: String { BookEmbeddingText.text(for: self) }

    /// Needs (re-)embedding: no vector, another model, or the text changed.
    func isStale(modelID: String) -> Bool {
        !hasEmbedding || storedModel != modelID || storedHash != BookEmbeddingText.hash(text: text, modelID: modelID)
    }
}

/// One Note as the embedding scan reads it. Its hash covers the raw note text.
struct NoteEmbeddingInput: Sendable, Equatable {
    let id: String
    let text: String
    let storedModel: String?
    let storedHash: String?
    let hasEmbedding: Bool

    init(id: String, text: String, storedModel: String? = nil, storedHash: String? = nil, hasEmbedding: Bool = false) {
        self.id = id
        self.text = text
        self.storedModel = storedModel
        self.storedHash = storedHash
        self.hasEmbedding = hasEmbedding
    }

    init(row: Row) throws {
        self.init(id: try row.requiredString("id"),
                  text: row["text"].stringValue ?? "",
                  storedModel: row["model"].stringValue,
                  storedHash: row["hash"].stringValue,
                  hasEmbedding: row.bool("hasEmbedding") ?? false)
    }

    func isStale(modelID: String) -> Bool {
        !hasEmbedding || storedModel != modelID || storedHash != BookEmbeddingText.hash(text: text, modelID: modelID)
    }
}
