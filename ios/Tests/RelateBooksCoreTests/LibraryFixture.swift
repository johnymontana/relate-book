import Foundation
import Relate
@testable import RelateBooksCore

/// A small graph in the shape of books.rl, covering every facet:
///
/// | key | title | authors | items (position: format price) | notes |
/// | --- | --- | --- | --- | --- |
/// | /works/OL1W | Apple Orchards | Jane Appleseed | 3: Paperback 10.00, 1: Hardcover 25.00 | two items; rating 4.5; 2001; fantasy; series #2; award 2002 |
/// | /works/OL2W | Mango Season | Zed Adams | 2: Kindle Edition 5.00 | status read; rating 3.9; 1999; science fiction |
/// | /works/OL3W | Zebra Stripes | (none) | 4: Paperback 7.50 | no author; no rating; 2010; series #1 |
/// | amazon:B000UNRES | Mystery Thing | Bob Brown | 5: Mass Market Paperback (no price, price_text "$3.99") | unresolved |
/// | /works/OL5W | L'étranger | Albert Camus | 6: Paperback 12.00 "The Stranger" | non-English title; author born Mondovi, citizen of France, won Nobel 1957 |
enum LibraryFixture {
    static let statements: [String] = [
        """
        CREATE (w:Wishlist {id: 'W1', title: 'Test list'})
        CREATE (a1:Author {key: '/authors/OL1A', name: 'Jane Appleseed',
                           birth_date: '1 January 1950', wikipedia_url: 'https://en.wikipedia.org/wiki/Jane',
                           photo_url: 'https://covers.openlibrary.org/a/id/1-L.jpg', occupations: ['novelist', 'farmer']})
        CREATE (a2:Author {key: '/authors/OL2A', name: 'Zed Adams'})
        CREATE (a3:Author {key: '/authors/OL3A', name: 'Bob Brown'})
        CREATE (a4:Author {key: '/authors/OL4A', name: 'Albert Camus', birth_date: '7 November 1913', death_date: '4 January 1960'})
        CREATE (b1:Book {key: '/works/OL1W', title: 'Apple Orchards', cover_url: 'https://covers.openlibrary.org/b/id/1-L.jpg',
                         description: 'All about apples.', first_publish_year: 2001, pages_median: 320, edition_count: 4,
                         languages: ['eng'], ol_rating: 4.5, ol_rating_count: 12, ol_want_to_read: 40,
                         ol_already_read: 7, ol_currently_reading: 2, ol_readinglog_count: 49,
                         url: 'https://openlibrary.org/works/OL1W'})
        CREATE (b2:Book {key: '/works/OL2W', title: 'Mango Season', first_publish_year: 1999, ol_rating: 3.9, reading_status: 'read'})
        CREATE (b3:Book {key: '/works/OL3W', title: 'Zebra Stripes', first_publish_year: 2010, cover_url: 'https://covers.openlibrary.org/b/id/3-L.jpg'})
        CREATE (b4:Book {key: 'amazon:B000UNRES', title: 'Mystery Thing'})
        CREATE (b5:Book {key: '/works/OL5W', title: 'L’étranger', first_publish_year: 1942})
        CREATE (i1:Item:Edition {asin: 'A001', title: 'Apple Orchards (Paperback)', format: 'Paperback', price: 10.0, currency: 'USD',
                                 url: 'https://www.amazon.com/dp/A001', thumbnail_url: 'https://m.media-amazon.com/A001._SL160_.jpg',
                                 amazon_rating: 4.2, amazon_review_count: 31, is_book: true})
        CREATE (i2:Item:Edition {asin: 'A002', title: 'Apple Orchards: A History', format: 'Hardcover', price: 25.0, currency: 'USD',
                                 url: 'https://www.amazon.com/dp/A002', is_book: true})
        CREATE (i3:Item:Edition {asin: 'A003', title: 'Mango Season', format: 'Kindle Edition', price: 5.0, currency: 'USD', is_book: true})
        CREATE (i4:Item:Edition {asin: 'A004', title: 'Zebra Stripes', format: 'Paperback', price: 7.5, currency: 'USD', is_book: true})
        CREATE (i5:Item:Edition {asin: 'B000UNRES', title: 'Mystery Thing: A Novel', format: 'Mass Market Paperback', price_text: '$3.99', is_book: true})
        CREATE (i6:Item:Edition {asin: 'A006', title: 'The Stranger', format: 'Paperback', price: 12.0, currency: 'USD', is_book: true})
        CREATE (w)-[:CONTAINS {position: 3, priority_label: 'medium'}]->(i1)
        CREATE (w)-[:CONTAINS {position: 1, priority_label: 'high'}]->(i2)
        CREATE (w)-[:CONTAINS {position: 2}]->(i3)
        CREATE (w)-[:CONTAINS {position: 4}]->(i4)
        CREATE (w)-[:CONTAINS {position: 5}]->(i5)
        CREATE (w)-[:CONTAINS {position: 6}]->(i6)
        CREATE (i1)-[:EDITION_OF]->(b1)
        CREATE (i2)-[:EDITION_OF]->(b1)
        CREATE (i3)-[:EDITION_OF]->(b2)
        CREATE (i4)-[:EDITION_OF]->(b3)
        CREATE (i5)-[:EDITION_OF]->(b4)
        CREATE (i6)-[:EDITION_OF]->(b5)
        CREATE (b1)-[:WRITTEN_BY {role: 'Author'}]->(a1)
        CREATE (b2)-[:WRITTEN_BY {role: 'Author'}]->(a2)
        CREATE (b4)-[:WRITTEN_BY {role: 'Author'}]->(a3)
        CREATE (b5)-[:WRITTEN_BY {role: 'Author'}]->(a4)
        """,
        """
        MATCH (b1:Book {key: '/works/OL1W'}), (b2:Book {key: '/works/OL2W'}), (b3:Book {key: '/works/OL3W'}),
              (b5:Book {key: '/works/OL5W'}), (a4:Author {key: '/authors/OL4A'})
        CREATE (fruit:Subject {name: 'Fruit'}), (orchards:Subject {name: 'Orchards'})
        CREATE (wa:Place {name: 'Washington'}), (mondovi:Place {name: 'Mondovi'})
        CREATE (johnny:Person {name: 'Johnny Appleseed'}), (era:Era {name: '20th century'})
        CREATE (fantasy:Genre {name: 'fantasy'}), (sf:Genre {name: 'science fiction'})
        CREATE (press:Publisher {name: 'Tree Press'}), (cycle:Series {name: 'Orchard Cycle'})
        CREATE (hugo:Award {name: 'Hugo Award'}), (nobel:Award {name: 'Nobel Prize in Literature'})
        CREATE (france:Country {name: 'France'})
        CREATE (b1)-[:ABOUT]->(fruit), (b1)-[:ABOUT]->(orchards), (b2)-[:ABOUT]->(fruit)
        CREATE (b1)-[:SET_IN]->(wa), (b1)-[:FEATURES]->(johnny), (b1)-[:SET_DURING]->(era)
        CREATE (b1)-[:IN_GENRE]->(fantasy), (b2)-[:IN_GENRE]->(sf)
        CREATE (b1)-[:PUBLISHED_BY]->(press)
        CREATE (b1)-[:PART_OF {position: '2'}]->(cycle), (b3)-[:PART_OF {position: '1'}]->(cycle)
        CREATE (b1)-[:WON {year: 2002}]->(hugo)
        CREATE (a4)-[:WON {year: 1957}]->(nobel), (a4)-[:BORN_IN]->(mondovi), (a4)-[:CITIZEN_OF]->(france)
        """,
    ]

