import Testing
import Foundation
import Relate
@testable import RelateBooksCore

/// A small graph with every kind of link between books:
///
/// | key | title | author | series | award | subjects | place |
/// | --- | --- | --- | --- | --- | --- | --- |
/// | /works/H1W | The Left Hand of Darkness | Ursula K. Le Guin | Hainish Cycle 4 | Hugo Award | Gethen, Novels | |
/// | /works/H2W | The Dispossessed | Ursula K. Le Guin | Hainish Cycle 5 | | Gethen, Novels | |
/// | /works/H3W | The Lathe of Heaven | Ursula K. Le Guin | | | Novels | Portland |
/// | /works/W1W | Project Hail Mary | Andy Weir | | Hugo Award | Space, Novels | Houston |
/// | /works/W2W | The Martian | Andy Weir | | | Space, Novels | Houston |
/// | /works/X1W | Weeknight Pasta | Lidia Cook | | | Novels | |
///
/// "Novels" is on all six books: with `maxDegree: 5` it links nothing, and
/// neither does it by share (more than a third of the library). Weeknight
/// Pasta and The Martian also share two noise subjects, a machine tag
/// ("nyt:list=1") and a stoplisted heading ("General"), which never link.
enum ConnectionFixture {
    static let h1 = "/works/H1W", h2 = "/works/H2W", h3 = "/works/H3W"
    static let w1 = "/works/W1W", w2 = "/works/W2W", x1 = "/works/X1W"
    static let hubDegree = 5

    static let books: [EmbeddingFixture.Book] = [
        .init(key: h1, title: "The Left Hand of Darkness", authors: ["Ursula K. Le Guin"], subjects: ["Gethen", "Novels"],
              description: "An envoy visits a winter planet whose people have no fixed gender."),
        .init(key: h2, title: "The Dispossessed", authors: ["Ursula K. Le Guin"], subjects: ["Gethen", "Novels"],
              description: "A physicist leaves his anarchist moon for its rich twin world."),
        .init(key: h3, title: "The Lathe of Heaven", authors: ["Ursula K. Le Guin"], subjects: ["Novels"],
              description: "A man whose dreams change reality is sent to a psychiatrist."),
        .init(key: w1, title: "Project Hail Mary", authors: ["Andy Weir"], subjects: ["Space", "Novels"],
              description: "A lone astronaut wakes on a ship and must save the earth."),
        .init(key: w2, title: "The Martian", authors: ["Andy Weir"], subjects: ["Space", "Novels", "nyt:list=1", "General"],
              description: "A botanist is stranded on Mars and grows potatoes."),
        .init(key: x1, title: "Weeknight Pasta", authors: ["Lidia Cook"], subjects: ["Novels", "nyt:list=1", "General"],
              description: "Italian recipes for busy evenings."),
    ]

    static let links = """
        MATCH (h1:Book {key: '/works/H1W'}), (h2:Book {key: '/works/H2W'}), (h3:Book {key: '/works/H3W'}),
              (w1:Book {key: '/works/W1W'}), (w2:Book {key: '/works/W2W'})
        CREATE (cycle:Series {name: 'Hainish Cycle'}), (hugo:Award {name: 'Hugo Award'})
        CREATE (houston:Place {name: 'Houston'}), (portland:Place {name: 'Portland'})
        CREATE (h1)-[:PART_OF {position: '4'}]->(cycle), (h2)-[:PART_OF {position: '5'}]->(cycle)
        CREATE (h1)-[:WON {year: 1970}]->(hugo), (w1)-[:WON {year: 2022}]->(hugo)
        CREATE (w1)-[:SET_IN]->(houston), (w2)-[:SET_IN]->(houston), (h3)-[:SET_IN]->(portland)
        """

    static func store() async throws -> GraphStore {
        let store = try await EmbeddingFixture.store(books)
        try await store.query(links)
        return store
    }
}

