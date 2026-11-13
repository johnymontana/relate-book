import Foundation
import Relate

/// One row of a book list: scalar columns only (no nodes). Produced by
/// `LibraryQueries.summaryProjection()`, shared by the library, author and
/// term lists.
struct BookSummary: Sendable, Hashable, Identifiable {
    let key: String
    let title: String
    /// Title of the book's first wishlist item (English Amazon title).
    let itemTitle: String?
    let authors: [String]
    let format: String?
    let coverURL: URL?
    let thumbnailURL: URL?
    let status: ReadingStatus
    /// `Book.my_rating`, 1...5.
    let myRating: Int?
    let price: Double?
    let currency: String?
    let priceText: String?
    let wishlistPosition: Int?
    let itemCount: Int
    let olRating: Double?
    let firstPublishYear: Int?
    /// `Book.source`: "openlibrary", "amazon", or "app" (added in the app, phase 5).
    let source: String?
    /// `Book.added_on` (app-added books).
    let addedOn: Date?

    var id: String { key }

    init(key: String, title: String, itemTitle: String? = nil, authors: [String] = [],
         format: String? = nil, coverURL: URL? = nil, thumbnailURL: URL? = nil,
         status: ReadingStatus = .want, myRating: Int? = nil, price: Double? = nil, currency: String? = nil,
         priceText: String? = nil, wishlistPosition: Int? = nil, itemCount: Int = 0,
         olRating: Double? = nil, firstPublishYear: Int? = nil, source: String? = nil, addedOn: Date? = nil) {
        self.key = key
        self.title = title
        self.itemTitle = itemTitle
        self.authors = authors
        self.format = format
        self.coverURL = coverURL
        self.thumbnailURL = thumbnailURL
        self.status = status
        self.myRating = myRating
        self.price = price
        self.currency = currency
        self.priceText = priceText
        self.wishlistPosition = wishlistPosition
        self.itemCount = itemCount
        self.olRating = olRating
        self.firstPublishYear = firstPublishYear
        self.source = source
        self.addedOn = addedOn
    }

    init(record: [String: CypherValue]) throws {
        try self.init(row: Row(record))
    }

    init(row: Row) throws {
        let key = try row.requiredString("key")
        self.init(
            key: key,
            title: row.string("title") ?? row.string("itemTitle") ?? key,
            itemTitle: row.string("itemTitle"),
            authors: row.strings("authors"),
            format: row.string("format"),
            coverURL: row.imageURL("coverURL"),
            thumbnailURL: row.imageURL("thumbnailURL"),
            status: ReadingStatus(graphValue: row.string("status")),
            myRating: row.int("myRating"),
            price: row.double("price"),
            currency: row.string("currency"),
            priceText: row.string("priceText"),
            wishlistPosition: row.int("position"),
            itemCount: row.int("itemCount") ?? 0,
            olRating: row.double("olRating"),
            firstPublishYear: row.int("firstPublishYear"),
            source: row.string("source"),
            addedOn: row.instant("addedOn"))
    }

    /// A copy with the user's status and/or rating replaced (in-place row
    /// patches after a write). `rating: .some(nil)` clears the rating.
    func with(status newStatus: ReadingStatus? = nil, rating newRating: Int?? = nil) -> BookSummary {
        BookSummary(key: key, title: title, itemTitle: itemTitle, authors: authors, format: format,
                    coverURL: coverURL, thumbnailURL: thumbnailURL, status: newStatus ?? status,
                    myRating: newRating ?? myRating, price: price, currency: currency, priceText: priceText,
                    wishlistPosition: wishlistPosition, itemCount: itemCount, olRating: olRating,
                    firstPublishYear: firstPublishYear, source: source, addedOn: addedOn)
    }

    /// The item title, shown under the book title when they differ (the
    /// Open Library title can be in another language, e.g. "L'étranger").
    var subtitle: String? { BookTitles.subtitle(bookTitle: title, itemTitle: itemTitle) }

    var authorLine: String { authors.isEmpty ? "Unknown author" : authors.joined(separator: ", ") }

    /// Not resolved in Open Library: only Amazon data.
    var isUnresolved: Bool { key.hasPrefix("amazon:") }

    var displayPrice: String? { PriceFormat.string(price: price, currency: currency, text: priceText) }

    /// Added through the app (phase 5): no Amazon item.
    var isAppAdded: Bool { source == "app" }

    /// What the row shows at the trailing edge: the price, else "Added in
    /// app" for app books, else nil.
    var trailingText: String? { displayPrice ?? (isAppAdded ? "Added in app" : nil) }

    /// Cover candidates in preference order: the Open Library cover (medium
    /// size for rows), then the Amazon thumbnail.
    var imageURLs: [URL] {
        [coverURL.map(CoverURLs.medium), thumbnailURL].compactMap { $0 }
    }
}

enum BookTitles {
    /// `itemTitle` when it says something the book title does not: it
    /// differs after case/diacritic folding and does not merely extend the
    /// book title with a subtitle or edition note.
    static func subtitle(bookTitle: String, itemTitle: String?) -> String? {
        guard let itemTitle, !itemTitle.isEmpty else { return nil }
        let a = fold(bookTitle), b = fold(itemTitle)
        if a.isEmpty || a == b || b.hasPrefix(a) { return nil }
        return itemTitle
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CoverURLs {
    /// Open Library covers come in -S/-M/-L; rows use -M to save bandwidth.
    static func medium(_ url: URL) -> URL {
        let s = url.absoluteString
        guard s.contains("covers.openlibrary.org"), s.hasSuffix("-L.jpg") else { return url }
        return URL(string: String(s.dropLast("-L.jpg".count)) + "-M.jpg") ?? url
    }
}

enum PriceFormat {
    /// `price` formatted in `currency` (default USD); falls back to the
    /// scraped `text` when there is no numeric price.
    static func string(price: Double?, currency: String?, text: String?) -> String? {
        if let price {
            let code = (currency?.count == 3 ? currency! : "USD").uppercased()
            return price.formatted(.currency(code: code).locale(Locale(identifier: "en_US")))
        }
        return text
    }
}
