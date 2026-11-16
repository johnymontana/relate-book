import Testing
import Foundation
import Relate
@testable import RelateBooksCore

@Suite("Next up")
struct NextUpTests {
    typealias F = ConnectionFixture

    @Test("nothing read or rated: no series, no authors; unread award winners are listed")
    func untouchedLibrary() async throws {
        let store = try await F.store()
        let next = try await store.nextUp()
        #expect(next.series.isEmpty && next.authors.isEmpty)
        #expect(next.awards.map(\.book.key) == [F.w1, F.h1])       // one award each, by title
        #expect(next.awards.allSatisfy { $0.awardCount == 1 && $0.sharedCount == 0 && $0.awards == ["Hugo Award"] })
        #expect(!next.isEmpty && NextUp().isEmpty)
    }

    @Test("a read, rated book brings its series, its author's other books and the co-winners of its award")
    func afterReadingOne() async throws {
        let store = try await F.store()
        try await store.setStatus(key: F.h1, status: .read)
        try await store.setRating(key: F.h1, rating: 5)
        let next = try await store.nextUp()

        #expect(next.series.count == 1)
        let hainish = try #require(next.series.first)
        #expect(hainish.name == "Hainish Cycle" && hainish.readCount == 1 && hainish.listCount == 2 && hainish.unreadCount == 1)
        #expect(hainish.book.key == F.h2 && hainish.book.title == "The Dispossessed" && hainish.position == "5")
        #expect(hainish.caption == "Read 1 of 2 on your list · next is #5")

        #expect(next.authors.count == 1)
        let leGuin = try #require(next.authors.first)
        #expect(leGuin.authorName == "Ursula K. Le Guin" && leGuin.bestRating == 5 && leGuin.unreadCount == 2)
        #expect(leGuin.books.map(\.key) == [F.h2, F.h3])            // by title
        #expect(leGuin.caption == "You rated The Left Hand of Darkness 5")

        // The read book leaves the award list; Project Hail Mary shares the Hugo with it.
        #expect(next.awards.map(\.book.key) == [F.w1])
        #expect(next.awards.first?.sharedCount == 1 && next.awards.first?.caption == "Hugo Award")
    }

    @Test("series order: lowest position first, fractional and missing positions; a finished series drops out")
    func seriesOrder() async throws {
        let store = try await F.store()
        try await store.query("""
            MATCH (s:Series {name: 'Hainish Cycle'}), (h3:Book {key: '/works/H3W'}), (x1:Book {key: '/works/X1W'})
            CREATE (h3)-[:PART_OF {position: '4.5'}]->(s), (x1)-[:PART_OF]->(s)
            """)
        try await store.setStatus(key: F.h1, status: .read)
        var series = try await store.nextUp().series
        #expect(series.first?.book.key == F.h3 && series.first?.position == "4.5")
        #expect(series.first?.listCount == 4 && series.first?.unreadCount == 3)
        // A book being read is not "next"; neither is a read one.
        try await store.setStatus(key: F.h3, status: .reading)
        series = try await store.nextUp().series
        #expect(series.first?.book.key == F.h2)
        try await store.setStatus(key: F.h2, status: .read)
        series = try await store.nextUp().series
        #expect(series.first?.book.key == F.x1 && series.first?.position == nil && series.first?.readCount == 2)
        #expect(series.first?.caption == "Read 2 of 4 on your list")
        try await store.setStatus(key: F.x1, status: .read)
        #expect(try await store.nextUp().series.isEmpty)
    }

    @Test("authors: a rating below the threshold is not a recommendation; rated and started books are not suggested")
    func authorRules() async throws {
        let store = try await F.store()
        try await store.setRating(key: F.w1, rating: 3)
        #expect(try await store.nextUp().authors.isEmpty)
        try await store.setRating(key: F.w1, rating: 4)
        try await store.setRating(key: F.h1, rating: 5)
        var authors = try await store.nextUp().authors
        #expect(authors.map(\.authorName) == ["Ursula K. Le Guin", "Andy Weir"])    // best rating first
        #expect(authors[1].books.map(\.key) == [F.w2] && authors[1].caption == "You rated Project Hail Mary 4")
        try await store.setStatus(key: F.w2, status: .reading)
        try await store.setRating(key: F.h2, rating: 2)
        authors = try await store.nextUp(perAuthor: 1).authors
        #expect(authors.map(\.authorName) == ["Ursula K. Le Guin"])
        #expect(authors[0].books.map(\.key) == [F.h3] && authors[0].unreadCount == 1)
    }