@Suite("Connections between books")
struct ConnectionTests {
    typealias F = ConnectionFixture

    @Test("neighbours of one seed: summed rarity-weighted links, strongest link named, hubs and the seed left out")
    func relatedToOneSeed() async throws {
        let store = try await F.store()
        let related = try await store.relatedCandidates(seeds: [F.h1], limit: 10, maxDegree: F.hubDegree)
        // H2: series 4/2 + author 3/3 + Gethen 1/2 = 3.5. H3: author 3/3. W1: award 2/2.
        #expect(related.map(\.key) == [F.h2, F.h3, F.w1])
        #expect(abs(related[0].weight - 3.5) < 1e-9 && abs(related[1].weight - 1) < 1e-9 && abs(related[2].weight - 1) < 1e-9)
        #expect(related[0].connection == BookConnection(kind: .series, name: "Hainish Cycle", otherKey: F.h1,
                                                        otherTitle: "The Left Hand of Darkness", weight: 2))
        #expect(related[0].connection.phrase == "Same series as The Left Hand of Darkness")
        #expect(related[1].connection.kind == .author && related[1].connection.name == "Ursula K. Le Guin")
        #expect(related[2].connection.phrase == "Won the Hugo Award, like The Left Hand of Darkness")
        // A higher cap alone does not let the hub in: it is on more than a third of the library.
        #expect(try await store.relatedCandidates(seeds: [F.h1], limit: 10, maxDegree: 10).map(\.key) == [F.h2, F.h3, F.w1])
        // With the share rule lifted too, the book that shares only "Novels" arrives, at 1/6.
        let withHub = try await store.relatedCandidates(seeds: [F.h1], limit: 10, maxDegree: 10, maxShare: 1)
        #expect(Set(withHub.map(\.key)) == [F.h2, F.h3, F.w1, F.w2, F.x1])
        let pasta = try #require(withHub.first { $0.key == F.x1 })
        #expect(abs(pasta.weight - 1.0 / 6) < 1e-9 && pasta.connection == BookConnection(
            kind: .subject, name: "Novels", otherKey: F.h1, otherTitle: "The Left Hand of Darkness", weight: 1.0 / 6))
        // Noise subjects never link, whatever the caps: The Martian reaches Weeknight Pasta only through "Novels".
        let fromMartian = try await store.relatedCandidates(seeds: [F.w2], limit: 10, maxDegree: 10, maxShare: 1)
        #expect(fromMartian.first { $0.key == F.x1 }?.connection.name == "Novels")
        #expect(try await store.relatedCandidates(seeds: [F.w2], limit: 10).map(\.key) == [F.w1])
        #expect(try await store.connections(to: F.w2, from: [F.x1], maxDegree: 10).isEmpty)
        try await store.setStatus(key: F.w2, status: .read)
        #expect(try await store.readingConnections(keys: [F.x1], minWeight: 0, maxDegree: 10).isEmpty)
    }

    @Test("several seeds: a later seed's links count less, seeds are never returned, the limit holds")
    func relatedToSeveralSeeds() async throws {
        let store = try await F.store()
        let related = try await store.relatedCandidates(seeds: [F.w1, F.h1], limit: 10, maxDegree: F.hubDegree)
        // W2 from seed 1: author 3/2 + Space 1/2 + Houston 1/2 = 2.5. H2 from seed 2: 3.5 / 2. H3: 1 / 2.
        #expect(related.map(\.key) == [F.w2, F.h2, F.h3])
        #expect(abs(related[0].weight - 2.5) < 1e-9 && abs(related[1].weight - 1.75) < 1e-9 && abs(related[2].weight - 0.5) < 1e-9)
        #expect(related[0].connection.kind == .author && related[0].connection.otherKey == F.w1)
        #expect(try await store.relatedCandidates(seeds: [F.w1, F.h1], limit: 1, maxDegree: F.hubDegree).map(\.key) == [F.w2])
        #expect(try await store.relatedCandidates(seeds: [], limit: 10).isEmpty)
        #expect(try await store.relatedCandidates(seeds: ["/works/NOPE"], limit: 10).isEmpty)
    }

    @Test("links to the user's reading: read, reading or rated at least 4; a rating weighs more")
    func readingConnections() async throws {
        let store = try await F.store()
        #expect(try await store.readingConnections(keys: [F.h2, F.w1, F.x1], maxDegree: F.hubDegree).isEmpty)
        try await store.setStatus(key: F.h1, status: .read)
        try await store.setRating(key: F.h1, rating: 5)
        try await store.setStatus(key: F.w2, status: .reading)
        let links = try await store.readingConnections(keys: [F.h2, F.w1, F.x1, F.h1], perBook: 3, maxDegree: F.hubDegree)
        #expect(Set(links.keys) == [F.h2, F.w1])
        // H2 shares a series, an author and a subject with H1: one reason, named by the strongest (4/2 * 2).
        let h2 = try #require(links[F.h2])
        #expect(h2.map(\.connection.kind) == [.series] && h2[0].connection.weight == 4)
        #expect(h2[0].phrase == "Same series as The Left Hand of Darkness, which you rated 5")
        #expect(h2[0].status == .read && h2[0].rating == 5)
        // W1 has two reasons, one per book. The Martian comes first: it shares the author (3/2), a subject
        // and a place (2.5 in all), against the award shared with the rated book (2/2 * 2 = 2).
        let w1 = try #require(links[F.w1])
        #expect(w1.map(\.connection.otherKey) == [F.w2, F.h1])
        #expect(w1[0].connection.kind == .author && w1[0].phrase == "By Andy Weir, like The Martian, which you’re reading")
        #expect(w1[1].connection.kind == .award && w1[1].rating == 5)
        // A floor on the weight drops the weaker reasons: for H2 only the series (4.0) is above 3.
        #expect(try await store.readingConnections(keys: [F.h2, F.w1], perBook: 3, minWeight: 3, maxDegree: F.hubDegree)
            .mapValues { $0.map(\.connection.kind) } == [F.h2: [.series]])
        // One per book by default; a rating below 4 on an unread book is not a reason.
        #expect(try await store.readingConnections(keys: [F.h2], maxDegree: F.hubDegree)[F.h2]?.count == 1)
        try await store.setStatus(key: F.w2, status: .want)
        try await store.setRating(key: F.w2, rating: 3)
        let after = try await store.readingConnections(keys: [F.w1], perBook: 3, maxDegree: F.hubDegree)
        #expect(after[F.w1]?.map(\.connection.otherKey) == [F.h1])
    }

    @Test("links to one given book, for the books beside it")
    func connectionsToAnAnchor() async throws {
        let store = try await F.store()
        let links = try await store.connections(to: F.h1, from: [F.h2, F.h3, F.w1, F.x1, F.h1], maxDegree: F.hubDegree)
        #expect(Set(links.keys) == [F.h2, F.h3, F.w1])
        #expect(links[F.h2]?.shortPhrase == "Same series")
        #expect(links[F.h3]?.shortPhrase == "Same author")
        #expect(links[F.w1]?.shortPhrase == "Both won the Hugo Award")
        #expect(links[F.h2]?.otherKey == F.h1)
        #expect(try await store.connections(to: F.h1, from: []).isEmpty)
    }

    @Test("statement shape: fixed relationship types, values as parameters, no subquery clause")
    func statements() throws {
        let related = try ConnectionQueries.related(seeds: ["a'); MATCH (n) DETACH DELETE n //"], limit: 0, maxDegree: 1)
        #expect(!related.cypher.contains("DETACH") && related.parameters["limit"] == .int(1) && related.parameters["maxDegree"] == .int(2))
        #expect(ConnectionQueries.noiseSubjects.contains("general") && ConnectionQueries.noiseSubjects.contains("romans, nouvelles"))
        #expect(ConnectionQueries.noiseSubjects == ConnectionQueries.noiseSubjects.map { $0.lowercased() }.sorted())
        #expect(related.cypher.contains("PART_OF|WRITTEN_BY|WON|FEATURES|SET_IN|ABOUT|SET_DURING"))
        for statement in [related, try ConnectionQueries.reading(keys: ["k"]), try ConnectionQueries.between(anchor: "a", keys: ["k"])] {
            #expect(!statement.cypher.contains("CALL"))
        }
        #expect(ConnectionKind(relationship: "PART_OF") == .series && ConnectionKind(relationship: "IN_GENRE") == nil)
        #expect(ConnectionQueries.strengthCase("via").contains("WHEN 'PART_OF' THEN 4.0") )
        #expect(ReadingConnection.clause(status: .read, rating: nil) == "which you read")
    }
}

