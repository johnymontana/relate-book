import Foundation

/// An author as linked from a book.
struct AuthorRef: Sendable, Hashable, Identifiable {
    let key: String
    let name: String
    let role: String?
    var id: String { key }
}

extension AuthorRef {
    /// Decodes `{key, name, role, richness}` maps into one ref per author
    /// name, sorted by name. The store has separate Author nodes with the
    /// same name on one book (three "David Allen"s, two of them bare); the
    /// node with the most data (image 4, bio 2, birth date 1; ties by key)
    /// stands for the name, so the link opens a page with content.
    static func deduplicated(_ rows: [Row]) -> [AuthorRef] {
        var best: [String: (ref: AuthorRef, richness: Int)] = [:]
        for r in rows {
            guard let key = r.string("key") else { continue }
            let ref = AuthorRef(key: key, name: r.string("name") ?? key, role: r.string("role"))
            let richness = r.int("richness") ?? 0
            let name = BookTitles.fold(ref.name)
            if let current = best[name],
               current.richness > richness || (current.richness == richness && current.ref.key < key) {
                continue
            }
            best[name] = (ref, richness)
        }
        return best.values.map(\.ref).sorted { a, b in
            let order = a.name.localizedCaseInsensitiveCompare(b.name)
            return order == .orderedSame ? a.key < b.key : order == .orderedAscending
        }
    }
}

/// One wishlist item (an Amazon edition) of a book.
struct EditionItem: Sendable, Hashable, Identifiable {
    let asin: String
    let title: String?
    let byline: String?
    let format: String?
    let price: Double?
    let currency: String?
    let priceText: String?
    let amazonRating: Double?
    let amazonReviewCount: Int?
    let url: URL?
    let imageURL: URL?
    let thumbnailURL: URL?
    let isbn13: String?
    let isbn10: String?
    let wishlistPosition: Int?
    let priority: String?
    var id: String { asin }

    var displayPrice: String? { PriceFormat.string(price: price, currency: currency, text: priceText) }

    init(row: Row) throws {
        asin = try row.requiredString("asin")
        title = row.string("title")
        byline = row.string("byline")
        format = row.string("format")
        price = row.double("price")
        currency = row.string("currency")
        priceText = row.string("priceText")
        amazonRating = row.double("amazonRating")
        amazonReviewCount = row.int("amazonReviewCount")
        url = row.url("url")
        imageURL = row.imageURL("imageURL")
        thumbnailURL = row.imageURL("thumbnailURL")
        isbn13 = row.string("isbn13")
        isbn10 = row.string("isbn10")
        wishlistPosition = row.int("position")
        priority = row.string("priority")
    }
}

struct SeriesMembership: Sendable, Hashable, Identifiable {
    let name: String
    /// As stored ("4"); may be nil.
    let position: String?
    var id: String { name }
}

struct AwardWin: Sendable, Hashable, Identifiable {
    let name: String
    let year: Int?
    var id: String { "\(name)|\(year.map(String.init) ?? "")" }
}

/// Everything the Book detail screen shows, from one statement.
struct BookDetail: Sendable, Hashable, Identifiable {
    let key: String
    let title: String
    let url: URL?
    let coverURL: URL?
    let description: String?
    let firstPublishYear: Int?
    let pagesMedian: Int?
    let editionCount: Int?
    let languages: [String]
    let olRating: Double?
    let olRatingCount: Int?
    let olWantToRead: Int?
    let olAlreadyRead: Int?
    let olCurrentlyReading: Int?
    let olReadingLogCount: Int?
    /// Equals `userData.status`.
    let status: ReadingStatus
    /// Status, rating, dates, tags and notes (same row).
    let userData: BookUserData
    let authors: [AuthorRef]
    let subjects: [String]
    let places: [String]
    let people: [String]
    let eras: [String]
    let genres: [String]
    let publishers: [String]
    let series: [SeriesMembership]
    let awards: [AwardWin]
    /// Wishlist items, in wishlist order.
    let items: [EditionItem]
    /// `Book.source`: "openlibrary", "amazon", or "app" (phase 5).
    let source: String?
    /// `Book.added_on` (app-added books).
    let addedOn: Date?
    /// `Book.match` for app-added books: how it was added.
    let importMatch: ImportMatch?
    /// Book.subtitle (Open Library); shown for app books, whose header has
    /// no item title.
    let olSubtitle: String?
    /// Edition facts the ISBN flow wrote on the Book; nil when none.
    let appEdition: AppEdition?

    var id: String { key }
    var isUnresolved: Bool { key.hasPrefix("amazon:") }
    /// Added through the app (phase 5): no Amazon item.
    var isAppAdded: Bool { source == "app" }
    /// Entered by hand (no Open Library record).
    var isManual: Bool { key.hasPrefix("manual:") }
    /// The first wishlist item: source of the Amazon price, rating and link.
    var primaryItem: EditionItem? { items.first }
    var subtitle: String? { BookTitles.subtitle(bookTitle: title, itemTitle: primaryItem?.title) }
    /// `subtitle` (the item-title rule), else `olSubtitle` for app books.
    var displaySubtitle: String? { subtitle ?? (isAppAdded ? olSubtitle : nil) }
    var imageURLs: [URL] {
        [coverURL, primaryItem?.imageURL, primaryItem?.thumbnailURL].compactMap { $0 }
    }

