import Foundation

/// The Author page header (books come from `GraphStore.authorBooks`).
struct AuthorDetail: Sendable, Hashable, Identifiable {
    let key: String
    let name: String
    let bio: String?
    let birthDate: String?
    let deathDate: String?
    /// Open Library photo first, then the Wikimedia image.
    let imageURLs: [URL]
    let wikipediaURL: URL?
    let wikidataURL: URL?
    let openLibraryURL: URL?
    let occupations: [String]
    let bornIn: [String]
    let citizenOf: [String]
    let awards: [AwardWin]
    let bookCount: Int

    var id: String { key }

    /// "21 October 1929 – 22 January 2018", "b. 1965", or nil.
    var lifespan: String? {
        switch (birthDate, deathDate) {
        case let (b?, d?): "\(b) – \(d)"
        case let (b?, nil): "Born \(b)"
        case let (nil, d?): "Died \(d)"
        default: nil
        }
    }

    init(row: Row) throws {
        key = try row.requiredString("key")
        name = row.string("name") ?? key
        bio = row.string("bio").map(AuthorDetail.cleanBio)
        birthDate = row.string("birthDate").flatMap(AuthorDetail.displayDate)
        deathDate = row.string("deathDate").flatMap(AuthorDetail.displayDate)
        imageURLs = [row.imageURL("photoURL"), row.imageURL("imageURL")].compactMap { $0 }
        wikipediaURL = row.url("wikipediaURL")
        wikidataURL = row.url("wikidataURL")
        openLibraryURL = row.url("url")
        occupations = row.strings("occupations")
        bornIn = BookDetail.sortedUnique(row.strings("bornIn"))
        citizenOf = BookDetail.sortedUnique(row.strings("citizenOf"))
        awards = AwardWin.sorted(row.rows("awards"))
        bookCount = row.int("bookCount") ?? 0
    }

    /// Wikidata ISO dates ("1942-02-12") read like the Open Library ones
    /// ("12 February 1942"); free text passes through; text with no digit
    /// (stray punctuation in the data) is dropped.
    static func displayDate(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.contains(where: \.isNumber) else { return nil }
        let parts = s.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, let y = Int(parts[0]),
              let m = Int(parts[1]), let d = Int(parts[2].prefix(2)), (1...12).contains(m) else { return s }
        let months = ["January", "February", "March", "April", "May", "June", "July",
                      "August", "September", "October", "November", "December"]
        return d >= 1 ? "\(d) \(months[m - 1]) \(y)" : "\(months[m - 1]) \(y)"
    }

    /// Open Library bios end with "Source: [Wikipedia](…)" and use CRLF.
    static func cleanBio(_ s: String) -> String {
        // Drop CRs by scalar: in Swift "\r\n" is one Character, so a
        // Character-level replace of "\r" would not match it.
        var text = String(String.UnicodeScalarView(s.unicodeScalars.filter { $0 != "\r" }))
        if let r = text.range(of: "\nSource: [", options: .backwards) {
            text = String(text[..<r.lowerBound])
        } else if let r = text.range(of: "([Source]", options: .backwards) {
            text = String(text[..<r.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// An author in a list (term pages: born in a place, citizens of a country, award winners).
struct AuthorSummary: Sendable, Hashable, Identifiable {
    let key: String
    let name: String
    let bookCount: Int
    var id: String { key }

    init(row: Row) throws {
        key = try row.requiredString("key")
        name = row.string("name") ?? key
        bookCount = row.int("bookCount") ?? 0
    }
}
