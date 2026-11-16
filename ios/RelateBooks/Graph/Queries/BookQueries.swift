import Relate

/// Cypher for the Book detail screen: one statement, scalar columns plus
/// collected lists (pattern comprehensions avoid OPTIONAL MATCH fan-out).
/// The user's status, rating, dates, tags and notes come in the same row
/// (`StatusQueries.userColumns`). Phase 5 adds where the book came from
/// (`source`, `added_on`, `match`) and the edition facts an ISBN import
/// writes on the Book itself (an app-added book has no Item).
enum BookQueries {
    static func detail(key: String) throws -> Statement {
        try Statement("""
            MATCH (b:Book {key: $key})
            RETURN b.key AS key, b.title AS title, b.url AS url, b.cover_url AS coverURL,
                   b.description AS description, b.first_publish_year AS firstPublishYear,
                   b.pages_median AS pagesMedian, b.edition_count AS editionCount, b.languages AS languages,
                   b.ol_rating AS olRating, b.ol_rating_count AS olRatingCount,
                   b.ol_want_to_read AS olWantToRead, b.ol_already_read AS olAlreadyRead,
                   b.ol_currently_reading AS olCurrentlyReading, b.ol_readinglog_count AS olReadingLogCount,
                   coalesce(b.reading_status, 'want') AS status,
                   b.source AS source, b.added_on AS addedOn, b.match AS importMatch, b.subtitle AS subtitle,
                   b.isbn13 AS isbn13, b.isbn10 AS isbn10, b.publisher AS publisherName, b.publish_date AS publishDate,
                   b.publish_year AS publishYear, b.pages AS pages, b.physical_format AS physicalFormat,
                   [(b)-[r:WRITTEN_BY]->(a:Author) | {key: a.key, name: a.name, role: r.role,
                       richness: (CASE WHEN a.photo_url IS NOT NULL OR a.image_url IS NOT NULL THEN 4 ELSE 0 END)
                               + (CASE WHEN a.bio IS NOT NULL THEN 2 ELSE 0 END)
                               + (CASE WHEN a.birth_date IS NOT NULL OR a.wikidata_birth_date IS NOT NULL THEN 1 ELSE 0 END)}] AS authors,
                   [(b)-[:ABOUT]->(s:Subject) | s.name] AS subjects,
                   [(b)-[:SET_IN]->(p:Place) | p.name] AS places,
                   [(b)-[:FEATURES]->(p:Person) | p.name] AS people,
                   [(b)-[:SET_DURING]->(e:Era) | e.name] AS eras,
                   [(b)-[:IN_GENRE]->(g:Genre) | g.name] AS genres,
                   [(b)-[:PUBLISHED_BY]->(p:Publisher) | p.name] AS publishers,
                   [(b)-[r:PART_OF]->(s:Series) | {name: s.name, position: r.position}] AS series,
                   [(b)-[r:WON]->(w:Award) | {name: w.name, year: r.year}] AS awards,
                   [(:Wishlist)-[c:CONTAINS]->(i:Item)-[:EDITION_OF]->(b) |
                       {asin: i.asin, title: i.title, byline: i.byline, format: i.format,
                        price: i.price, currency: i.currency, priceText: i.price_text,
                        amazonRating: i.amazon_rating, amazonReviewCount: i.amazon_review_count,
                        url: i.url, imageURL: i.image_url, thumbnailURL: i.thumbnail_url,
                        isbn13: i.isbn13, isbn10: i.isbn10,
                        position: c.position, priority: c.priority_label}] AS items,
            \(StatusQueries.userColumns)
            """, ["key": key])
    }
}

extension GraphStore {
    /// The book with `key`, or nil when there is none.
    func bookDetail(key: String) async throws -> BookDetail? {
        try await read(BookQueries.detail(key: key)).rowsView.first.map(BookDetail.init(row:))
    }
}
