import CryptoKit
import Foundation
import Relate

/// How a book entered the library (`Book.match`).
enum ImportMatch: String, Sendable, CaseIterable {
    case isbn, search, manual
}

/// One author to MERGE. `properties` are written only when the node is
/// created (D6); for an author already in the store they are empty.
struct ImportAuthor: Sendable, Equatable {
    /// "/authors/OL…A" or "name:<slug>".
    let key: String
    /// For display and logging.
    let name: String
    /// "openlibrary" | "app".
    let source: String
    let properties: [String: CypherValue]
}

/// The five term lists (the extension's subjects/places/people/times/genres).
struct ImportTerms: Sendable, Equatable {
    var subjects: [String] = []
    var places: [String] = []
    var people: [String] = []
    var eras: [String] = []
    var genres: [String] = []
}

/// Everything the save transaction writes for one book, computed with no
/// I/O so tests can compare it with the expected table (spec A.20.4).
struct ImportDraft: Sendable, Equatable {
    let key: String
    let match: ImportMatch
    let title: String
    /// Book properties for `SET b += $props`. Never contains key, source,
    /// match or added_on; nil, [] and "" values are dropped (`drop_none`).
    let properties: [String: CypherValue]
    let authors: [ImportAuthor]
    let terms: ImportTerms

    static let maxAuthors = 8
    static let openLibrary = "https://openlibrary.org"

    /// The extension's `enrich_from_open_library` (spec §0.5).
    ///
    /// - `authors`: fetched records by key (a missing one falls back to the
    ///   doc's `author_name`, D7).
    /// - `knownAuthorKeys`: keys already in the store (D6), emitted with
    ///   empty properties.
    /// - `isbn` / `edition`: used only for `.isbn`. With an `OLEdition`
    ///   (the `/isbn/` fallback) the edition facts come from it; otherwise
    ///   from the editions sub-doc whose isbns contain the ISBN, else the
    ///   first one. `.search` writes no edition facts (D8).
    static func fromOpenLibrary(doc: OLSearchDoc, work: OLWork?, authors: [String: OLAuthor],
                                knownAuthorKeys: Set<String>, isbn: ISBN?, edition: OLEdition?,
                                match: ImportMatch) -> ImportDraft {
        var props: [String: CypherValue] = [:]
        func put(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { props[key] = .string(value) }
        }
        func put(_ key: String, _ value: Int?) {
            if let value { props[key] = .int(Int64(value)) }
        }
        func put(_ key: String, _ value: [String]) {
            if !value.isEmpty { props[key] = .list(value.map(CypherValue.string)) }
        }

        put("title", doc.title)
        put("subtitle", doc.subtitle)
        put("description", work?.description)
        put("first_sentence", doc.firstSentence)
        put("first_publish_year", doc.firstPublishYear)
        let coverID = doc.coverID ?? work?.covers.first { $0 > 0 }
        put("cover_url", coverID.map { "https://covers.openlibrary.org/b/id/\($0)-L.jpg" })
        if let rating = doc.ratingsAverage { props["ol_rating"] = .float(rating) }
        put("ol_rating_count", doc.ratingsCount)
        put("ol_want_to_read", doc.wantToReadCount)
        put("ol_currently_reading", doc.currentlyReadingCount)
        put("ol_already_read", doc.alreadyReadCount)
        put("ol_readinglog_count", doc.readinglogCount)
        put("pages_median", doc.pagesMedian)
        put("edition_count", doc.editionCount)
        put("languages", doc.languages)
        put("goodreads_ids", doc.goodreadsIDs)
        put("amazon_asins", doc.amazonIDs)
        put("wikidata", work?.wikidataIDs.first)
        let links = work?.links ?? []
        put("link_urls", links.map(\.url))
        put("link_titles", links.map { $0.title ?? "" })
        put("url", openLibrary + doc.key)

        if match == .isbn, let isbn {
            let facts = EditionFacts(doc: doc, isbn: isbn, edition: edition)
            put("isbn13", isbn.isbn13)
            put("isbn10", isbn.isbn10 ?? facts.isbns.first { $0.count == 10 && ISBN.isValid10($0) })
            put("ol_edition_key", facts.key)
            put("publisher", facts.publisher)
            put("publish_date", facts.publishDate)
            put("publish_year", ImportText.publishYear(facts.publishDate))
            put("pages", facts.pages)
            put("physical_format", ImportText.normalizeFormat(facts.physicalFormat))
        }

        var authorKeys: [String] = []
        for key in (work?.authorKeys.isEmpty == false ? work!.authorKeys : doc.authorKeys) where !authorKeys.contains(key) {
            authorKeys.append(key)
        }
        let importAuthors = authorKeys.prefix(maxAuthors).map { key in
            author(key: key, doc: doc, record: authors[key], known: knownAuthorKeys.contains(key))
        }

        let terms = ImportTerms(
            subjects: Array(ImportText.dedupe(doc.subjects.isEmpty ? work?.subjects ?? [] : doc.subjects).prefix(60)),
            places: Array(ImportText.dedupe(doc.places.isEmpty ? work?.subjectPlaces ?? [] : doc.places).prefix(40)),
            people: Array(ImportText.dedupe(doc.people.isEmpty ? work?.subjectPeople ?? [] : doc.people).prefix(40)),
            eras: Array(ImportText.dedupe(doc.times.isEmpty ? work?.subjectTimes ?? [] : doc.times).prefix(20)),
            genres: Array(ImportText.dedupe(work?.genres ?? []).filter { !$0.hasPrefix("/") }.prefix(20)))

        return ImportDraft(key: doc.key, match: match, title: doc.title, properties: props,
                           authors: Array(importAuthors), terms: terms)
    }

