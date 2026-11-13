import Testing
import Foundation
@testable import RelateBooksCore

@Suite("Open Library models")
struct OpenLibraryModelsTests {
    static func response(_ name: String) throws -> OLSearchResponse {
        OLSearchResponse(json: try FixtureFiles.openLibraryJSON(name))
    }

    @Test("ISBN search doc: keys, first sentence, the filtered editions sub-doc")
    func isbnSearch() throws {
        let r = try Self.response("search-isbn13.json")
        #expect(r.numFound == 1 && r.docs.count == 1)
        let doc = try #require(r.docs.first)
        #expect(doc.key == "/works/OL2670211W" && doc.title == "The Perfect Storm")
        #expect(doc.authorKeys == ["/authors/OL389527A", "/authors/OL2801780A"])
        #expect(doc.authorNames == ["Sebastian Junger", "Anne Collins"])
        #expect(doc.firstSentence?.hasPrefix("ONE midwinter") == true)
        #expect(doc.ratingsAverage == 4.125 && doc.ratingsCount == 16 && doc.editionCount == 29)
        #expect(doc.coverID == 8231807 && doc.firstPublishYear == 1997 && doc.pagesMedian == 256)
        #expect(doc.subjects.count == 36 && doc.places == ["New England", "North Atlantic Ocean", "Gloucester (Mass.)"])
        let edition = try #require(doc.editions.first)
        #expect(edition.isbns.contains("9780393337013"))
        #expect(edition.publishers == ["W.W. Norton & Company"])
        #expect(edition.publishDates == ["2009"])
        #expect(edition.numberOfPages == nil && edition.physicalFormat == nil)
        #expect(edition.key == "/books/OL24495814M")
        #expect(doc.authorLine == "Sebastian Junger, Anne Collins")
        #expect(try Self.response("search-isbn10.json").docs.first?.key == doc.key)
    }

    @Test("title search: 19 works (an edition key dropped), docs without cover decode")
    func titleSearch() throws {
        let r = try Self.response("search-title.json")
        #expect(r.docs.count == 19)
        #expect(!r.docs.contains { $0.key == "/works/OL8151445M" })
        #expect(r.docs.filter { $0.coverID == nil }.count == 8)
        #expect(r.docs.filter { $0.coverID == nil }.allSatisfy { $0.coverURL == nil })
        #expect(r.docs[0].coverURL?.absoluteString == "https://covers.openlibrary.org/b/id/8231807-M.jpg")
        #expect(r.docs.first { $0.key == "/works/OL708184W" }?.authorLine == "Jeff Smith")
    }

    @Test("work: plain-string description, authors, places, links, covers")
    func work() throws {
        let work = OLWork(json: try FixtureFiles.openLibraryJSON("work-OL2670211W.json"))
        let description = try #require(work.description)
        #expect(description.unicodeScalars.count == 1570)
        #expect(description.hasPrefix("It was the storm of the century"))
        #expect(work.authorKeys == ["/authors/OL389527A", "/authors/OL2801780A"])
        #expect(work.subjectPlaces.count == 3 && work.links.count == 1 && work.covers.count == 4)
        #expect(work.genres.isEmpty && work.wikidataIDs.isEmpty && work.subjectPeople.isEmpty)
        #expect(work.links.first?.title == "New York Times review")
    }

    @Test("authors: a rich record with {type, value} bio, and a name-only record")
    func authors() throws {
        let junger = OLAuthor(json: try FixtureFiles.openLibraryJSON("author-OL389527A.json"))
        #expect(junger.bio?.hasPrefix("Sebastian Junger is") == true)
        #expect(junger.photoIDs == [6389647])
        #expect(junger.remoteIDs["wikidata"] == "Q969298")
        #expect(junger.birthDate == "17 January 1962" && junger.personalName == "Sebastian Junger")
        let collins = OLAuthor(json: try FixtureFiles.openLibraryJSON("author-OL2801780A.json"))
        #expect(collins.name == "Anne Collins")
        #expect(collins.bio == nil && collins.personalName == nil && collins.birthDate == nil && collins.deathDate == nil)
        #expect(collins.photoIDs.isEmpty && collins.remoteIDs.isEmpty && collins.links.isEmpty && collins.alternateNames.isEmpty)
    }

    @Test("edition record behind /isbn/")
    func edition() throws {
        let edition = OLEdition(json: try FixtureFiles.openLibraryJSON("edition-OL24495814M.json"))
        #expect(edition.workKeys == ["/works/OL2670211W"])
        #expect(edition.numberOfPages == 233 && edition.publishDate == "2009")
        #expect(edition.isbn13 == ["9780393337013"] && edition.isbn10 == ["0393337014"])
        #expect(edition.publishers == ["W.W. Norton & Company"] && edition.key == "/books/OL24495814M")
    }

    @Test("not found and Project Hail Mary")
    func otherFixtures() throws {
        #expect(try Self.response("search-notfound.json").docs.isEmpty)
        #expect(try Self.response("search-notfound.json").numFound == 0)
        let phm = try #require(try Self.response("search-isbn-phm.json").docs.first)
        #expect(phm.key == "/works/OL21745884W" && phm.places.count == 10)
    }

    @Test("malformed input never crashes")
    func malformed() throws {
        #expect(OLSearchResponse(json: try JSONValue.parse(Data("[]".utf8))).docs.isEmpty)
        #expect(throws: OpenLibraryError.invalidResponse("not JSON")) { try JSONValue.parse(Data("not json".utf8)) }
        #expect(OLSearchResponse(json: try JSONValue.parse(Data(#"{"docs": "x"}"#.utf8))).docs.isEmpty)
        #expect(OLSearchResponse(json: try JSONValue.parse(Data(#"{"docs": [1, null, {"key": 3}, {"key": "/works/OL1W"}]}"#.utf8))).docs.isEmpty)
        let work = OLWork(json: try JSONValue.parse(Data(#"{"description": 5, "covers": "x", "authors": [{"author": 1}]}"#.utf8)))
        #expect(work.description == nil && work.covers.isEmpty && work.authorKeys.isEmpty)
    }

    @Test("JSONValue accessors: numbers vs numeric strings, ol_text")
    func accessors() throws {
        let json = try JSONValue.parse(Data(#"""
            {"n": 4, "f": 4.125, "s": "12", "fs": "2.5", "b": true, "t": "  hi ", "o": {"type": "/type/text", "value": " v "},
             "e": "", "l": ["a", 1, "b"], "one": "solo", "ints": [1, 2.5, "3", -1]}
            """#.utf8))
        #expect(json["n"].int == 4 && json["n"].double == 4)
        #expect(json["f"].int == nil && json["f"].double == 4.125)
        #expect(json["s"].int == 12 && json["fs"].double == 2.5 && json["fs"].int == nil)
        #expect(json["b"] == .bool(true) && json["b"].int == nil)
        #expect(json["t"].text == "hi" && json["o"].text == "v" && json["e"].text == nil && json["n"].text == nil)
        #expect(json["l"].strings == ["a", "b"] && json["one"].strings == ["solo"])
        #expect(json["ints"].ints == [1, -1])
        #expect(json["missing"] == .null && json["missing"]["deeper"] == .null && json["l"].array.count == 3)
    }
}
