import Testing
import Foundation
@testable import RelateBooksCore

@Suite("Book embedding text")
struct BookEmbeddingTextTests {
    static let model = EmbeddingSpace.modelID

    static func fixtureText(_ name: String) throws -> String {
        try #require(FixtureFiles.tokenizer.cases.first { $0.name == name }).text
    }

    @Test("join reproduces the Python fixture strings book_01...book_05")
    func joinMatchesPython() throws {
        let hailMary = BookEmbeddingText.prefix(try Self.fixtureText("long_text_truncated"), scalars: 800)
        let cases: [(String, String, [String], [String], String?)] = [
            ("book_01", "Project Hail Mary", ["Andy Weir"],
             ["Survival after airplane accidents, shipwrecks", "FICTION / Thrillers / Suspense",
              "FICTION / Science Fiction / Hard Science Fiction", "Habiletés de survie", "Vol spatial", "Astronautes"],
             hailMary),
            ("book_02", "The Left Hand of Darkness", ["Ursula K. Le Guin"],
             ["Fantasy", "Classics", "LGBTQ fiction before Stonewall", "Trahison (Morale)", "Loyauté", "science fiction"],
             nil),
            ("book_03", "Klara and the Sun", ["Kazuo Ishiguro"],
             ["FICTION / Visionary & Metaphysical", "FICTION / Science Fiction / General", "Amitié",
              "Intelligence artificielle"],
             "Klara and the Sun, the first novel by Kazuo Ishiguro since he was awarded the Nobel Prize in "
                + "Literature, tells the story of Klara, an Artificial Friend with outstanding observational qualities."),
            ("book_04", "Station Eleven", ["Emily St. John Mandel"],
             ["Dystopias", "Prophets", "Theatrical companies", "collection:Canada Reads 2023", "Epidemics",
              "Canadian fiction"],
             "One snowy night Arthur Leander, a famous actor, has a heart attack onstage during a production of "
                + "\"King Lear.\" Jeevan Chaudhary, a paparazzo-turned-EMT, is in the audience and leaps to his aid."),
            ("book_05", "Getting Things Done", ["David Allen"],
             ["Selbstorganisation", "Psychological Stress", "Creative ability in business", "Industrial management",
              "Zi wo(xin li xue)"],
             "In today's world, yesterday's methods just don't work. In Getting Things Done, veteran coach and "
                + "management consultant David Allen shares the breakthrough methods for stress-free performance."),
        ]
        for (name, title, authors, subjects, description) in cases {
            let joined = BookEmbeddingText.join(title: title, authors: authors, subjects: subjects, description: description)
            #expect(joined == (try Self.fixtureText(name)), "\(name)")
        }
        // The same strings are the embedding fixtures 1...5.
        #expect(FixtureFiles.embedding.cases[1].text == (try Self.fixtureText("book_01")))
    }

    @Test("no description: title · authors · subjects")
    func noDescription() {
        let input = BookEmbeddingInput(key: "/works/X", title: " Dune ", authors: ["Frank Herbert"],
                                       subjects: ["Science fiction", "Deserts"], description: "   ")
        #expect(input.text == "Dune · Frank Herbert · Deserts, Science fiction")
        #expect(input.text.components(separatedBy: BookEmbeddingText.separator).count == 3)
    }

    @Test("a description is cut at 800 scalars, counting emoji and accents by scalar")
    func longDescription() {
        let combining = "e\u{0301}"                                   // 2 scalars, 1 Character
        let body = String(repeating: "a", count: 797) + combining + "📚" + String(repeating: "z", count: 50)
        let input = BookEmbeddingInput(key: "/works/X", title: "T", description: body)
        let parts = input.text.components(separatedBy: BookEmbeddingText.separator)
        #expect(parts.count == 2)
        let description = parts[1]
        #expect(description.unicodeScalars.count == 800)
        #expect(description.hasSuffix(combining + "📚"))
        let short = BookEmbeddingInput(key: "/works/X", title: "T", description: String(repeating: "b", count: 800))
        #expect(short.text == "T · " + String(repeating: "b", count: 800))
    }