    /// One Open Library author: the record's facts, or none for a known key.
    private static func author(key: String, doc: OLSearchDoc, record: OLAuthor?, known: Bool) -> ImportAuthor {
        let fallbackName: String = {
            if let index = doc.authorKeys.firstIndex(of: key), index < doc.authorNames.count,
               !doc.authorNames[index].isEmpty {
                return doc.authorNames[index]
            }
            return doc.authorNames.first { !$0.isEmpty } ?? key
        }()
        let name = record?.name ?? fallbackName
        guard !known else { return ImportAuthor(key: key, name: name, source: "openlibrary", properties: [:]) }
        var props: [String: CypherValue] = [:]
        func put(_ k: String, _ v: String?) {
            if let v, !v.isEmpty { props[k] = .string(v) }
        }
        put("name", name)
        put("personal_name", record?.personalName)
        put("bio", record?.bio)
        put("birth_date", record?.birthDate)
        put("death_date", record?.deathDate)
        if let names = record?.alternateNames, !names.isEmpty { props["alternate_names"] = .list(names.map(CypherValue.string)) }
        put("photo_url", record?.photoIDs.first.map { "https://covers.openlibrary.org/a/id/\($0)-L.jpg" })
        let remote = record?.remoteIDs ?? [:]
        put("wikidata", remote["wikidata"])
        put("viaf", remote["viaf"])
        put("isni", remote["isni"])
        put("goodreads_id", remote["goodreads"])
        put("amazon_author_id", remote["amazon"])
        put("wikipedia_url", record?.links.first { $0.url.contains("wikipedia.org") }?.url)
        put("url", openLibrary + key)
        return ImportAuthor(key: key, name: name, source: "openlibrary", properties: props)
    }

    /// Manual entry (D18): no lookup, no enrichment. Throws
    /// `ImportError.emptyTitle` when the trimmed title is empty.
    static func manual(title: String, authors: String, uuid: UUID) throws -> ImportDraft {
        let cleanTitle = String(ImportText.clean(title).prefix(ImportText.maxTitleLength))
        guard !cleanTitle.isEmpty else { throw ImportError.emptyTitle }
        var seenKeys: Set<String> = []
        let importAuthors: [ImportAuthor] = ImportText.manualAuthors(authors).compactMap { name in
            let key = ImportText.bylineKey(name)
            guard seenKeys.insert(key).inserted else { return nil }
            return ImportAuthor(key: key, name: name, source: "app", properties: ["name": .string(name)])
        }
        return ImportDraft(key: "manual:" + uuid.uuidString.lowercased(), match: .manual, title: cleanTitle,
                           properties: ["title": .string(cleanTitle)], authors: importAuthors, terms: ImportTerms())
    }
}

