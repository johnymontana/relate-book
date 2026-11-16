import Testing
import Foundation
import Relate
@testable import RelateBooksCore

@Suite("Keyword sanitizer")
struct KeywordQueryTests {
    @Test("sanitizes quotes, fields, parens, wildcards, operators and stopwords")
    func cases() {
        #expect(KeywordQuery("\"hail mary\"")?.terms == ["hail", "mary"])
        #expect(KeywordQuery("title:mary")?.terms == ["title", "mary"])
        #expect(KeywordQuery("(mary)")?.terms == ["mary"])
        #expect(KeywordQuery("astro*")?.terms == ["astro"])
        #expect(KeywordQuery("mary AND hail OR NOT x")?.terms == ["mary", "hail"])
        #expect(KeywordQuery("the of a") == nil)
        #expect(KeywordQuery("C++") == nil)
        #expect(KeywordQuery("o'brien")?.terms == ["brien"])
        #expect(KeywordQuery("sci-fi")?.terms == ["sci", "fi"])
        #expect(KeywordQuery("Café Été")?.terms == ["café", "été"])
        let twelve = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima"
        #expect(KeywordQuery(twelve)?.terms == ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"])
        #expect(KeywordQuery("earth Earth EARTH moon")?.terms == ["earth", "moon"])
        #expect(KeywordQuery("") == nil)
        #expect(KeywordQuery("   ") == nil)
        #expect(KeywordQuery("le guin")?.text == "le guin")
    }

    @Test("coverage needs every term as a whole token")
    func coverage() throws {
        let q = try #require(KeywordQuery("lonely astronaut saves earth"))
        #expect(q.terms == ["lonely", "astronaut", "saves", "earth"])
        #expect(q.isCovered(by: ["The lonely astronaut", nil, "He saves the Earth."]))
        #expect(!q.isCovered(by: ["The lonely astronaut saves an earthquake victim"]))
        #expect(!q.isCovered(by: ["lonely astronaut"]))
        #expect(!q.isCovered(by: []))
    }
}

@Suite("Rank fusion")
struct RankFusionTests {
    typealias S = RankFusion.SemanticCandidate
    typealias K = RankFusion.KeywordCandidate
    typealias N = RankFusion.NoteCandidate

    @Test("RRF order and reasons")
    func basic() throws {
        let hits = RankFusion.fuse(semantic: [S(key: "A", cosine: 0.9), S(key: "B", cosine: 0.8), S(key: "C", cosine: 0.7)],
                                   keyword: [K(key: "C", score: 5), K(key: "D", score: 3)], notes: [])
        #expect(hits.map(\.key) == ["C", "A", "B", "D"])
        #expect(hits.map(\.reason) == [.both, .semantic, .semantic, .keyword])
        let c = try #require(hits.first)
        #expect(abs(c.fusedScore - (1.0 / 63 + 1.0 / 61)) < 1e-12)
        #expect(c.semanticRank == 3 && c.keywordRank == 1 && c.noteRank == nil)
        #expect(c.semanticCosine == 0.7 && c.keywordScore == 5)
        #expect(c.sources == [.semantic, .keyword])
        #expect(hits[3].sources == .keyword && hits[3].semanticCosine == nil)
    }

    @Test("a note match makes the reason note")
    func note() throws {
        let hits = RankFusion.fuse(semantic: [S(key: "A", cosine: 0.5), S(key: "B", cosine: 0.4)],
                                   keyword: [K(key: "B", score: 2)],
                                   notes: [N(key: "B", cosine: 0.6, noteID: "n1", snippet: "steam trains")])
        let b = try #require(hits.first { $0.key == "B" })
        #expect(b.reason == .note && b.sources == [.semantic, .keyword, .note])
        #expect(b.noteID == "n1" && b.noteSnippet == "steam trains" && b.noteCosine == 0.6)
        #expect(hits.first?.key == "B")
        #expect(b.detailText == "Your note: “steam trains”")
    }