@Suite("Graph-expanded search")
struct RelatedSearchTests {
    typealias F = ConnectionFixture
    typealias S = RankFusion.SemanticCandidate
    typealias K = RankFusion.KeywordCandidate

    static func related(_ key: String, _ weight: Double, seed: String = "A") -> RelatedCandidate {
        RelatedCandidate(key: key, weight: weight,
                         connection: BookConnection(kind: .series, name: "Cycle", otherKey: seed, otherTitle: "Seed", weight: weight))
    }

    @Test("fusion: neighbours rank after the offset, lift a book already found, and are 'related' only on their own")
    func fusion() throws {
        let semantic = [S(key: "A", cosine: 0.9), S(key: "B", cosine: 0.8), S(key: "C", cosine: 0.7)]
        let hits = RankFusion.fuse(semantic: semantic, keyword: [K(key: "A", score: 3)], notes: [],
                                   related: [Self.related("R", 2), Self.related("C", 1)], relatedOffset: 5)
        // C: semantic #3 plus related #7 passes B (semantic #2); R alone (related #6) comes last.
        #expect(hits.map(\.key) == ["A", "C", "B", "R"])
        let c = try #require(hits.first { $0.key == "C" })
        #expect(c.reason == .semantic && c.sources == [.semantic, .related] && c.relatedRank == 7)
        #expect(abs(c.fusedScore - (1.0 / 63 + 1.0 / 67)) < 1e-12)
        let r = try #require(hits.last)
        #expect(r.reason == .related && r.sources == .related && r.relatedRank == 6 && r.semanticCosine == nil)
        #expect(abs(r.fusedScore - 1.0 / 66) < 1e-12)
        #expect(r.detailText == "Same series as Seed" && r.relation?.otherKey == "A")
        // Without the list, nothing changes; a repeated neighbour keeps its first position.
        #expect(RankFusion.fuse(semantic: semantic, keyword: [], notes: []).map(\.relatedRank) == [nil, nil, nil])
        let twice = RankFusion.fuse(semantic: [], keyword: [], notes: [], related: [Self.related("R", 2), Self.related("R", 1)])
        #expect(twice.count == 1 && twice[0].relatedRank == 1 && twice[0].relation?.weight == 2)
        #expect(MatchReason.related.label == "Related")
    }

