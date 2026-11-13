/// Reciprocal rank fusion over the three candidate lists (D9), pure.
enum RankFusion {
    struct SemanticCandidate: Sendable, Equatable {
        let key: String
        /// Cosine in [-1, 1]: 2 * score - 1.
        let cosine: Double
    }

    struct KeywordCandidate: Sendable, Equatable {
        let key: String
        let score: Double
        let titleMatch: Bool

        init(key: String, score: Double, titleMatch: Bool = false) {
            self.key = key
            self.score = score
            self.titleMatch = titleMatch
        }
    }

    struct NoteCandidate: Sendable, Equatable {
        let key: String
        let cosine: Double
        let noteID: String
        let snippet: String
    }

    /// Each list is already ordered best first; a key repeated within a list
    /// keeps its first position. rank = 1-based position.
    ///
    /// - fused = Σ 1 / (k + rank) over the lists containing the key.
    /// - Order: fused desc, then the smallest rank, then a title/author
    ///   keyword match first, then semantic cosine desc (none last), then key.
    /// - Reason: note if a note matched, else both, semantic or keyword.
    static func fuse(semantic: [SemanticCandidate], keyword: [KeywordCandidate], notes: [NoteCandidate],
                     k: Double = 60) -> [SearchHit] {
        struct Entry {
            var semanticRank: Int?, keywordRank: Int?, noteRank: Int?
            var semantic: SemanticCandidate?, keyword: KeywordCandidate?, note: NoteCandidate?
        }
        var entries: [String: Entry] = [:]
        var order: [String] = []
        func entry(_ key: String, _ update: (inout Entry) -> Void) {
            if entries[key] == nil {
                entries[key] = Entry()
                order.append(key)
            }
            update(&entries[key]!)
        }
        var rank = 0
        for c in semantic where entries[c.key]?.semanticRank == nil {
            rank += 1
            let r = rank
            entry(c.key) { $0.semanticRank = r; $0.semantic = c }
        }
        rank = 0
        for c in keyword where entries[c.key]?.keywordRank == nil {
            rank += 1
            let r = rank
            entry(c.key) { $0.keywordRank = r; $0.keyword = c }
        }
        rank = 0
        for c in notes where entries[c.key]?.noteRank == nil {
            rank += 1
            let r = rank
            entry(c.key) { $0.noteRank = r; $0.note = c }
        }

        let hits: [SearchHit] = order.map { key in
            let e = entries[key]!
            var sources: MatchSources = []
            var fused = 0.0
            if let r = e.semanticRank { sources.insert(.semantic); fused += 1 / (k + Double(r)) }
            if let r = e.keywordRank { sources.insert(.keyword); fused += 1 / (k + Double(r)) }
            if let r = e.noteRank { sources.insert(.note); fused += 1 / (k + Double(r)) }
            let reason: MatchReason =
                if sources.contains(.note) { .note }
                else if sources.contains([.semantic, .keyword]) { .both }
                else if sources.contains(.semantic) { .semantic }
                else { .keyword }
            return SearchHit(key: key, reason: reason, sources: sources,
                             semanticRank: e.semanticRank, keywordRank: e.keywordRank, noteRank: e.noteRank,
                             semanticCosine: e.semantic?.cosine, keywordScore: e.keyword?.score,
                             titleMatch: e.keyword?.titleMatch ?? false,
                             noteCosine: e.note?.cosine, noteID: e.note?.noteID, noteSnippet: e.note?.snippet,
                             fusedScore: fused)
        }
        return hits.sorted(by: precedes)
    }

    static func precedes(_ a: SearchHit, _ b: SearchHit) -> Bool {
        if a.fusedScore != b.fusedScore { return a.fusedScore > b.fusedScore }
        let ra = bestRank(a), rb = bestRank(b)
        if ra != rb { return ra < rb }
        // A keyword hit on the title or author wins an exact tie against
        // a hit without one ("weir": The Martian, keyword #1, ties a
        // semantic-only #1).
        if a.titleMatch != b.titleMatch { return a.titleMatch }
        switch (a.semanticCosine, b.semanticCosine) {
        case let (x?, y?) where x != y: return x > y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.key < b.key
        }
    }

    private static func bestRank(_ hit: SearchHit) -> Int {
        [hit.semanticRank, hit.keywordRank, hit.noteRank].compactMap { $0 }.min() ?? Int.max
    }
}
