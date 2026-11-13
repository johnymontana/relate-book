import Testing
import Foundation
import Relate
@testable import RelateBooksCore

/// The fixture book's Open Library records, decoded.
enum PerfectStorm {
    static let key = "/works/OL2670211W"
    static let isbn = ISBN("9780393337013")!
    static let junger = "/authors/OL389527A"
    static let collins = "/authors/OL2801780A"

    static func doc(_ name: String = "search-isbn13.json") throws -> OLSearchDoc {
        try #require(OLSearchResponse(json: try FixtureFiles.openLibraryJSON(name)).docs.first)
    }
    static func work() throws -> OLWork { OLWork(json: try FixtureFiles.openLibraryJSON("work-OL2670211W.json")) }
    static func authors() throws -> [String: OLAuthor] {
        [junger: OLAuthor(json: try FixtureFiles.openLibraryJSON("author-OL389527A.json")),
         collins: OLAuthor(json: try FixtureFiles.openLibraryJSON("author-OL2801780A.json"))]
    }
    static func edition() throws -> OLEdition { OLEdition(json: try FixtureFiles.openLibraryJSON("edition-OL24495814M.json")) }

    /// The ISBN-flow draft with both author records (no author known).
    static func draft(match: ImportMatch = .isbn, known: Set<String> = []) throws -> ImportDraft {
        ImportDraft.fromOpenLibrary(doc: try doc(), work: try work(), authors: try authors(), knownAuthorKeys: known,
                                    isbn: isbn, edition: nil, match: match)
    }
}

@Suite("Import draft")
struct ImportDraftTests {
    @Test("the ISBN draft's Book properties are exactly the extension's (typed per D10)")
    func bookProperties() throws {
        let draft = try PerfectStorm.draft()
        let work = try PerfectStorm.work()
        let doc = try PerfectStorm.doc()
        #expect(draft.key == PerfectStorm.key && draft.match == .isbn && draft.title == "The Perfect Storm")
        let expected: [String: CypherValue] = [
            "cover_url": .string("https://covers.openlibrary.org/b/id/8231807-L.jpg"),
            "description": .string(work.description!),
            "edition_count": .int(29),
            "first_publish_year": .int(1997),
            "first_sentence": .string("ONE midwinter day off the coast of Massachusetts, the crew of a mackerel schooner spotted a bottle with a note in it."),
            "goodreads_ids": .list(doc.goodreadsIDs.map(CypherValue.string)),
            "isbn10": .string("0393337014"),
            "isbn13": .string("9780393337013"),
            "languages": .list([.string("eng")]),
            "link_titles": .list([.string("New York Times review")]),
            "link_urls": .list([.string("http://www.nytimes.com/1997/06/22/books/the-tempest.html")]),
            "ol_already_read": .int(19),
            "ol_currently_reading": .int(7),
            "ol_edition_key": .string("/books/OL24495814M"),
            "ol_rating": .float(4.125),
            "ol_rating_count": .int(16),
            "ol_readinglog_count": .int(158),
            "ol_want_to_read": .int(132),
            "pages_median": .int(256),
            "publish_date": .string("2009"),
            "publish_year": .int(2009),
            "publisher": .string("W.W. Norton & Company"),
            "title": .string("The Perfect Storm"),
            "url": .string("https://openlibrary.org/works/OL2670211W"),
        ]
        #expect(Set(draft.properties.keys) == Set(expected.keys))
        for (key, value) in expected {
            #expect(draft.properties[key] == value, "\(key)")
        }
        #expect(doc.goodreadsIDs.count == 22 && doc.goodreadsIDs.first == "1673975")
        #expect(work.description!.hasPrefix("It was the storm of the century"))
        for absent in ["subtitle", "wikidata", "amazon_asins", "pages", "physical_format", "key", "source", "match", "added_on"] {
            #expect(draft.properties[absent] == nil, "\(absent)")
        }
    }

