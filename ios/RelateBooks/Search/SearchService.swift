import Foundation

/// Hybrid search (plan §3.4, D9) and "More like this" (D11).
///
/// Three candidate lists, fused with reciprocal rank fusion (k = 60):
/// 1. Semantic: the query embedded on device, top 50 on `book_embedding`.
/// 2. Keyword: `book_text` top 50 plus `item_text` top 50 mapped to Books,
///    kept only when the book contains every sanitized term (title,
///    description, first sentence, item title or byline). Without that gate
///    the engine's OR / term-frequency ranking puts any book mentioning one
///    common term ("earth") in the list, and plain RRF pushed Project Hail
///    Mary out of the top 5 for "lonely astronaut saves earth".
/// 3. Notes: top 20 on `note_embedding`, mapped to the owning Book, with
///    note cosine >= 0.30.
///
/// Status and tag filters apply after fusion, in the hydrate query. Search
/// works on whatever is embedded so far, so it is usable while indexing.
struct SearchService: Sendable {
    let store: GraphStore
    let embedder: (any TextEmbedder)?
    var tuning = SearchTuning()

    init(store: GraphStore, embedder: (any TextEmbedder)?, tuning: SearchTuning = SearchTuning()) {
        self.store = store
        self.embedder = embedder
        self.tuning = tuning
    }

    func search(_ raw: String, filter: SearchFilter = SearchFilter()) async throws -> SearchResponse {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else {
            return SearchResponse(query: text, results: [], semanticAvailable: embedder != nil, keywordTerms: [])
        }

        var semanticAvailable = false
        var semantic: [RankFusion.SemanticCandidate] = []
        var notes: [RankFusion.NoteCandidate] = []
        if let embedder {
            var query: [Float]?
            do {
                query = try await embedder.embed([text]).first
                semanticAvailable = query != nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.query.error("query embedding failed; keyword only: \(error.localizedDescription, privacy: .public)")
            }
            if let query {
                semantic = try await store.semanticCandidates(vector: query, limit: tuning.semanticLimit)
                notes = try await store.noteCandidates(vector: query, limit: tuning.noteLimit,
                                                       snippetLength: tuning.noteSnippetLength)
                    .filter { $0.cosine >= tuning.minNoteCosine }
                    .sorted { $0.cosine != $1.cosine ? $0.cosine > $1.cosine : $0.key < $1.key }
            }
        }

        let keywordQuery = KeywordQuery(text)
        var keyword: [RankFusion.KeywordCandidate] = []
        if let keywordQuery {
            let books = try await store.bookTextHits(keywordQuery, limit: tuning.keywordLimit)
            let items = try await store.itemTextHits(keywordQuery, limit: tuning.keywordLimit)
            keyword = Self.keywordCandidates(query: keywordQuery, books: books, items: items)
        }

        let hits = RankFusion.fuse(semantic: semantic, keyword: keyword, notes: notes, k: tuning.rrfK)
        let summaries = try await store.hydrateSearch(keys: hits.map(\.key), filter: filter, limit: tuning.resultLimit)
        let byKey = Dictionary(summaries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let results = hits.compactMap { hit in byKey[hit.key].map { SearchResult(book: $0, hit: hit) } }
        return SearchResponse(query: text, results: results, semanticAvailable: semanticAvailable,
                              keywordTerms: keywordQuery?.terms ?? [])
    }

    /// Merges the two fulltext lists per book, applies the all-terms gate
    /// and orders: title/author match first, then book_text score, then
    /// item score, then key.
    static func keywordCandidates(query: KeywordQuery, books: [BookTextHit], items: [ItemTextHit]) -> [RankFusion.KeywordCandidate] {
        struct Merged {
            var bookScore: Double?
            var itemScore: Double?
            var coverage: [String?] = []
            var titles: [String?] = []
        }
        var merged: [String: Merged] = [:]
        for hit in books {
            var m = merged[hit.key] ?? Merged()
            m.bookScore = max(m.bookScore ?? hit.score, hit.score)
            m.coverage += [hit.title, hit.description, hit.firstSentence]
            m.titles.append(hit.title)
            merged[hit.key] = m
        }
        for hit in items {
            var m = merged[hit.key] ?? Merged()
            m.itemScore = max(m.itemScore ?? hit.score, hit.score)
            m.coverage += [hit.itemTitle, hit.byline, hit.bookTitle]
            m.titles += [hit.bookTitle, hit.itemTitle, hit.byline]
            merged[hit.key] = m
        }
        struct Ranked {
            let key: String
            let titleMatch: Bool
            let bookScore: Double
            let itemScore: Double
            let score: Double
        }
        let ranked: [Ranked] = merged.compactMap { key, m in
            guard query.isCovered(by: m.coverage) else { return nil }
            return Ranked(key: key, titleMatch: query.isCovered(by: m.titles), bookScore: m.bookScore ?? 0,
                          itemScore: m.itemScore ?? 0, score: m.bookScore ?? m.itemScore ?? 0)
        }
        return ranked
            .sorted { a, b in
                if a.titleMatch != b.titleMatch { return a.titleMatch }
                if a.bookScore != b.bookScore { return a.bookScore > b.bookScore }
                if a.itemScore != b.itemScore { return a.itemScore > b.itemScore }
                return a.key < b.key
            }
            .map { RankFusion.KeywordCandidate(key: $0.key, score: $0.score, titleMatch: $0.titleMatch) }
    }

    /// The books nearest to `key`'s stored vector, excluding it; [] when the
    /// book is not embedded yet.
    func moreLikeThis(key: String, limit: Int = 10) async throws -> [BookSummary] {
        try await store.moreLikeThis(key: key, limit: limit)
    }
}