    @Test("no subjects and no authors: title · description; missing title uses the key")
    func sparse() {
        #expect(BookEmbeddingInput(key: "/works/X", title: "Piranesi", description: "A house of halls.").text
                == "Piranesi · A house of halls.")
        #expect(BookEmbeddingInput(key: "/works/X", title: nil).text == "/works/X")
        #expect(BookEmbeddingInput(key: "/works/X", title: "  ", authors: ["A"]).text == "/works/X · A")
    }

    @Test("subject filtering, dedupe, order and the cap of 15")
    func subjects() {
        let raw = ["nyt:hardcover-fiction=2018-05-06", "collection:Canada Reads 2023", "599.9", "Fiction",
                   "New York Times bestseller", "OVERDRIVE", "  Forests ", "forests", "Zebras", "apples", "Apples",
                   "key=value", "Sci027000 sci086000 sci000000", ""]
        #expect(BookEmbeddingText.normalizedSubjects(raw) == ["apples", "Forests", "Sci027000 sci086000 sci000000", "Zebras"])
        let many = (1...30).map { String(format: "Subject %02d", $0) }.reversed()
        let capped = BookEmbeddingText.normalizedSubjects(Array(many))
        #expect(capped.count == 15)
        #expect(capped.first == "Subject 01" && capped.last == "Subject 15")
    }

    @Test("authors are trimmed, deduped case-insensitively and sorted")
    func authors() {
        #expect(BookEmbeddingText.normalizedAuthors(["Tara Westover", " Orah Danḳner ", "tara westover", "", "David Allen", "David Allen"])
                == ["David Allen", "Orah Danḳner", "Tara Westover"])
    }

    @Test("permuted authors and subjects give the same text and hash")
    func permutation() {
        let a = BookEmbeddingInput(key: "/works/X", title: "T", authors: ["B", "A"], subjects: ["y", "X", "z"], description: "d")
        let b = BookEmbeddingInput(key: "/works/X", title: "T", authors: ["A", "B"], subjects: ["z", "y", "X"], description: "d")
        #expect(a.text == b.text)
        #expect(BookEmbeddingText.hash(text: a.text, modelID: Self.model) == BookEmbeddingText.hash(text: b.text, modelID: Self.model))
    }

    @Test("golden hashes; the hash changes with the model id")
    func hashes() {
        #expect(BookEmbeddingText.hash(text: "Project Hail Mary · Andy Weir", modelID: Self.model)
                == "c93ba672aedc7033ccd863a1bcfad84d1910123f5122e9494572037bb1433267")
        #expect(BookEmbeddingText.hash(text: "Loved the winter crossing of the Gobrin Ice.", modelID: Self.model)
                == "1ffe98bb425aa4635e8d288417681b3a4c389bc18c0ef8be04f2a0efe93f05ef")
        #expect(BookEmbeddingText.hash(text: "Project Hail Mary · Andy Weir", modelID: "other")
                != BookEmbeddingText.hash(text: "Project Hail Mary · Andy Weir", modelID: Self.model))
    }

    @Test("isStale: no embedding, other model, other hash, fresh")
    func staleness() {
        let base = BookEmbeddingInput(key: "/works/X", title: "T", authors: ["A"])
        let hash = BookEmbeddingText.hash(text: base.text, modelID: Self.model)
        func with(model: String?, hash: String?, has: Bool) -> BookEmbeddingInput {
            BookEmbeddingInput(key: "/works/X", title: "T", authors: ["A"], storedModel: model, storedHash: hash, hasEmbedding: has)
        }
        #expect(with(model: Self.model, hash: hash, has: false).isStale(modelID: Self.model))
        #expect(with(model: "old", hash: hash, has: true).isStale(modelID: Self.model))
        #expect(with(model: Self.model, hash: "abc", has: true).isStale(modelID: Self.model))
        #expect(!with(model: Self.model, hash: hash, has: true).isStale(modelID: Self.model))
        let note = NoteEmbeddingInput(id: "n", text: "hello", storedModel: Self.model,
                                      storedHash: BookEmbeddingText.hash(text: "hello", modelID: Self.model), hasEmbedding: true)
        #expect(!note.isStale(modelID: Self.model))
        #expect(NoteEmbeddingInput(id: "n", text: "hello!", storedModel: Self.model, storedHash: note.storedHash,
                                   hasEmbedding: true).isStale(modelID: Self.model))
    }
}
