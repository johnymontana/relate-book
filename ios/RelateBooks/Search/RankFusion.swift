/// Reciprocal rank fusion over the candidate lists (D9), pure: semantic,
/// keyword, notes, and the graph neighbours of the top hits.
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
    /// - Reason: note if a note matched, else both, semantic or keyword;
    ///   related only when the graph is the sole source.
    /// - `related` ranks start after `relatedOffset`: its n-th entry adds
    ///   `1 / (k + relatedOffset + n)`. A book also in another list is
    ///   lifted by it and keeps that list's reason.
    static func fuse(semantic: [SemanticCandidate], keyword: [KeywordCandidate], notes: [NoteCandidate],
                     related: [RelatedCandidate] = [], relatedOffset: Int = 0, k: Double = 60) -> [SearchHit] {
        struct Entry {
            var semanticRank: Int?, keywordRank: Int?, noteRank: Int?, relatedRank: Int?
            var semantic: SemanticCandidate?, keyword: KeywordCandidate?, note: NoteCandidate?
            var related: RelatedCandidate?
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
        rank = max(0, relatedOffset)
        for c in related where entries[c.key]?.relatedRank == nil {
            rank += 1
            let r = rank
            entry(c.key) { $0.relatedRank = r; $0.related = c }
        }

        let hits: [SearchHit] = order.map { key in
            let e = entries[key]!
            var sources: MatchSources = []
            var fused = 0.0
            if let r = e.semanticRank { sources.insert(.semantic); fused += 1 / (k + Double(r)) }
            if let r = e.keywordRank { sources.insert(.keyword); fused += 1 / (k + Double(r)) }
            if let r = e.noteRank { sources.insert(.note); fused += 1 / (k + Double(r)) }
            if let r = e.relatedRank { sources.insert(.related); fused += 1 / (k + Double(r)) }
            let reason: MatchReason =
                if sources.contains(.note) { .note }
                else if sources.contains([.semantic, .keyword]) { .both }
                else if sources.contains(.semantic) { .semantic }
                else if sources.contains(.keyword) { .keyword }
                else { .related }
            return SearchHit(key: key, reason: reason, sources: sources,
                             semanticRank: e.semanticRank, keywordRank: e.keywordRank, noteRank: e.noteRank,
                             relatedRank: e.relatedRank, relation: e.related?.connection,
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
        [hit.semanticRank, hit.keywordRank, hit.noteRank, hit.relatedRank].compactMap { $0 }.min() ?? Int.max
    }
}
