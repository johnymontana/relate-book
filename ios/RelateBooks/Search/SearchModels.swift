import Foundation

/// Optional filters applied after fusion (D9), in the hydrate query.
struct SearchFilter: Sendable, Hashable {
    var status: ReadingStatus?
    var tag: String?

    init(status: ReadingStatus? = nil, tag: String? = nil) {
        self.status = status
        self.tag = tag
    }

    var isEmpty: Bool { status == nil && tag == nil }
}

/// Why a result matched (the row's reason label).
enum MatchReason: String, Sendable, Hashable, CaseIterable {
    case semantic, keyword, note, both
    /// Found only through the graph: a neighbour of a top hit.
    case related

    var label: String {
        switch self {
        case .semantic: "Semantic"
        case .keyword: "Keyword"
        case .note: "Your note"
        case .both: "Semantic + keyword"
        case .related: "Related"
        }
    }

    var systemImage: String {
        switch self {
        case .semantic: "sparkles"
        case .keyword: "textformat"
        case .note: "note.text"
        case .both: "sparkle.magnifyingglass"
        case .related: "point.3.connected.trianglepath.dotted"
        }
    }
}

/// The candidate lists a result appeared in.
struct MatchSources: OptionSet, Sendable, Hashable {
    let rawValue: Int
    static let semantic = MatchSources(rawValue: 1 << 0)
    static let keyword = MatchSources(rawValue: 1 << 1)
    static let note = MatchSources(rawValue: 1 << 2)
    /// The graph neighbours of the top hits.
    static let related = MatchSources(rawValue: 1 << 3)
}

/// One fused result before hydration: its lists, ranks and scores.
struct SearchHit: Sendable, Hashable {
    let key: String
    let reason: MatchReason
    let sources: MatchSources
    /// 1-based positions in each list.
    let semanticRank: Int?
    let keywordRank: Int?
    let noteRank: Int?
    /// 1-based position among the graph neighbours of the top hits.
    let relatedRank: Int?
    /// The strongest link to a top hit (its other book is that hit).
    let relation: BookConnection?
    /// Cosine similarity in [-1, 1] (the engine's SEARCH score is (1 + cos) / 2).
    let semanticCosine: Double?
    /// The fulltext score (summed term frequency).
    let keywordScore: Double?
    /// Every query term is in the title, item title or byline.
    let titleMatch: Bool
    let noteCosine: Double?
    let noteID: String?
    let noteSnippet: String?
    /// Σ 1 / (k + rank) over the lists containing the book.
    let fusedScore: Double

    /// The secondary line under a result row, e.g. "Semantic 0.59" or
    /// "Your note: “trains…”".
    var detailText: String {
        switch reason {
        case .note:
            guard let noteSnippet else { return MatchReason.note.label }
            return "Your note: “\(Self.shorten(noteSnippet, to: 40))”"
        case .both:
            return "Semantic \(Self.format(semanticCosine)) + keyword"
        case .semantic:
            return "Semantic \(Self.format(semanticCosine))"
        case .keyword:
            return titleMatch ? "Keyword (title or author)" : "Keyword"
        case .related:
            return relation?.phrase ?? MatchReason.related.label
        }
    }

    static func format(_ cosine: Double?) -> String {
        String(format: "%.2f", cosine ?? 0)
    }

    /// The first `n` characters (whitespace collapsed) plus "…" when cut.
    static func shorten(_ text: String, to n: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > n else { return flat }
        return String(flat.prefix(n)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// A displayable result: the book row plus why it matched.
struct SearchResult: Sendable, Hashable, Identifiable {
    let book: BookSummary
    let hit: SearchHit
    /// The book's strongest link to something the user read, is reading or
    /// rated highly; nil when there is none.
    var because: ReadingConnection? = nil
    var id: String { book.key }
}

struct SearchResponse: Sendable, Hashable {
    /// The trimmed query text.
    let query: String
    let results: [SearchResult]
    /// False when there is no embedder or embedding the query failed
    /// (results are keyword only).
    let semanticAvailable: Bool
    /// The sanitized fulltext terms (empty: no keyword search ran).
    let keywordTerms: [String]

    var isEmpty: Bool { results.isEmpty }

    /// A copy with each row's book replaced by `transform` (status patches).
    func mapBooks(_ transform: (BookSummary) -> BookSummary) -> SearchResponse {
        SearchResponse(query: query,
                       results: results.map { SearchResult(book: transform($0.book), hit: $0.hit, because: $0.because) },
                       semanticAvailable: semanticAvailable, keywordTerms: keywordTerms)
    }
}

/// Knobs for `SearchService` (D9).
struct SearchTuning: Sendable, Equatable {
    var semanticLimit = 50
    var keywordLimit = 50
    var noteLimit = 20
    var rrfK = 60.0
    /// Notes below this cosine are not a match.
    var minNoteCosine = 0.30
    var resultLimit = 50
    /// Characters of note text kept on a hit.
    var noteSnippetLength = 160

    // Graph expansion: the neighbours of the top hits as a fourth list.
    /// How many of the top fused hits are expanded. 0 turns expansion off.
    var relatedSeeds = 5
    /// A hit found only by its vector is a seed when its cosine is at least
    /// this; a keyword or note hit always is. Below it, the "top hit" of a
    /// query nothing matches would drag its neighbours in.
    var minSeedCosine = 0.35
    /// At most this many neighbours join the fusion.
    var relatedLimit = 10
    /// The neighbours rank from this position on: the n-th counts as rank
    /// `relatedRankOffset + n`, so a book found only through the graph
    /// never outranks the hits it was reached from.
    var relatedRankOffset = 5
    /// Neighbours linked more weakly than this are dropped (a link weighs
    /// `strength / degree / seed position`; see `ConnectionQueries`).
    var minRelatedWeight = 0.05
    /// Shared nodes on more books than this link nothing.
    var maxConnectionDegree = ConnectionQueries.defaultMaxDegree
    /// Attach each result's link to the user's reading (`SearchResult.because`).
    var explainsResults = true
}