    @Test("seeds: the top hits that matched by keyword or note, or closely enough by vector")
    func seeds() {
        let hits = RankFusion.fuse(
            semantic: [S(key: "near", cosine: 0.6), S(key: "far", cosine: 0.2), S(key: "both", cosine: 0.1)],
            keyword: [K(key: "both", score: 1), K(key: "word", score: 1)], notes: [])
        var tuning = SearchTuning()
        #expect(SearchService.seeds(hits, tuning: tuning) == ["both", "near", "word"])
        tuning.relatedSeeds = 2
        #expect(SearchService.seeds(hits, tuning: tuning) == ["both", "near"])
        tuning.relatedSeeds = 0
        #expect(SearchService.seeds(hits, tuning: tuning).isEmpty)
    }

    @Test("keyword search: the series, the author's other book and the co-winner follow the hit, each with its reason")
    func keywordOnly() async throws {
        let store = try await F.store()
        var tuning = SearchTuning()
        tuning.maxConnectionDegree = F.hubDegree
        let service = SearchService(store: store, embedder: nil, tuning: tuning)
        let response = try await service.search("left hand darkness")
        #expect(response.results.map(\.book.key) == [F.h1, F.h2, F.h3, F.w1])
        #expect(response.results.map(\.hit.reason) == [.keyword, .related, .related, .related])
        #expect(response.results[1].hit.detailText == "Same series as The Left Hand of Darkness")
        #expect(response.results[2].hit.detailText == "By Ursula K. Le Guin, like The Left Hand of Darkness")
        #expect(response.results[1].hit.relatedRank == 6)
        // Nothing is read yet, so nothing is explained.
        #expect(response.results.allSatisfy { $0.because == nil })

        // Expansion off: only the direct hit.
        tuning.relatedSeeds = 0
        let plain = try await SearchService(store: store, embedder: nil, tuning: tuning).search("left hand darkness")
        #expect(plain.results.map(\.book.key) == [F.h1])
    }