    @Test("duplicates keep their first position; empty keyword list is pure semantic order")
    func duplicatesAndEmpty() {
        let hits = RankFusion.fuse(semantic: [S(key: "A", cosine: 0.9), S(key: "A", cosine: 0.1), S(key: "B", cosine: 0.8)],
                                   keyword: [], notes: [])
        #expect(hits.map(\.key) == ["A", "B"])
        #expect(hits[0].semanticCosine == 0.9 && hits[1].semanticRank == 2)
        let keywordDup = RankFusion.fuse(semantic: [], keyword: [K(key: "X", score: 9), K(key: "Y", score: 5), K(key: "X", score: 1)], notes: [])
        #expect(keywordDup.map(\.key) == ["X", "Y"] && keywordDup[0].keywordScore == 9)
        #expect(RankFusion.fuse(semantic: [], keyword: [], notes: []).isEmpty)
    }

    @Test("ties: smallest rank, then semantic cosine, then key")
    func ties() {
        // B (semantic #2) and D (keyword #2) tie on fused score and rank: B has a cosine.
        let a = RankFusion.fuse(semantic: [S(key: "A", cosine: 0.9), S(key: "B", cosine: 0.8)],
                                keyword: [K(key: "C", score: 3), K(key: "D", score: 2)], notes: [])
        #expect(a.map(\.key) == ["A", "C", "B", "D"])
        // ...unless D's keyword hit is on the title or author.
        let titled = RankFusion.fuse(semantic: [S(key: "A", cosine: 0.9), S(key: "B", cosine: 0.8)],
                                     keyword: [K(key: "C", score: 3), K(key: "D", score: 2, titleMatch: true)], notes: [])
        #expect(titled.map(\.key) == ["A", "C", "D", "B"])
        let weir = RankFusion.fuse(semantic: [S(key: "Park", cosine: 0.35)], keyword: [K(key: "Martian", score: 1, titleMatch: true)], notes: [])
        #expect(weir.map(\.key) == ["Martian", "Park"])
        // Two keyword-only hits with the same fused score and rank cannot occur; two semantic
        // entries at the same rank in different lists tie on cosine order, then key.
        let b = RankFusion.fuse(semantic: [S(key: "Z", cosine: 0.5)], keyword: [K(key: "Y", score: 1)], notes: [])
        #expect(b.map(\.key) == ["Z", "Y"])
        let c = RankFusion.fuse(semantic: [], keyword: [K(key: "M", score: 1)],
                                notes: [N(key: "L", cosine: 0.4, noteID: "n", snippet: "s")])
        #expect(c.map(\.key) == ["L", "M"])
    }

    @Test("detail text per reason")
    func detailText() {
        let hits = RankFusion.fuse(semantic: [S(key: "A", cosine: 0.587)], keyword: [K(key: "B", score: 2, titleMatch: true)], notes: [])
        #expect(hits.first { $0.key == "A" }?.detailText == "Semantic 0.59")
        #expect(hits.first { $0.key == "B" }?.detailText == "Keyword (title or author)")
        #expect(MatchReason.both.label == "Semantic + keyword" && MatchReason.note.label == "Your note")
        #expect(SearchHit.shorten("a  very long\nnote text that goes on and on and on forever", to: 20) == "a very long note tex…")
    }
}

@Suite("Search service")
struct SearchServiceTests {
    static let model = "fake-hash-384"

    /// The eight search books, all embedded with FakeEmbedder; S3 and S6 tagged "Favorites".
    static func store(embedAll: Bool = true) async throws -> GraphStore {
        let store = try await EmbeddingFixture.store(EmbeddingFixture.searchBooks)
        try await store.addTag(bookKey: "/works/S3W", name: "Favorites")
        try await store.addTag(bookKey: "/works/S6W", name: "Favorites")
        if embedAll {
            try await EmbeddingIndexer(store: store, embedder: FakeEmbedder()).run()
        }
        return store
    }