/// The edition facts of an ISBN import, from the `/isbn/` record when the
/// fallback found one, else from the matching search editions sub-doc.
private struct EditionFacts {
    let key: String?
    let isbns: [String]
    let publisher: String?
    let publishDate: String?
    let pages: Int?
    let physicalFormat: String?

    init(doc: OLSearchDoc, isbn: ISBN, edition: OLEdition?) {
        if let edition {
            key = edition.key
            isbns = edition.isbn10 + edition.isbn13
            publisher = edition.publishers.first
            publishDate = edition.publishDate
            pages = edition.numberOfPages
            physicalFormat = edition.physicalFormat
            return
        }
        let candidates = [isbn.isbn13] + [isbn.isbn10].compactMap { $0 }
        let sub = doc.editions.first { e in candidates.contains { e.isbns.contains($0) } } ?? doc.editions.first
        key = sub?.key
        isbns = sub?.isbns ?? []
        publisher = sub?.publishers.first
        publishDate = sub?.publishDates.first
        pages = sub?.numberOfPages
        physicalFormat = sub?.physicalFormat
    }
}

/// Ports of the extension's small text rules.
enum ImportText {
    static let maxTitleLength = 300
    static let maxAuthorLength = 200

    /// `dedupe`: collapse whitespace, strip, strip ".", keep the first
    /// spelling per lowercase value. Note: "foo ." becomes "foo " (the
    /// trailing space stays, exactly like Python's `.strip().strip(".")`).
    static func dedupe(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for value in values {
            let collapsed = value.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = String(collapsed.trimmingPrefix(while: { $0 == "." }).reversed().drop(while: { $0 == "." }).reversed())
            guard !cleaned.isEmpty, seen.insert(cleaned.lowercased()).inserted else { continue }
            out.append(cleaned)
        }
        return out
    }

    /// `"name:" + re.sub("[^a-z0-9]+", "-", name.lower()).strip("-")`, the
    /// extension's byline-author key; an empty slug (e.g. 村上春樹) gives
    /// `name:h-<first 12 hex of SHA-256(lowercased NFC name)>` (D18).
    static func bylineKey(_ name: String) -> String {
        var slug = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if pendingDash && !slug.isEmpty { slug.append("-") }
                pendingDash = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        if !slug.isEmpty { return "name:" + slug }
        let digest = SHA256.hash(data: Data(name.precomposedStringWithCanonicalMapping.lowercased().utf8))
        return "name:h-" + digest.map { String(format: "%02x", $0) }.joined().prefix(12)
    }

    /// The first `\b(1[5-9]\d\d|20\d\d)\b` in the date text (Python's simple
    /// word boundaries, so "c1997" has no year).
    static func publishYear(_ date: String?) -> Int? {
        guard let date else { return nil }
        let regex = /\b(1[5-9]\d\d|20\d\d)\b/.wordBoundaryKind(.simple)
        guard let match = date.firstMatch(of: regex) else { return nil }
        return Int(match.output.1)
    }

    /// D19: trimmed; an all-lowercase value gets each space-separated word
    /// capitalised ("mass market paperback" → "Mass Market Paperback");
    /// anything else is kept; empty → nil.
    static func normalizeFormat(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        guard trimmed == trimmed.lowercased() else { return trimmed }
        return trimmed.split(separator: " ", omittingEmptySubsequences: false)
            .map { word in word.prefix(1).uppercased() + word.dropFirst() }
            .joined(separator: " ")
    }

    /// D18: split on `,` `;` and newlines, trim, drop empties, dedupe
    /// case-insensitively, at most 8 names of at most 200 characters.
    static func manualAuthors(_ text: String) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline }) {
            let name = String(clean(String(part)).prefix(maxAuthorLength))
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            out.append(name)
            if out.count == ImportDraft.maxAuthors { break }
        }
        return out
    }

    /// NFC, whitespace collapsed, trimmed.
    static func clean(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