    @Test("statement shape and limits")
    func statements() throws {
        #expect(try NextUpQueries.series(limit: 0).parameters["limit"] == .int(1))
        #expect(try NextUpQueries.authors(minRating: 4, perAuthor: 0, limit: 5).parameters["perAuthor"] == .int(1))
        for statement in [try NextUpQueries.series(limit: 5), try NextUpQueries.authors(minRating: 4, perAuthor: 3, limit: 5),
                          try NextUpQueries.awards(minRating: 4, limit: 5),
                          try NextUpQueries.nearReading(radiusMeters: 1000, perPlace: 3, limit: 5)] {
            #expect(!statement.cypher.contains("CALL"))
        }
    }
}

@Suite("Near your reading")
struct NearReadingTests {
    @Test("nothing read: no suggestions")
    func nothingRead() async throws {
        let store = try await PlaceFixture.store()
        #expect(try await store.placesNearReading().isEmpty)
    }

    @Test("a read book's own setting and the settings near it, nearest first, unread books only")
    func nearARead() async throws {
        let store = try await PlaceFixture.store()
        // River Song is set in Montana and in Butte (about 265 km apart).
        try await store.setStatus(key: "/works/M1", status: .read)
        let near = try await store.placesNearReading(radiusMeters: 300_000)
        #expect(near.map(\.label) == ["Montana", "Butte"])
        let montana = try #require(near.first)
        #expect(montana.isSamePlace && montana.meters == 0 && montana.fromLabel == "Montana")
        #expect(montana.books.map(\.title) == ["A Big Sky", "Mountain Time"] && montana.bookCount == 2)
        #expect(montana.caption == "You read River Song, set here")
        #expect(abs(montana.coordinate.latitude - PlaceFixture.montana.latitude) < 1e-6)
        #expect(near[1].books.map(\.title) == ["Copper Town"] && near[1].isSamePlace)

        // Reading Copper Town too leaves Butte with nothing unread.
        try await store.setStatus(key: "/works/B1", status: .read)
        #expect(try await store.placesNearReading(radiusMeters: 300_000).map(\.label) == ["Montana"])
    }

    @Test("a neighbouring place is suggested with its distance; the radius bounds it; one row per label")
    func neighbours() async throws {
        let store = try await PlaceFixture.store()
        try await store.setStatus(key: "/works/B1", status: .read)      // Copper Town: Butte only
        let near = try await store.placesNearReading(radiusMeters: 300_000)
        #expect(near.map(\.label) == ["Butte", "Montana"])
        let butte = near[0], montana = near[1]
        #expect(butte.isSamePlace && butte.books.map(\.title) == ["River Song"])
        #expect(!montana.isSamePlace && montana.fromLabel == "Butte" && montana.readTitle == "Copper Town")
        #expect((255_000...275_000).contains(montana.meters))
        #expect(montana.caption == "\(NearbyReading.distanceText(montana.meters)) from Butte, where Copper Town is set")
        #expect(montana.bookCount == 3 && montana.books.count == 3)
        #expect(try await store.placesNearReading(radiusMeters: 300_000, perPlace: 2)[1].books.count == 2)
        #expect(try await store.placesNearReading(radiusMeters: 100_000).map(\.label) == ["Butte"])
        // The whole of the United States is within reach of a larger radius: two headings, one label, one row.
        let wide = try await store.placesNearReading(radiusMeters: 1_500_000)
        #expect(wide.map(\.label) == ["Butte", "Montana", "United States"])
        #expect(wide[2].bookCount == 3 && Set(wide[2].books.map(\.title)) == ["Highways", "Coast to Coast", "Prairie"])
        #expect(try await store.placesNearReading(radiusMeters: 1_500_000, limit: 1).count == 1)
        // A heading on more books than the cap is neither a destination (Montana: 3 books)...
        #expect(try await store.placesNearReading(radiusMeters: 300_000, maxPlaceBooks: 2).map(\.label) == ["Butte"])
        // ...nor an origin: with only A Big Sky read (Montana), nothing is near.
        try await store.setStatus(key: "/works/B1", status: .want)
        try await store.setStatus(key: "/works/M2", status: .read)
        #expect(try await store.placesNearReading(radiusMeters: 300_000, maxPlaceBooks: 2).isEmpty)
        #expect(try await store.placesNearReading(radiusMeters: 300_000).map(\.label) == ["Montana", "Butte"])
    }

    @Test("distance text")
    func distanceText() {
        #expect(NearbyReading.distanceText(400) == "under 1 km")
        #expect(NearbyReading.distanceText(8_400) == "8 km")
        #expect(NearbyReading.distanceText(99_400) == "99 km")
        #expect(NearbyReading.distanceText(263_000) == "260 km")
    }
}
