import Testing
import Foundation
import Relate
@testable import RelateBooksCore

/// The whole add-book pipeline on a temp copy of the bundled sample books.rl
/// scaled to 1,800 books (`ScaledLibrary`; stub transport, stub geocoder;
/// spec D36), then the phase 5 statements' timings with the PerfTests budgets
/// (50 ms, place statements 30 ms), and the main list and search queries
/// with an Item-less book present.
@Suite("Import on the scaled sample books.rl", .serialized)
struct ImportRealStoreTests {
    /// One of The Perfect Storm's three places, already on the map before the
    /// import (as on a real export), so the import reuses it.
    static let seedNewEngland = """
        CREATE (:Place {name: 'New England', geocoded_label: 'New England', geo_status: 'ok', geo_source: 'seed',
                        geo_lat: 43.9654, geo_lon: -70.8227, location: point({latitude: 43.9654, longitude: -70.8227})})
        """

    @Test("import The Perfect Storm into a copy of the scaled sample; every phase 5 query within budget")
    func realStore() async throws {
        try await HeavyTestGate.exclusive { try await Self.run() }
    }

    static func run() async throws {
        let source = PerfTests.bundledStore
        try #require(FileManager.default.fileExists(atPath: source.path), "missing \(source.path)")
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await ScaledLibrary.make(at: dir.appendingPathComponent("library.rl"))
        #expect(try await store.bookCount() == ScaledLibrary.bookCount)
        try await store.query(Self.seedNewEngland)
        let labelsAtStart = try await store.locatedLabels().count
        let usBox = GeoBox(south: 17.5, west: -135, north: 62.5, east: -65)
        let usLabelsBefore = try await store.placePins(in: usBox).count

        // Lookup: search, work and both authors (neither is in the sample), so 4 requests.
        let transport = StubOpenLibraryTransport(latency: .zero)
        let importer = BookImporter(client: OpenLibraryClient(transport: transport, minimumInterval: .zero), store: store)
        #expect(try await importer.localMatch(isbn: PerfectStorm.isbn) == nil)
        guard case .draft(let draft) = try await importer.resolve(isbn: PerfectStorm.isbn) else {
            Issue.record("expected a draft"); return
        }
        #expect(await transport.requestedURLs.count == 4)

        // Save (the statements of `saveImport`, timed), then geocode.
        let newPlaces = try await store.missingPlaceNames(draft.terms.places)
        #expect(newPlaces == ["North Atlantic Ocean", "Gloucester (Mass.)"])
        let results = try await store.write(try ImportQueries.saveStatements(draft, now: Date()))
        #expect(results.first?.rowsView.first?.bool("created") == true)
        let saveMs = results.reduce(0) { $0 + $1.elapsedMs }
        let outcomes = await PlaceLocator(store: store, geocoder: StubPlaceGeocoder()).locate(newPlaces)
        #expect(outcomes.map(\.label) == ["North Atlantic Ocean", "Gloucester"])

        // The book reaches the library, the author, the map, keyword search.
        #expect(try await store.bookCount() == ScaledLibrary.bookCount + 1)
        #expect(try await store.authorBooks(key: PerfectStorm.junger).count == 1)
        #expect(try await store.placeSummary(label: "Gloucester")?.bookCount == 1)
        let usPins = try await store.placePins(in: usBox)
        #expect(usPins.contains { $0.label == "Gloucester" && $0.books == 1 })
        #expect(usPins.count == usLabelsBefore + 1)
        #expect(try await store.searchPlaces("glouc").first?.label == "Gloucester")
        #expect(try await store.bookTextHits(KeywordQuery("perfect storm")!, limit: 10).first?.key == PerfectStorm.key)
        #expect(try await importer.localMatch(isbn: PerfectStorm.hailMaryISBN) == PerfectStorm.hailMary)
        #expect(try await importer.localMatch(isbn: PerfectStorm.isbn) == PerfectStorm.key)
        #expect(try await store.placeLocation(name: "North Atlantic Ocean").isOnMap)
        #expect(try await store.placeLocation(name: "New England").isOnMap)
        let row = try #require(try await store.libraryPage(filter: LibraryFilter(text: "perfect storm")).first)
        #expect(row.key == PerfectStorm.key && row.trailingText == "Added in app")
        #expect(try await store.libraryPage(sort: .wishlist, skip: ScaledLibrary.bookCount).last?.key == PerfectStorm.key)
        #expect(try await store.libraryCount(filter: LibraryFilter(unresolvedOnly: true)) == 0)
        #expect(try await store.saveImport(draft, now: Date()) == .existing(key: PerfectStorm.key))

        // Timings.
        let titleKeys = OLSearchResponse(json: try FixtureFiles.openLibraryJSON("search-title.json")).docs.map(\.key)
        let keys21 = titleKeys + [PerfectStorm.hailMary, "/works/OL59800W"]
        #expect(keys21.count == 21)
        let budget: [(String, Statement)] = [
            ("import bookByISBN PHM", try ImportQueries.bookByISBN(PerfectStorm.hailMaryISBN)),
            ("import bookExists", try ImportQueries.bookExists(key: PerfectStorm.key)),
            ("import existingBooks 21", try ImportQueries.existingBooks(keys: keys21)),
            ("import existingAuthors 2", try ImportQueries.existingAuthors(keys: [PerfectStorm.junger, PerfectStorm.collins])),
            ("import missingPlaces 3", try ImportQueries.missingPlaces(names: draft.terms.places)),
            ("import appFormatFacets", LibraryQueries.appFormatFacets),
            ("import formatFacets items", LibraryQueries.formatFacets),
            ("import scanBook Perfect Storm", try EmbeddingQueries.scanBook(key: PerfectStorm.key)),
            ("import libraryPage [text=perfect storm]", try LibraryQueries.page(filter: LibraryFilter(text: "perfect storm"), sort: .title, skip: 0)),
            ("import detail Perfect Storm", try BookQueries.detail(key: PerfectStorm.key)),
            ("import hydrate 2 keys", try SearchQueries.hydrate(keys: [PerfectStorm.key, PerfectStorm.hailMary], filter: SearchFilter(), limit: 50)),
            // The main list and search queries with an Item-less book in the store.
            ("import libraryPage title p0", try LibraryQueries.page(filter: LibraryFilter(), sort: .title, skip: 0)),
            ("import libraryPage wishlist skip 1800", try LibraryQueries.page(filter: LibraryFilter(), sort: .wishlist, skip: 1800)),
            ("import libraryPage [format=Hardcover] p0", try LibraryQueries.page(filter: LibraryFilter(format: "Hardcover"), sort: .title, skip: 0)),
            ("import libraryCount [format=Paperback]", try LibraryQueries.count(filter: LibraryFilter(format: "Paperback"))),
            ("import bookText [perfect storm]", try SearchQueries.bookText(KeywordQuery("perfect storm")!, limit: 50)),
        ]
        let geo: [(String, Statement)] = [
            ("import nearestLabel Gloucester", try ImportQueries.nearestLabel(GeoCoordinate(latitude: 42.6159, longitude: -70.6620), radiusMeters: 1000)),
            ("import nearestLabel Pasadena", try ImportQueries.nearestLabel(GeoCoordinate(latitude: 34.1477, longitude: -118.1442), radiusMeters: 1000)),
            ("import locatedLabels", ImportQueries.locatedLabels()),
        ]
        var measured: [PerfTests.Measurement] = []
        for (name, statement) in budget {
            measured.append(try await PerfTests.measure(store, name, statement))
        }
        var geoMeasured: [PerfTests.Measurement] = []
        for (name, statement) in geo {
            geoMeasured.append(try await PerfTests.measure(store, name, statement))
        }
        print(String(format: "PERF import save transaction: %.2f ms (cold, single run; %d statements)", saveMs, results.count))
        #expect(saveMs < PerfTests.budgetMs)
        for m in measured {
            #expect(m.median < PerfTests.budgetMs, "\(m.name) median \(m.median) ms >= \(PerfTests.budgetMs) ms")
        }
        for m in geoMeasured {
            #expect(m.median < PerfTests.placeBudgetMs, "\(m.name) median \(m.median) ms >= \(PerfTests.placeBudgetMs) ms")
        }
        let all = measured + geoMeasured
        let worst = all.max { $0.median < $1.median }!
        print(String(format: "PERF import summary: %d queries; slowest median %.2f ms (%@)", all.count, worst.median, worst.name))
        #expect(geoMeasured[1].rows == 1 && geoMeasured[0].rows == 1)
        #expect(geoMeasured[2].rows == labelsAtStart + 2)  // + Gloucester, North Atlantic Ocean

        // Variant headings of regions already on the map join their label
        // (the extension's assign_labels), however far CLGeocoder's centre is.
        let variants = ["Hawaii (U.S.)", "england", "Cuba"]
        try await store.query("UNWIND $names AS name CREATE (:Place {name: name})",
                              ["names": .list(variants.map(CypherValue.string))])
        let q = { (h: String) in HeadingNormalizer.normalize(h).query ?? h }
        let table: [String: [GeocodeCandidate]] = [
            q("Hawaii (U.S.)"): [GeocodeCandidate(coordinate: GeoCoordinate(latitude: 20.8, longitude: -156.3), name: "Hawaii",
                                                  administrativeArea: "HI", country: "United States", isoCountryCode: "US")],
            q("england"): [GeocodeCandidate(coordinate: GeoCoordinate(latitude: 52.8, longitude: -1.6), name: "England",
                                            administrativeArea: "England", country: "United Kingdom", isoCountryCode: "GB")],
            q("Cuba"): [GeocodeCandidate(coordinate: GeoCoordinate(latitude: 21.32718, longitude: -77.82286),
                                                  name: "Cuba", country: "Cuba", isoCountryCode: "CU")],
        ]
        let labelsBefore = try await store.locatedLabels().count
        let variantOutcomes = await PlaceLocator(store: store, geocoder: StubPlaceGeocoder(table: table)).locate(variants)
        #expect(variantOutcomes.map(\.label) == ["Hawaii", "England", "Cuba"])
        #expect(try await store.locatedLabels().count == labelsBefore + 1)  // Cuba is new to the store
        #expect(try await store.placeSummary(label: "Hawaii")?.bookCount ?? 0 > 0)
    }
}

extension PerfectStorm {
    static let hailMary = "/works/OL21745884W"
    /// The sample's Project Hail Mary edition (Kindle, Ballantine).
    static let hailMaryISBN = ISBN("9780593135211")!
}