    init(row: Row) throws {
        key = try row.requiredString("key")
        let items = try row.rows("items").map(EditionItem.init(row:))
            .sorted { ($0.wishlistPosition ?? .max, $0.asin) < ($1.wishlistPosition ?? .max, $1.asin) }
        self.items = items
        title = row.string("title") ?? items.first?.title ?? key
        url = row.url("url")
        coverURL = row.imageURL("coverURL")
        description = row.string("description")
        firstPublishYear = row.int("firstPublishYear")
        pagesMedian = row.int("pagesMedian")
        editionCount = row.int("editionCount")
        languages = row.strings("languages")
        olRating = row.double("olRating")
        olRatingCount = row.int("olRatingCount")
        olWantToRead = row.int("olWantToRead")
        olAlreadyRead = row.int("olAlreadyRead")
        olCurrentlyReading = row.int("olCurrentlyReading")
        olReadingLogCount = row.int("olReadingLogCount")
        status = ReadingStatus(graphValue: row.string("status"))
        userData = try BookUserData(row: row)
        authors = AuthorRef.deduplicated(row.rows("authors"))
        subjects = BookDetail.sortedUnique(row.strings("subjects"))
        places = BookDetail.sortedUnique(row.strings("places"))
        people = BookDetail.sortedUnique(row.strings("people"))
        eras = BookDetail.sortedUnique(row.strings("eras"))
        genres = BookDetail.sortedUnique(row.strings("genres"))
        publishers = BookDetail.sortedUnique(row.strings("publishers"))
        series = row.rows("series").compactMap { r in
            r.string("name").map { SeriesMembership(name: $0, position: r.text("position")) }
        }.sorted { $0.name < $1.name }
        awards = AwardWin.sorted(row.rows("awards"))
        source = row.string("source")
        addedOn = row.instant("addedOn")
        importMatch = row.string("importMatch").flatMap(ImportMatch.init(rawValue:))
        olSubtitle = row.string("subtitle")
        appEdition = AppEdition(row: row)
    }

    static func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

extension AwardWin {
    /// Decodes `{name, year}` maps; newest year first, undated last, then by name.
    static func sorted(_ rows: [Row]) -> [AwardWin] {
        Array(Set(rows.compactMap { r in r.string("name").map { AwardWin(name: $0, year: r.int("year")) } }))
            .sorted { a, b in
                if a.year != b.year { return (a.year ?? Int.min) > (b.year ?? Int.min) }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }
}

/// Edition facts an ISBN import writes on the Book (phase 5; an app-added
/// book has no Item to carry them).
struct AppEdition: Sendable, Hashable {
    let isbn13: String?
    let isbn10: String?
    let publisher: String?
    let publishDate: String?
    let publishYear: Int?
    let pages: Int?
    let physicalFormat: String?

    init(isbn13: String? = nil, isbn10: String? = nil, publisher: String? = nil, publishDate: String? = nil,
         publishYear: Int? = nil, pages: Int? = nil, physicalFormat: String? = nil) {
        self.isbn13 = isbn13
        self.isbn10 = isbn10
        self.publisher = publisher
        self.publishDate = publishDate
        self.publishYear = publishYear
        self.pages = pages
        self.physicalFormat = physicalFormat
    }

    /// nil when the row carries none of the columns.
    init?(row: Row) {
        self.init(isbn13: row.string("isbn13"), isbn10: row.string("isbn10"), publisher: row.string("publisherName"),
                  publishDate: row.text("publishDate"), publishYear: row.int("publishYear"), pages: row.int("pages"),
                  physicalFormat: row.string("physicalFormat"))
        if self == AppEdition() { return nil }
    }
}

/// The "Added in app" text on Book detail (D33).
enum AddedInAppText {
    /// "Added Nov 8, 2026 · ISBN scan" (en_US, in `timeZone`); without a
    /// date "Added in app · …".
    static func line(addedOn: Date?, match: ImportMatch?, timeZone: TimeZone = .current) -> String {
        var head = "Added in app"
        if let addedOn {
            var style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Locale(identifier: "en_US"),
                                         calendar: Calendar(identifier: .gregorian), timeZone: timeZone)
            style.timeZone = timeZone
            head = "Added " + addedOn.formatted(style)
        }
        guard let match else { return head }
        return head + " · " + via(match)
    }

    /// "ISBN scan" | "Open Library search" | "entered manually".
    static func via(_ match: ImportMatch) -> String {
        switch match {
        case .isbn: "ISBN scan"
        case .search: "Open Library search"
        case .manual: "entered manually"
        }
    }

    /// ["ISBN 9780393337013", "W.W. Norton & Company · 2009", "233 pages",
    /// "Paperback"]: the present ones only.
    static func details(_ edition: AppEdition?) -> [String] {
        guard let edition else { return [] }
        var lines: [String] = []
        if let isbn = edition.isbn13 ?? edition.isbn10 { lines.append("ISBN \(isbn)") }
        let year = edition.publishYear.map(String.init) ?? edition.publishDate
        switch (edition.publisher, year) {
        case let (publisher?, year?): lines.append("\(publisher) · \(year)")
        case let (publisher?, nil): lines.append(publisher)
        case let (nil, year?): lines.append("Published \(year)")
        default: break
        }
        if let pages = edition.pages { lines.append(pages == 1 ? "1 page" : "\(pages) pages") }
        if let format = edition.physicalFormat { lines.append(format) }
        return lines
    }
}