    @Test("the vector query returns the expected neighbour first")
    func semanticNeighbour() async throws {
        let store = try await Self.store()
        let q = try FakeEmbedder().vector("astronaut alone in space")
        let candidates = try await store.semanticCandidates(vector: q, limit: 50)
        #expect(candidates.count == 8)
        #expect(candidates.first?.key == "/works/S1W")
        #expect(zip(candidates, candidates.dropFirst()).allSatisfy { $0.cosine >= $1.cosine })
        let input = try #require(try await store.embeddingScanPage(after: "").first { $0.key == "/works/S1W" })
        let expected = EmbeddingVector.cosine(q, try FakeEmbedder().vector(input.text))
        #expect(abs((candidates.first?.cosine ?? 0) - expected) < 1e-4)          // cosine = 2 * score - 1
    }

    @Test("hybrid search ranks the matching book first")
    func astronaut() async throws {
        let service = SearchService(store: try await Self.store(), embedder: FakeEmbedder())
        let response = try await service.search("  astronaut alone in space ")
        #expect(response.query == "astronaut alone in space")
        #expect(response.semanticAvailable)
        #expect(response.keywordTerms == ["astronaut", "alone", "space"])
        let first = try #require(response.results.first)
        #expect(first.book.key == "/works/S1W")
        #expect(first.hit.reason == .semantic || first.hit.reason == .both)
        #expect(first.book.title == "The Lonely Astronaut" && first.book.authors == ["Ann Star"])
        #expect(response.results.count == 8)
    }

    @Test("an exact title query is semantic + keyword")
    func exactTitle() async throws {
        let service = SearchService(store: try await Self.store(), embedder: FakeEmbedder())
        let response = try await service.search("Gardens of the Moon")
        let first = try #require(response.results.first)
        #expect(first.book.key == "/works/S2W")
        #expect(first.hit.reason == .both && first.hit.titleMatch)
        #expect(response.results.filter { $0.hit.sources.contains(.keyword) }.map(\.book.key) == ["/works/S2W"])
    }

    @Test("status and tag filters apply after fusion")
    func filters() async throws {
        let service = SearchService(store: try await Self.store(), embedder: FakeEmbedder())
        let read = try await service.search("history of money", filter: SearchFilter(status: .read))
        #expect(Set(read.results.map(\.book.key)) == ["/works/S1W", "/works/S5W"])
        #expect(read.results.first?.book.key == "/works/S5W")
        #expect(read.results.allSatisfy { $0.book.status == .read })
        let want = try await service.search("history of money", filter: SearchFilter(status: .want))
        #expect(want.results.count == 5 && want.results.allSatisfy { $0.book.status == .want })
        let tagged = try await service.search("pasta recipes", filter: SearchFilter(tag: "Favorites"))
        #expect(Set(tagged.results.map(\.book.key)) == ["/works/S3W", "/works/S6W"])
        #expect(tagged.results.first?.book.key == "/works/S6W")
        let both = try await service.search("pasta recipes", filter: SearchFilter(status: .reading, tag: "Favorites"))
        #expect(both.results.map(\.book.key) == ["/works/S3W"])
        #expect(try await service.search("pasta", filter: SearchFilter(tag: "Nope")).results.isEmpty)
    }

    @Test("a matching note makes its book a note result; an unrelated query does not")
    func notes() async throws {
        let store = try await Self.store()
        try await store.addNote(bookKey: "/works/S6W", text: "the steam trains through the alps")
        #expect(try await EmbeddingIndexer(store: store, embedder: FakeEmbedder()).embedNotes(bookKey: "/works/S6W") == 1)
        let service = SearchService(store: store, embedder: FakeEmbedder())
        let response = try await service.search("steam trains")
        let first = try #require(response.results.first)
        #expect(first.book.key == "/works/S6W")
        #expect(first.hit.reason == .note)
        #expect(first.hit.noteSnippet == "the steam trains through the alps")
        #expect((first.hit.noteCosine ?? 0) >= 0.30)
        let unrelated = try await service.search("quantum chromodynamics")
        #expect(!unrelated.results.contains { $0.hit.reason == .note })
    }