    @Test("authors: OL facts on new authors, none on known ones")
    func authors() throws {
        let draft = try PerfectStorm.draft()
        #expect(draft.authors.map(\.key) == [PerfectStorm.junger, PerfectStorm.collins])
        #expect(draft.authors.allSatisfy { $0.source == "openlibrary" })
        let junger = draft.authors[0].properties
        #expect(Set(junger.keys) == ["name", "personal_name", "bio", "birth_date", "photo_url", "wikidata", "viaf", "isni", "goodreads_id", "url"])
        #expect(junger["birth_date"] == .string("17 January 1962"))
        #expect(junger["photo_url"] == .string("https://covers.openlibrary.org/a/id/6389647-L.jpg"))
        #expect(junger["viaf"] == .string("17368316") && junger["isni"] == .string("000000000692546X"))
        #expect(junger["goodreads_id"] == .string("16494") && junger["wikidata"] == .string("Q969298"))
        #expect(junger["url"] == .string("https://openlibrary.org/authors/OL389527A"))
        #expect(draft.authors[1].properties == ["name": .string("Anne Collins"), "url": .string("https://openlibrary.org/authors/OL2801780A")])

        let known = try PerfectStorm.draft(known: [PerfectStorm.junger])
        #expect(known.authors[0].properties.isEmpty && known.authors[0].name == "Sebastian Junger")
        #expect(!known.authors[1].properties.isEmpty)

        // D7: a missing record falls back to the doc's name at the key's index.
        let missing = ImportDraft.fromOpenLibrary(doc: try PerfectStorm.doc(), work: nil, authors: [:], knownAuthorKeys: [],
                                                  isbn: nil, edition: nil, match: .search)
        #expect(missing.authors.map { $0.properties["name"] } == [.string("Sebastian Junger"), .string("Anne Collins")])
    }