    @Test("with vectors: a neighbour already in the semantic list is lifted and keeps its reason; results name the link to the user's reading")
    func withVectors() async throws {
        let store = try await F.store()
        try await EmbeddingIndexer(store: store, embedder: FakeEmbedder()).run()
        var tuning = SearchTuning()
        tuning.maxConnectionDegree = F.hubDegree
        var off = tuning
        off.relatedSeeds = 0
        let query = "left hand darkness"
        let before = try await SearchService(store: store, embedder: FakeEmbedder(), tuning: off).search(query)
        let after = try await SearchService(store: store, embedder: FakeEmbedder(), tuning: tuning).search(query)
        #expect(before.results.first?.book.key == F.h1 && after.results.first?.book.key == F.h1)
        #expect(Set(before.results.map(\.book.key)) == Set(after.results.map(\.book.key)))
        let h2Before = try #require(before.results.firstIndex { $0.book.key == F.h2 })
        let h2After = try #require(after.results.firstIndex { $0.book.key == F.h2 })
        #expect(h2After <= h2Before && h2After == 1)
        let h2 = after.results[h2After]
        #expect(h2.hit.sources.contains([.semantic, .related]) && h2.hit.reason == .semantic)
        #expect(h2.hit.relation?.kind == .series)

        try await store.setRating(key: F.h1, rating: 5)
        let explained = try await SearchService(store: store, embedder: FakeEmbedder(), tuning: tuning).search(query)
        let dispossessed = try #require(explained.results.first { $0.book.key == F.h2 })
        #expect(dispossessed.because?.phrase == "Same series as The Left Hand of Darkness, which you rated 5")
        #expect(explained.results.first { $0.book.key == F.x1 }?.because == nil)
        // A status patch keeps the explanation.
        #expect(explained.mapBooks { $0 }.results.first { $0.book.key == F.h2 }?.because == dispossessed.because)
        var silent = tuning
        silent.explainsResults = false
        let unexplained = try await SearchService(store: store, embedder: FakeEmbedder(), tuning: silent).search(query)
        #expect(unexplained.results.allSatisfy { $0.because == nil })
    }

    @Test("a query nothing matches expands nothing")
    func weakSeedsExpandNothing() async throws {
        let store = try await F.store()
        try await EmbeddingIndexer(store: store, embedder: FakeEmbedder()).run()
        var tuning = SearchTuning()
        tuning.maxConnectionDegree = F.hubDegree
        let response = try await SearchService(store: store, embedder: FakeEmbedder(), tuning: tuning).search("zzqx vvkw")
        #expect(response.results.allSatisfy { !$0.hit.sources.contains(.related) })
    }
}