    static func store() async throws -> GraphStore {
        let store = try await GraphStore.inMemory()
        for statement in statements { try await store.query(statement) }
        // Real bios use CRLF; a Cypher literal cannot spell a CR, so pass it as a parameter.
        try await store.query("MATCH (a:Author {key: '/authors/OL1A'}) SET a.bio = $bio",
                              ["bio": .string("Grew apples.\r\nSource: [Wikipedia](https://example.org)")])
        return store
    }

    /// Adds `count` plain books "Filler 001…" (each with one Paperback item
    /// and author "Filler Author") for paging tests.
    static func addFillers(_ count: Int, to store: GraphStore) async throws {
        let rows: [CypherValue] = (1...count).map { n in
            let id = String(format: "%03d", n)
            return ["key": .string("/works/F\(id)W"), "title": .string("Filler \(id)"), "asin": .string("F\(id)"), "position": .int(Int64(100 + n))]
        }
        try await store.query("""
            MATCH (w:Wishlist {id: 'W1'})
            MERGE (a:Author {key: '/authors/FILLER'}) ON CREATE SET a.name = 'Filler Author'
            WITH w, a
            UNWIND $rows AS row
            CREATE (b:Book {key: row.key, title: row.title})
            CREATE (i:Item:Edition {asin: row.asin, title: row.title, format: 'Paperback', price: 1.0, currency: 'USD'})
            CREATE (w)-[:CONTAINS {position: row.position}]->(i)
            CREATE (i)-[:EDITION_OF]->(b)
            CREATE (b)-[:WRITTEN_BY]->(a)
            """, ["rows": .list(rows)])
    }
}
