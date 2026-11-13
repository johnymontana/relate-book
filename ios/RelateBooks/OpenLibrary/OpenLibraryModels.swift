import Foundation

/// Any JSON value. Every Open Library model decodes from this with lenient
/// accessors, so a missing field or an unexpected type is nil or [] (never
/// a throw, never a crash): Open Library omits absent fields, returns
/// `description` as a string or as `{type, value}`, and `publish_date` as a
/// string or a list depending on the endpoint (spec §0.2).
enum JSONValue: Sendable, Equatable, Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a JSON value")
        }
    }

    /// Parses any JSON document (an object, an array or a fragment).
    /// Throws `OpenLibraryError.invalidResponse` for anything that is not JSON.
    static func parse(_ data: Data) throws -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw OpenLibraryError.invalidResponse("not JSON")
        }
    }

    /// `.null` unless this is an object with that key.
    subscript(key: String) -> JSONValue {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    /// A string, as is; anything else is nil.
    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// A string with something other than whitespace in it, as is (Python's
    /// `value or None` for the extension's scalar fields).
    var nonEmptyString: String? {
        guard let s = string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    /// A number with no fraction, or a numeric string.
    var int: Int? {
        switch self {
        case .number(let n) where n.isFinite && n.rounded() == n && abs(n) < 9.0e15: return Int(n)
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// A number, or a numeric string.
    var double: Double? {
        switch self {
        case .number(let n) where n.isFinite: return n
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// The elements of an array; [] for anything else.
    var array: [JSONValue] {
        if case .array(let a) = self { return a }
        return []
    }

    /// An array's strings (non-strings dropped); a lone string is `[it]`.
    var strings: [String] {
        switch self {
        case .array(let a): return a.compactMap(\.string)
        case .string(let s): return [s]
        default: return []
        }
    }

    /// An array's integers (non-integers dropped).
    var ints: [Int] {
        array.compactMap { value in
            if case .number = value { return value.int }
            return nil
        }
    }

    /// The extension's `ol_text`: a string, or an object's "value" string;
    /// trimmed; empty → nil.
    var text: String? {
        let raw: String?
        switch self {
        case .string(let s): raw = s
        case .object: raw = self["value"].string
        default: raw = nil
        }
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// `search.json`'s envelope. Docs that are not works are already dropped.
struct OLSearchResponse: Sendable, Equatable {
    let numFound: Int
    let docs: [OLSearchDoc]

    init(json: JSONValue) {
        let docs = json["docs"].array.compactMap(OLSearchDoc.init(json:))
        self.docs = docs
        numFound = json["numFound"].int ?? json["num_found"].int ?? docs.count
    }
}

/// One search doc (a work). `init?` returns nil unless `key` matches
/// `^/works/OL[0-9]+W$` and `title` is non-empty (D22: the live result list
/// for "the perfect storm" held "/works/OL8151445M", an edition key).
struct OLSearchDoc: Sendable, Hashable, Identifiable {
    let key: String
    let title: String
    let subtitle: String?
    /// "/authors/" + each `author_key` (search results carry bare ids).
    let authorKeys: [String]
    let authorNames: [String]
    let firstPublishYear: Int?
    /// `cover_i` when positive.
    let coverID: Int?
    let subjects: [String]
    let places: [String]
    let people: [String]
    let times: [String]
    let ratingsAverage: Double?
    let ratingsCount: Int?
    let readinglogCount: Int?
    let wantToReadCount: Int?
    let currentlyReadingCount: Int?
    let alreadyReadCount: Int?
    let pagesMedian: Int?
    let editionCount: Int?
    /// The first element when `first_sentence` is a list, or the string.
    let firstSentence: String?
    let languages: [String]
    let goodreadsIDs: [String]
    let amazonIDs: [String]
    /// `editions.docs`. With an `isbn:` query Open Library filters this to
    /// the matching edition.
    let editions: [OLEditionDoc]

    var id: String { key }

    static func isWorkKey(_ key: String) -> Bool {
        key.wholeMatch(of: /\/works\/OL[0-9]+W/) != nil
    }

    init?(json: JSONValue) {
        guard let key = json["key"].string, Self.isWorkKey(key),
              let title = json["title"].nonEmptyString else { return nil }
        self.key = key
        self.title = title
        subtitle = json["subtitle"].nonEmptyString
        authorKeys = json["author_key"].strings
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("/authors/") ? $0 : "/authors/" + $0 }
        authorNames = json["author_name"].strings
        firstPublishYear = json["first_publish_year"].int
        coverID = json["cover_i"].int.flatMap { $0 > 0 ? $0 : nil }
        subjects = json["subject"].strings
        places = json["place"].strings
        people = json["person"].strings
        times = json["time"].strings
        ratingsAverage = json["ratings_average"].double
        ratingsCount = json["ratings_count"].int
        readinglogCount = json["readinglog_count"].int
        wantToReadCount = json["want_to_read_count"].int
        currentlyReadingCount = json["currently_reading_count"].int
        alreadyReadCount = json["already_read_count"].int
        pagesMedian = json["number_of_pages_median"].int
        editionCount = json["edition_count"].int
        switch json["first_sentence"] {
        case .array(let a): firstSentence = a.first?.nonEmptyString
        case let other: firstSentence = other.nonEmptyString
        }
        languages = json["language"].strings
        goodreadsIDs = json["id_goodreads"].strings
        amazonIDs = json["id_amazon"].strings
        editions = json["editions"]["docs"].array.map(OLEditionDoc.init(json:))
    }

    /// `covers.openlibrary.org/b/id/<id>-M.jpg` (result rows); nil without a cover.
    var coverURL: URL? {
        coverID.flatMap { URL(string: "https://covers.openlibrary.org/b/id/\($0)-M.jpg") }
    }

    /// "Sebastian Junger, Anne Collins" (exact repeats dropped), or "Unknown author".
    var authorLine: String {
        var seen: Set<String> = []
        let names = authorNames.filter { !$0.isEmpty && seen.insert($0).inserted }
        return names.isEmpty ? "Unknown author" : names.joined(separator: ", ")
    }
}

/// One `editions.docs` entry of a search doc.
struct OLEditionDoc: Sendable, Hashable {
    let key: String?
    let title: String?
    let isbns: [String]
    let publishers: [String]
    /// `publish_date` is a list in search results.
    let publishDates: [String]
    let numberOfPages: Int?
    let physicalFormat: String?
    let languages: [String]

    init(json: JSONValue) {
        key = json["key"].nonEmptyString
        title = json["title"].nonEmptyString
        isbns = json["isbn"].strings
        publishers = json["publisher"].strings
        publishDates = json["publish_date"].strings
        numberOfPages = json["number_of_pages"].int
        physicalFormat = json["physical_format"].nonEmptyString
        languages = json["language"].strings
    }
}

/// A work or author link with a URL.
struct OLLink: Sendable, Hashable {
    let title: String?
    let url: String

    /// Entries with a non-empty `url`; others are dropped.
    static func list(_ json: JSONValue) -> [OLLink] {
        json.array.compactMap { link in
            guard let url = link["url"].nonEmptyString else { return nil }
            return OLLink(title: link["title"].string, url: url)
        }
    }
}

/// `GET /works/OL…W.json`.
struct OLWork: Sendable, Hashable {
    let key: String?
    let title: String?
    /// `ol_text(description)`: a string here, `{type, value}` elsewhere.
    let description: String?
    /// As given (can contain -1); the importer uses the first positive one.
    let covers: [Int]
    /// `authors[].author.key`.
    let authorKeys: [String]
    let subjects: [String]
    let subjectPlaces: [String]
    let subjectPeople: [String]
    let subjectTimes: [String]
    let genres: [String]
    let links: [OLLink]
    /// `identifiers.wikidata`.
    let wikidataIDs: [String]

    init(json: JSONValue) {
        key = json["key"].nonEmptyString
        title = json["title"].nonEmptyString
        description = json["description"].text
        covers = json["covers"].ints
        authorKeys = json["authors"].array.compactMap { $0["author"]["key"].nonEmptyString }
        subjects = json["subjects"].strings
        subjectPlaces = json["subject_places"].strings
        subjectPeople = json["subject_people"].strings
        subjectTimes = json["subject_times"].strings
        genres = json["genres"].strings
        links = OLLink.list(json["links"])
        wikidataIDs = json["identifiers"]["wikidata"].strings
    }
}

/// `GET /authors/OL…A.json`. Sparse records (name only) decode fine.
struct OLAuthor: Sendable, Hashable {
    let key: String?
    let name: String?
    let personalName: String?
    /// `ol_text(bio)`.
    let bio: String?
    let birthDate: String?
    let deathDate: String?
    let alternateNames: [String]
    /// Positive photo ids only.
    let photoIDs: [Int]
    /// String values only (viaf, wikidata, isni, goodreads, amazon, …).
    let remoteIDs: [String: String]
    let links: [OLLink]

    init(json: JSONValue) {
        key = json["key"].nonEmptyString
        name = json["name"].nonEmptyString
        personalName = json["personal_name"].nonEmptyString
        bio = json["bio"].text
        birthDate = json["birth_date"].nonEmptyString
        deathDate = json["death_date"].nonEmptyString
        alternateNames = json["alternate_names"].strings
        photoIDs = json["photos"].ints.filter { $0 > 0 }
        if case .object(let ids) = json["remote_ids"] {
            remoteIDs = ids.compactMapValues(\.nonEmptyString)
        } else {
            remoteIDs = [:]
        }
        links = OLLink.list(json["links"])
    }
}

/// The edition record behind `/isbn/<isbn>.json` (the D5 fallback; the 302
/// to `/books/OL…M.json` is followed by the transport).
struct OLEdition: Sendable, Hashable {
    let key: String?
    let title: String?
    let subtitle: String?
    /// `works[].key`.
    let workKeys: [String]
    let numberOfPages: Int?
    let physicalFormat: String?
    let publishers: [String]
    /// A string here (a list in search editions; the first is taken then).
    let publishDate: String?
    let isbn13: [String]
    let isbn10: [String]

    init(json: JSONValue) {
        key = json["key"].nonEmptyString
        title = json["title"].nonEmptyString
        subtitle = json["subtitle"].nonEmptyString
        workKeys = json["works"].array.compactMap { $0["key"].nonEmptyString }
        numberOfPages = json["number_of_pages"].int
        physicalFormat = json["physical_format"].nonEmptyString
        publishers = json["publishers"].strings
        publishDate = json["publish_date"].strings.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        isbn13 = json["isbn_13"].strings
        isbn10 = json["isbn_10"].strings
    }
}