    @Test("without an embedder (or when it fails) search is keyword only")
    func keywordOnly() async throws {
        let store = try await Self.store()
        for embedder in [nil, FailingEmbedder() as (any TextEmbedder)?] {
            let service = SearchService(store: store, embedder: embedder)
            let response = try await service.search("astronaut")
            #expect(!response.semanticAvailable)
            #expect(response.results.map(\.book.key) == ["/works/S1W"])
            #expect(response.results.first?.hit.reason == .keyword)
        }
        let none = try await SearchService(store: store, embedder: nil).search("zzzqqq")
        #expect(none.results.isEmpty && none.isEmpty)
        let short = try await SearchService(store: store, embedder: FakeEmbedder()).search(" a ")
        #expect(short.results.isEmpty && short.keywordTerms.isEmpty)
    }

    @Test("with half the books embedded, search returns semantic hits from that half plus keyword hits")
    func partialIndex() async throws {
        let store = try await Self.store(embedAll: false)
        let inputs = try await store.embeddingScanPage(after: "")
        let half = inputs.filter { ["/works/S1W", "/works/S2W", "/works/S3W", "/works/S4W"].contains($0.key) }
        try await store.writeBookEmbeddings(try half.map { input in
            BookEmbeddingRow(key: input.key, vector: try FakeEmbedder().vector(input.text),
                             hash: BookEmbeddingText.hash(text: input.text, modelID: Self.model))
        }, model: Self.model)
        let response = try await SearchService(store: store, embedder: FakeEmbedder()).search("pasta recipes")
        let semanticKeys = Set(response.results.filter { $0.hit.sources.contains(.semantic) }.map(\.book.key))
        #expect(semanticKeys == ["/works/S1W", "/works/S2W", "/works/S3W", "/works/S4W"])
        let pasta = try #require(response.results.first { $0.book.key == "/works/S6W" })
        #expect(pasta.hit.reason == .keyword && pasta.hit.keywordRank == 1)
        // Keyword #1 ties the semantic #1 on fused score; the semantic hit wins the tie (it has a cosine).
        #expect(response.results.prefix(2).contains { $0.book.key == "/works/S6W" })
    }