    @Test("terms: dedupe keeps the first spelling, caps after dedupe")
    func terms() throws {
        let terms = try PerfectStorm.draft().terms
        #expect(terms.subjects.count == 36)
        #expect(Array(terms.subjects.prefix(5)) == ["Social life and customs", "Foreign speakers", "Andrea Gail (Boat)",
                                                    "Andrea Gail (Ship)", "Open Library Staff Picks"])
        #expect(terms.subjects.contains("Social life & customs"))
        #expect(terms.places == ["New England", "North Atlantic Ocean", "Gloucester (Mass.)"])
        #expect(terms.people.isEmpty && terms.eras.isEmpty && terms.genres.isEmpty)
    }

    @Test("a search import writes no edition facts (D8)")
    func searchDraft() throws {
        let draft = try PerfectStorm.draft(match: .search)
        #expect(draft.match == .search)
        for key in ["isbn10", "isbn13", "publisher", "publish_date", "publish_year", "pages", "physical_format", "ol_edition_key"] {
            #expect(draft.properties[key] == nil, "\(key)")
        }
        #expect(draft.properties["title"] == .string("The Perfect Storm"))
    }

    @Test("the /isbn/ fallback takes edition facts from the edition record")
    func fallbackDraft() throws {
        let draft = ImportDraft.fromOpenLibrary(doc: try PerfectStorm.doc("search-key.json"), work: try PerfectStorm.work(),
                                                authors: try PerfectStorm.authors(), knownAuthorKeys: [],
                                                isbn: PerfectStorm.isbn, edition: try PerfectStorm.edition(), match: .isbn)
        #expect(draft.properties["pages"] == .int(233))
        #expect(draft.properties["publisher"] == .string("W.W. Norton & Company"))
        #expect(draft.properties["publish_date"] == .string("2009"))
        #expect(draft.properties["ol_edition_key"] == .string("/books/OL24495814M"))
        #expect(draft.properties["isbn13"] == .string("9780393337013"))
        #expect(draft.properties["isbn10"] == .string("0393337014"))
        // Without the record, the unfiltered sub-doc (docs[0], 1997 Norton) is used; its bad "006101351" is ignored.
        let subDoc = ImportDraft.fromOpenLibrary(doc: try PerfectStorm.doc("search-key.json"), work: nil, authors: [:],
                                                 knownAuthorKeys: [], isbn: ISBN("9798999999993")!, edition: nil, match: .isbn)
        #expect(subDoc.properties["isbn10"] == .string("039304016X"))
        #expect(subDoc.properties["ol_edition_key"] == .string("/books/OL1003073M"))
    }

    @Test("dedupe matches the extension")
    func dedupe() {
        #expect(ImportText.dedupe(["  U.S. ", "u.s", "Gloucester (Mass.)", "foo .", "Foo", "a  b", "", "...", "Fiction."])
                == ["U.S", "Gloucester (Mass.)", "foo ", "Foo", "a b", "Fiction"])
    }

    @Test("byline keys match the extension's slug rule")
    func bylineKeys() {
        #expect(ImportText.bylineKey("Rana Foroohar") == "name:rana-foroohar")
        #expect(ImportText.bylineKey("Morten Bøås") == "name:morten-b-s")
        #expect(ImportText.bylineKey("J. R. R. Tolkien") == "name:j-r-r-tolkien")
        #expect(ImportText.bylineKey("  Ursula K. Le Guin ") == "name:ursula-k-le-guin")
        let kanji = ImportText.bylineKey("村上春樹")
        #expect(kanji.hasPrefix("name:h-") && kanji.count == "name:h-".count + 12)
        #expect(kanji.dropFirst(7).allSatisfy { $0.isHexDigit } && ImportText.bylineKey("村上春樹") == kanji)
    }

    @Test("publish year, format and manual authors")
    func textRules() {
        #expect(ImportText.publishYear("May 04, 2021") == 2021)
        #expect(ImportText.publishYear("c1997") == nil)
        #expect(ImportText.publishYear("1450?") == nil)
        #expect(ImportText.publishYear("2009") == 2009 && ImportText.publishYear(nil) == nil)
        #expect(ImportText.normalizeFormat("paperback") == "Paperback")
        #expect(ImportText.normalizeFormat("mass market paperback") == "Mass Market Paperback")
        #expect(ImportText.normalizeFormat("E-book") == "E-book")
        #expect(ImportText.normalizeFormat("  ") == nil && ImportText.normalizeFormat(nil) == nil)
        #expect(ImportText.manualAuthors("Jane Doe, Rana Foroohar; jane doe\n\n") == ["Jane Doe", "Rana Foroohar"])
        #expect(ImportText.manualAuthors((1...10).map { "A\($0)" }.joined(separator: ",")).count == 8)
        #expect(ImportText.manualAuthors(String(repeating: "x", count: 250)).first?.count == 200)
    }

    @Test("manual draft: manual:<uuid>, title only, byline authors with source app")
    func manualDraft() throws {
        let uuid = UUID(uuidString: "3F2A9C1E-8B7D-4E21-9A55-0C6D2B1F7E90")!
        let draft = try ImportDraft.manual(title: "  Field Notes from the  Bitterroot ", authors: "Jane Doe, Rana Foroohar", uuid: uuid)
        #expect(draft.key == "manual:3f2a9c1e-8b7d-4e21-9a55-0c6d2b1f7e90")
        #expect(draft.match == .manual && draft.title == "Field Notes from the Bitterroot")
        #expect(draft.properties == ["title": .string("Field Notes from the Bitterroot")])
        #expect(draft.authors.map(\.key) == ["name:jane-doe", "name:rana-foroohar"])
        #expect(draft.authors.allSatisfy { $0.source == "app" })
        #expect(draft.authors[0].properties == ["name": .string("Jane Doe")])
        #expect(draft.terms == ImportTerms())
        #expect(throws: ImportError.emptyTitle) { try ImportDraft.manual(title: "   ", authors: "", uuid: uuid) }
        #expect(try ImportDraft.manual(title: String(repeating: "t", count: 400), authors: "", uuid: uuid).title.count == 300)
    }
}