    @Test("more like this excludes the seed, is ordered by similarity, and is empty for an un-embedded book")
    func moreLikeThis() async throws {
        let store = try await Self.store()
        try await store.query("""
            UNWIND range(1, 12) AS n
            CREATE (:Book {key: '/works/X' + toString(n) + 'W', title: 'Lonely astronaut sequel ' + toString(n)})
            """)
        try await EmbeddingIndexer(store: store, embedder: FakeEmbedder()).run()
        try await store.query("CREATE (:Book {key: '/works/NOEMB', title: 'Not embedded'})")
        let service = SearchService(store: store, embedder: FakeEmbedder())
        let similar = try await service.moreLikeThis(key: "/works/S1W")
        #expect(similar.count == 10)
        #expect(!similar.contains { $0.key == "/works/S1W" })
        // Expected order from the stored vectors.
        let inputs = try await store.embeddingScanPage(after: "")
        let fake = FakeEmbedder()
        let seed = try fake.vector(try #require(inputs.first { $0.key == "/works/S1W" }).text)
        let ranked = try inputs.filter { $0.key != "/works/S1W" && $0.key != "/works/NOEMB" }
            .map { ($0.key, EmbeddingVector.cosine(seed, try fake.vector($0.text))) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        // Many sequels tie exactly; compare by cosine, not by key, at the boundary.
        let cosineByKey = Dictionary(uniqueKeysWithValues: ranked)
        let returned = similar.map { cosineByKey[$0.key] ?? -2 }
        #expect(abs(returned[0] - ranked[0].1) < 1e-5)
        #expect(zip(returned, returned.dropFirst()).allSatisfy { $0 >= $1 - 1e-5 })
        #expect(returned.allSatisfy { $0 >= ranked[9].1 - 1e-5 })
        #expect(try await service.moreLikeThis(key: "/works/NOEMB").isEmpty)
        #expect(try await service.moreLikeThis(key: "/works/MISSING").isEmpty)
        #expect(try await service.moreLikeThis(key: "/works/S1W", limit: 3).count == 3)
    }

    @Test("hostile fulltext strings: the sanitizer's output is always accepted; raw, only a trailing backslash is refused (V6)")
    func hostileStrings() async throws {
        let store = try await Self.store()
        for raw in ["\"quoted\"", "a:b", "(x)", "x*", "AND", "\\", "x\\", "\\x", "[x]", "{x}", "&&", "?"] {
            let rawQuery = KeywordQuery(terms: [raw])
            if raw.hasSuffix("\\") {
                // Relate main (after 1.0.1): a trailing backslash escapes
                // nothing and is a syntax error. 1.0.1 accepted it.
                await #expect(throws: RelateError.self) { _ = try await store.bookTextHits(rawQuery, limit: 50) }
                await #expect(throws: RelateError.self) { _ = try await store.itemTextHits(rawQuery, limit: 50) }
            } else {
                _ = try await store.bookTextHits(rawQuery, limit: 50)
                _ = try await store.itemTextHits(rawQuery, limit: 50)
            }
            if let sanitized = KeywordQuery(raw) {
                #expect(!sanitized.text.contains("\\"))
                _ = try await store.bookTextHits(sanitized, limit: 50)
                _ = try await store.itemTextHits(sanitized, limit: 50)
            }
        }
        let quoted = try await store.bookTextHits(KeywordQuery(terms: ["\"astronaut\""]), limit: 50)
        #expect(quoted.map(\.key) == ["/works/S1W"])
        // Relate 1.0.1: upper-case AND is an operator in the raw string; the
        // sanitizer lower-cases and drops it, so the terms are ORed again.
        let raw = "astronaut AND zzunmatched"
        #expect(try await store.bookTextHits(KeywordQuery(terms: [raw]), limit: 50).isEmpty)
        let sanitized = try #require(KeywordQuery(raw))
        #expect(sanitized.text == "astronaut zzunmatched")
        #expect(try await store.bookTextHits(sanitized, limit: 50).map(\.key) == ["/works/S1W"])
        let byline = try await store.itemTextHits(try #require(KeywordQuery("erikson")), limit: 50)
        #expect(byline.map(\.key) == ["/works/S2W"])
    }

    @Test("keyword candidates: the all-terms gate, title match first")
    func keywordGate() throws {
        let q = try #require(KeywordQuery("le guin darkness"))
        let books = [
            BookTextHit(key: "A", score: 9, title: "Darkness Falls", description: "No author here", firstSentence: nil),
            BookTextHit(key: "B", score: 2, title: "The Left Hand of Darkness", description: nil, firstSentence: nil),
            BookTextHit(key: "C", score: 5, title: "Essays", description: "Le Guin on darkness and light", firstSentence: nil),
        ]
        let items = [ItemTextHit(key: "B", score: 4, bookTitle: "The Left Hand of Darkness", itemTitle: "Left Hand", byline: "Ursula K. Le Guin")]
        let out = SearchService.keywordCandidates(query: q, books: books, items: items)
        #expect(out.map(\.key) == ["B", "C"])
        #expect(out[0].titleMatch && !out[1].titleMatch)
        #expect(out[0].score == 2 && out[1].score == 5)
    }
}
