import Testing
import Foundation
import Relate
@testable import RelateBooksCore

/// An in-memory store with located places, in the shape the geocode pass
/// writes (`location` point + `geocoded_label` + `geo_status`):
///
/// | Heading(s) | Label | Location | Links |
/// | --- | --- | --- | --- |
/// | Montana | Montana | (47.3753, -109.6388) | books M1, M2, M3 |
/// | Butte (Mont.) | Butte | (46.0131, -112.5370) | books M1, B1 |
/// | United States, USA | United States | (39.78, -100.45) | US1, US2 -> United States; US2, US3 -> USA; author A1 born USA |
/// | London, London (England) | London | (51.507, -0.128) | L1 -> both; authors A2, A3 born London |
/// | Tokyo | Tokyo | (35.68, 139.76) | birthplace only: author A4 |
/// | Suva | Suva | (-18.14, 178.44) | S1 |
/// | Apia | Apia | (-13.83, -171.77) | S2 |
/// | Gethen | none | geo_status skipped | G1 |
/// | Middle West | none | geo_status unresolved | W1 |
enum PlaceFixture {
    static let montana = GeoCoordinate(latitude: 47.3753, longitude: -109.6388)
    static let unitedStates = GeoCoordinate(latitude: 39.78, longitude: -100.45)

    static let statements: [String] = [
        """
        CREATE (m1:Book {key: '/works/M1', title: 'River Song'})
        CREATE (m2:Book {key: '/works/M2', title: 'A Big Sky'})
        CREATE (m3:Book {key: '/works/M3', title: 'Mountain Time'})
        CREATE (b1:Book {key: '/works/B1', title: 'Copper Town'})
        CREATE (us1:Book {key: '/works/US1', title: 'Highways'})
        CREATE (us2:Book {key: '/works/US2', title: 'Coast to Coast'})
        CREATE (us3:Book {key: '/works/US3', title: 'Prairie'})
        CREATE (l1:Book {key: '/works/L1', title: 'Fog'})
        CREATE (s1:Book {key: '/works/S1', title: 'Island Days'})
        CREATE (s2:Book {key: '/works/S2', title: 'Lagoon'})
        CREATE (g1:Book {key: '/works/G1', title: 'Winter World'})
        CREATE (w1:Book {key: '/works/W1', title: 'Corn Belt'})
        CREATE (a1:Author {key: '/authors/A1', name: 'Amy American'})
        CREATE (a2:Author {key: '/authors/A2', name: 'Lena Londoner'})
        CREATE (a3:Author {key: '/authors/A3', name: 'Bert Bow'})
        CREATE (a4:Author {key: '/authors/A4', name: 'Taro Tokyo'})
        CREATE (m1)-[:WRITTEN_BY]->(a2), (l1)-[:WRITTEN_BY]->(a2)
        CREATE (pm:Place {name: 'Montana', geocoded_label: 'Montana', geo_status: 'ok', geo_source: 'nominatim',
                          location: point({latitude: 47.3753, longitude: -109.6388})})
        CREATE (pb:Place {name: 'Butte (Mont.)', geocoded_label: 'Butte', geo_status: 'ok', geo_source: 'nominatim',
                          location: point({latitude: 46.0131, longitude: -112.5370})})
        CREATE (pus:Place {name: 'United States', geocoded_label: 'United States', geo_status: 'ok', geo_source: 'nominatim',
                           location: point({latitude: 39.78, longitude: -100.45})})
        CREATE (pusa:Place {name: 'USA', geocoded_label: 'United States', geo_status: 'ok', geo_source: 'nominatim',
                            location: point({latitude: 39.78, longitude: -100.45})})
        CREATE (pl:Place {name: 'London', geocoded_label: 'London', geo_status: 'ok', geo_source: 'nominatim',
                          location: point({latitude: 51.507, longitude: -0.128})})
        CREATE (ple:Place {name: 'London (England)', geocoded_label: 'London', geo_status: 'ok', geo_source: 'nominatim',
                           location: point({latitude: 51.507, longitude: -0.128})})
        CREATE (pt:Place {name: 'Tokyo', geocoded_label: 'Tokyo', geo_status: 'ok', geo_source: 'nominatim',
                          location: point({latitude: 35.68, longitude: 139.76})})
        CREATE (ps:Place {name: 'Suva', geocoded_label: 'Suva', geo_status: 'ok', geo_source: 'nominatim',
                          location: point({latitude: -18.14, longitude: 178.44})})
        CREATE (pa:Place {name: 'Apia', geocoded_label: 'Apia', geo_status: 'ok', geo_source: 'nominatim',
                          location: point({latitude: -13.83, longitude: -171.77})})
        CREATE (pg:Place {name: 'Gethen', geo_status: 'skipped', geo_reason: 'fictional'})
        CREATE (pw:Place {name: 'Middle West', geo_status: 'unresolved', geo_query: 'Middle West'})
        CREATE (m1)-[:SET_IN]->(pm), (m2)-[:SET_IN]->(pm), (m3)-[:SET_IN]->(pm)
        CREATE (m1)-[:SET_IN]->(pb), (b1)-[:SET_IN]->(pb)
        CREATE (us1)-[:SET_IN]->(pus), (us2)-[:SET_IN]->(pus), (us2)-[:SET_IN]->(pusa), (us3)-[:SET_IN]->(pusa)
        CREATE (a1)-[:BORN_IN]->(pusa)
        CREATE (l1)-[:SET_IN]->(pl), (l1)-[:SET_IN]->(ple)
        CREATE (a2)-[:BORN_IN]->(pl), (a3)-[:BORN_IN]->(pl)
        CREATE (a4)-[:BORN_IN]->(pt)
        CREATE (s1)-[:SET_IN]->(ps), (s2)-[:SET_IN]->(pa)
        CREATE (g1)-[:SET_IN]->(pg), (w1)-[:SET_IN]->(pw)
        """,
    ]

    static func seed(_ store: GraphStore) async throws {
        for statement in statements { try await store.query(statement) }
        try await store.migrate()              // place_location and place_label exist
    }

    static func store() async throws -> GraphStore {
        let store = try await GraphStore.inMemory()
        try await seed(store)
        return store
    }

    static let usBox = GeoBox(south: 24, west: -125, north: 50, east: -66)
}

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

@Suite("Place queries")
struct PlaceQueryTests {
    @Test("region: a US box gives Montana, Butte and United States, no London")
    func region() async throws {
        let store = try await PlaceFixture.store()
        let pins = try await store.placePins(in: PlaceFixture.usBox)
        #expect(pins.map(\.label) == ["United States", "Montana", "Butte"])
    }

    @Test("grouping: distinct counts across the nodes of a label; headings sorted")
    func grouping() async throws {
        let store = try await PlaceFixture.store()
        let pins = try await store.placePins(in: .world)
        let us = try #require(pins.first { $0.label == "United States" })
        #expect(us.books == 3)                         // distinct, not 4
        #expect(us.authors == 1)
        #expect(us.placeNames == ["USA", "United States"])
        #expect(near(us.coordinate.latitude, 39.78) && near(us.coordinate.longitude, -100.45))
        let london = try #require(pins.first { $0.label == "London" })
        #expect(london.books == 1 && london.authors == 2)
        #expect(london.placeNames == ["London", "London (England)"])
        let butte = try #require(pins.first { $0.label == "Butte" })
        #expect(butte.books == 2 && butte.tier == .few)
    }

    @Test("birthplace-only pins come back with books 0")
    func birthplaceOnly() async throws {
        let store = try await PlaceFixture.store()
        let tokyo = try #require(try await store.placePins(in: .world).first { $0.label == "Tokyo" })
        #expect(tokyo.books == 0 && tokyo.authors == 1)
        #expect(tokyo.tier == .birthplace && tokyo.isBirthplaceOnly)
    }

    @Test("antimeridian: a crossing box is split in two; one unsplit statement agrees")
    func antimeridian() async throws {
        let store = try await PlaceFixture.store()
        let box = GeoBox(south: -30, west: 170, north: 0, east: -160)
        #expect(box.crossesAntimeridian)
        #expect(box.split().count == 2)
        #expect(Set(try await store.placePins(in: box).map(\.label)) == ["Suva", "Apia"])
        // Documents the engine: point.withinBBox wraps west > east since
        // relate 1.0.1 (0.16.1 matched nothing), so the split is now
        // belt-and-braces rather than required.
        let raw = Statement(try PlaceQueries.region(.world).cypher, [
            "southWest": .point(try .init(latitude: -30, longitude: 170)),
            "northEast": .point(try .init(latitude: 0, longitude: -160)),
        ])
        let labels = try await store.run(raw).rowsView.compactMap { try? PlacePin(row: $0).label }
        #expect(Set(labels) == ["Suva", "Apia"])
    }

    @Test("world: 7 labels; unlocated headings are absent")
    func world() async throws {
        let store = try await PlaceFixture.store()
        let labels = try await store.placePins(in: .world).map(\.label)
        #expect(Set(labels) == ["Montana", "Butte", "United States", "London", "Tokyo", "Suva", "Apia"])
        #expect(labels.count == 7)
        #expect(labels.first == "United States")       // most books first
    }

    @Test("search matches labels and headings, Montana first for mont")
    func search() async throws {
        let store = try await PlaceFixture.store()
        #expect(try await store.searchPlaces("mont").first?.label == "Montana")
        #expect(try await store.searchPlaces("usa").map(\.label) == ["United States"])
        #expect(try await store.searchPlaces("lond").map(\.label) == ["London"])
        #expect(try await store.searchPlaces("LOND ").map(\.label) == ["London"])
        #expect(try await store.searchPlaces("m").isEmpty)
        #expect(try await store.searchPlaces(" m ").isEmpty)
        #expect(try await store.searchPlaces("gethen").isEmpty)
        let us = try #require(try await store.searchPlaces("united").first)
        #expect(us.books == 3 && us.placeNames == ["USA", "United States"])
    }

    @Test("detail: summary, books in title order without duplicates, authors")
    func detail() async throws {
        let store = try await PlaceFixture.store()
        let montana = try #require(try await store.placeSummary(label: "Montana"))
        #expect(montana.bookCount == 3 && montana.authorCount == 0)
        #expect(near(montana.coordinate.latitude, 47.3753) && near(montana.coordinate.longitude, -109.6388))
        #expect(montana.placeNames == ["Montana"] && montana.otherNames.isEmpty)
        #expect(try await store.placeBooks(label: "Montana").map(\.title) == ["A Big Sky", "Mountain Time", "River Song"])
        let usBooks = try await store.placeBooks(label: "United States").map(\.key)
        #expect(usBooks.count == 3 && Set(usBooks).count == 3)
        let us = try #require(try await store.placeSummary(label: "United States"))
        #expect(us.bookCount == 3 && us.authorCount == 1 && us.otherNames == ["USA", "United States"])
        #expect(try await store.placeBooks(label: "United States", skip: 2, limit: 5).count == 1)
        #expect(Set(try await store.placeAuthors(label: "London").map(\.key)) == ["/authors/A2", "/authors/A3"])
        #expect(try await store.placeAuthors(label: "London").first?.name == "Lena Londoner")   // 2 books first
        #expect(try await store.placeSummary(label: "Nowhere") == nil)
        #expect(try await store.placeBooks(label: "Nowhere").isEmpty)
    }

    @Test("resolve: a label or heading, case-insensitive; unlocated is nil")
    func resolve() async throws {
        let store = try await PlaceFixture.store()
        #expect(try await store.resolvePlace("USA")?.label == "United States")
        #expect(try await store.resolvePlace("montana")?.label == "Montana")
        #expect(try await store.resolvePlace("London (England)")?.label == "London")
        #expect(try await store.resolvePlace("Butte (Mont.)")?.label == "Butte")
        #expect(try await store.resolvePlace("Gethen") == nil)
        #expect(try await store.resolvePlace("  ") == nil)
        let us = try #require(try await store.resolvePlace("United States"))
        #expect(near(us.coordinate.latitude, 39.78))
    }

    @Test("location: a heading's map status for Show on map")
    func location() async throws {
        let store = try await PlaceFixture.store()
        let gethen = try await store.placeLocation(name: "Gethen")
        #expect(!gethen.isOnMap && gethen.status == "skipped")
        #expect(gethen.notOnMapReason.contains("fictional"))
        let middleWest = try await store.placeLocation(name: "Middle West")
        #expect(!middleWest.isOnMap && middleWest.notOnMapReason == "Not on the map: location unknown")
        let usa = try await store.placeLocation(name: "USA")
        #expect(usa.isOnMap && usa.label == "United States" && usa.status == "ok")
        let unknown = try await store.placeLocation(name: "Atlantis")
        #expect(!unknown.isOnMap && unknown.status == nil && unknown.label == nil)
    }

    @Test("near me: by distance; a small radius finds nothing")
    func nearMe() async throws {
        let store = try await PlaceFixture.store()
        let missoula = GeoCoordinate(latitude: 46.87, longitude: -113.99)
        let near = try await store.placesNear(missoula, radiusMeters: 400_000)
        #expect(near.map(\.label) == ["Butte", "Montana"])
        #expect((140_000...155_000).contains(near.first?.meters ?? 0))
        #expect((325_000...345_000).contains(near.last?.meters ?? 0))
        #expect(try await store.placesNear(missoula, radiusMeters: 50_000).isEmpty)
    }

    @Test("decoding: WGS-84 points only, in range")
    func decoding() {
        let p = Row(["p": .point(.init(srid: 4326, x: -109.6, y: 47.4, z: nil))]).point("p")
        #expect(p == GeoCoordinate(latitude: 47.4, longitude: -109.6))
        #expect(Row(["p": .point(.init(srid: 4979, x: 10, y: 20, z: 300))]).point("p") == GeoCoordinate(latitude: 20, longitude: 10))
        #expect(Row(["p": .point(.init(srid: 7203, x: 1, y: 2, z: nil))]).point("p") == nil)
        #expect(Row(["p": .null]).point("p") == nil)
        #expect(Row([:]).point("p") == nil)
        #expect(Row(["p": .point(.init(srid: 4326, x: 0, y: 95, z: nil))]).point("p") == nil)
        #expect(Row(["p": .point(.init(srid: 4326, x: 181, y: 0, z: nil))]).point("p") == nil)
        #expect(Row(["p": .point(.init(srid: 4326, x: .nan, y: 0, z: nil))]).point("p") == nil)
        #expect(Row(["p": .string("47,-109")]).point("p") == nil)
    }

    @Test("PlacePin requires a label and a point")
    func pinDecoding() throws {
        let ok = try PlacePin(row: Row(["label": "X", "location": .point(.init(srid: 4326, x: 1, y: 2, z: nil)),
                                        "books": 5, "authors": 1, "placeNames": ["b", "a"]]))
        #expect(ok.placeNames == ["a", "b"] && ok.tier == .several && ok.countsText == "5 books · 1 author")
        #expect(throws: GraphError.self) { try PlacePin(row: Row(["label": "X"])) }
        #expect(throws: GraphError.self) {
            try PlacePin(row: Row(["location": .point(.init(srid: 4326, x: 1, y: 2, z: nil))]))
        }
    }

    @Test("the statements use parameters and the label index's property")
    func statements() throws {
        let region = try PlaceQueries.region(PlaceFixture.usBox)
        #expect(region.parameters["southWest"]?.pointValue?.longitude == -125 && region.parameters["northEast"]?.pointValue?.latitude == 50)
        #expect(region.cypher.contains("point.withinBBox(p.location"))
        #expect(try PlaceQueries.search("mont").parameters["limit"] == .int(20))
        #expect(try PlaceQueries.books(label: "Montana", skip: -3).parameters["skip"] == .int(0))
        #expect(try PlaceQueries.summary(label: "x").cypher.contains("{geocoded_label: $label}"))
    }
}

@Suite("Geo types")
struct GeoTypeTests {
    @Test("GeoBox clamps latitudes and wraps longitudes")
    func clampAndWrap() {
        let b = GeoBox(south: -100, west: -190, north: 100, east: -170)
        #expect(b.south == -90 && b.north == 90)
        #expect(near(b.west, 170) && b.east == -170 && b.crossesAntimeridian)
        let swapped = GeoBox(south: 10, west: 0, north: -10, east: 5)
        #expect(swapped.south == -10 && swapped.north == 10)
        #expect(GeoBox(south: 0, west: -180, north: 1, east: 180) == GeoBox(south: 0, west: -180, north: 1, east: 180))
        #expect(!GeoBox.world.crossesAntimeridian && GeoBox.world.isWorldLongitude)
        let wide = GeoBox(south: 0, west: -200, north: 1, east: 200)
        #expect(wide.isWorldLongitude)
        #expect(GeoBox.wrapLongitude(180) == 180 && GeoBox.wrapLongitude(190) == -170 && GeoBox.wrapLongitude(-540) == -180)
    }

    @Test("GeoBox from a center and span")
    func centerSpan() {
        let us = MapModel.initialRegion
        #expect(us == GeoBox(south: 17.5, west: -135, north: 62.5, east: -65))
        let fiji = GeoBox(center: GeoCoordinate(latitude: -18, longitude: 178), latitudeDelta: 10, longitudeDelta: 10)
        #expect(fiji.crossesAntimeridian && near(fiji.west, 173) && near(fiji.east, -177))
        #expect(near(fiji.longitudeSpan, 10) && near(fiji.center.longitude, 178))
        let all = GeoBox(center: GeoCoordinate(latitude: 0, longitude: 50), latitudeDelta: 400, longitudeDelta: 360)
        #expect(all == .world)
    }

    @Test("split: two halves for a crossing box, else itself")
    func split() {
        let box = GeoBox(south: -30, west: 170, north: 0, east: -160)
        #expect(box.split() == [GeoBox(south: -30, west: 170, north: 0, east: 180),
                                GeoBox(south: -30, west: -180, north: 0, east: -160)])
        #expect(PlaceFixture.usBox.split() == [PlaceFixture.usBox])
    }

    @Test("padded grows each side, clamps, and reaches the world")
    func padded() {
        let p = GeoBox(south: 40, west: -110, north: 50, east: -100).padded(by: 0.5)
        #expect(p == GeoBox(south: 35, west: -115, north: 55, east: -95))
        let tall = GeoBox(south: 0, west: 0, north: 80, east: 10).padded(by: 0.5)
        #expect(tall.north == 90 && tall.south == -40)
        let wide = GeoBox(south: 0, west: -100, north: 10, east: 80).padded(by: 0.5)   // 180 * 2 = 360
        #expect(wide.isWorldLongitude)
        let crossing = GeoBox(south: 0, west: 175, north: 10, east: -175).padded(by: 0.5)
        #expect(crossing.crossesAntimeridian && near(crossing.west, 170) && near(crossing.east, -170))
        let edge = GeoBox(south: 0, west: 160, north: 10, east: 175).padded(by: 0.5)   // grows over 180
        #expect(edge.crossesAntimeridian && near(edge.west, 152.5) && near(edge.east, -177.5))
        #expect(GeoBox.world.padded(by: 0.5) == .world)
    }

    @Test("contains boxes and coordinates, including crossing boxes")
    func contains() {
        let us = PlaceFixture.usBox
        #expect(us.contains(GeoBox(south: 44.3, west: -116.1, north: 49.1, east: -104)))
        #expect(!us.contains(GeoBox(south: 44, west: -130, north: 49, east: -104)))
        #expect(!us.contains(GeoBox(south: 20, west: -116, north: 49, east: -104)))
        #expect(GeoBox.world.contains(us) && !us.contains(.world))
        let crossing = GeoBox(south: -30, west: 170, north: 0, east: -160)
        #expect(crossing.contains(GeoBox(south: -20, west: 175, north: -10, east: -170)))
        #expect(crossing.contains(GeoBox(south: -20, west: -175, north: -10, east: -165)))
        #expect(crossing.contains(GeoBox(south: -20, west: 171, north: -10, east: 179)))
        #expect(!crossing.contains(GeoBox(south: -20, west: 160, north: -10, east: 175)))
        #expect(!us.contains(crossing))
        #expect(crossing.contains(GeoCoordinate(latitude: -18.14, longitude: 178.44)))
        #expect(crossing.contains(GeoCoordinate(latitude: -13.83, longitude: -171.77)))
        #expect(!crossing.contains(GeoCoordinate(latitude: -13.83, longitude: 0)))
        #expect(us.contains(PlaceFixture.montana) && !us.contains(GeoCoordinate(latitude: 51.5, longitude: -0.1)))
    }

    @Test("PinTier boundaries")
    func tiers() {
        #expect(PinTier(books: 0) == .birthplace)
        #expect(PinTier(books: 1) == .one)
        #expect(PinTier(books: 2) == .few)
        #expect(PinTier(books: 4) == .few)
        #expect(PinTier(books: 5) == .several)
        #expect(PinTier(books: 14) == .several)
        #expect(PinTier(books: 15) == .many)
        #expect(PinTier.birthplace < .many)
        #expect(PlaceText.books(1) == "1 book" && PlaceText.places(2) == "2 places")
    }
}

@MainActor
@Suite("Map model")
struct MapModelTests {
    static func model(debounce: Duration = .milliseconds(20)) async throws -> (MapModel, UserDataController, GraphStore) {
        let store = try await PlaceFixture.store()
        let controller = UserDataController(store: store)
        let model = MapModel(store: store, userData: controller)
        model.regionDebounce = debounce
        model.searchDebounce = debounce
        return (model, controller, store)
    }

    @Test("launch options: --open-tab map and --map-place")
    func launch() {
        #expect(LaunchOptions.parse(["app", "--open-tab", "map"]).initialTab == .map)
        let place = LaunchOptions.parse(["app", "--map-place", "Montana"])
        #expect(place.mapPlace == "Montana" && place.initialTab == .map)
        let library = LaunchOptions.parse(["app", "--open-tab", "library", "--map-place", "Montana"])
        #expect(library.initialTab == .library && library.mapPlace == "Montana")
        let missing = LaunchOptions.parse(["app", "--map-place"])
        #expect(missing.mapPlace == nil && missing.initialTab == nil)
        let empty = LaunchOptions.parse(["app", "--map-place", "", "--open-book", "/works/OL1W"])
        #expect(empty.mapPlace == nil && empty.routes == [.book(key: "/works/OL1W")])
        #expect(AppTab.allCases == [.library, .tags, .search, .map])
    }

    @Test("start fetches the padded initial region once")
    func start() async throws {
        let (model, _, _) = try await Self.model()
        #expect(!model.hasLoaded && !model.showsEmptyState)
        await model.start()
        #expect(model.queryCount == 1 && model.hasLoaded && !model.isLoading)
        #expect(model.fetchedBox == MapModel.initialRegion.padded(by: 0.5))
        #expect(Set(model.pins.map(\.label)) == ["United States", "Montana", "Butte"])
        #expect(model.countText == "3 places in view")
        await model.start()
        #expect(model.queryCount == 1)
    }

    @Test("debounce: rapid region changes outside the fetched box run one query, for the last box")
    func debounce() async throws {
        let (model, _, _) = try await Self.model()
        await model.start()
        let before = model.queryCount
        model.regionDidChange(GeoBox(south: 40, west: 0, north: 50, east: 10))        // Europe
        model.regionDidChange(GeoBox(south: 30, west: 130, north: 40, east: 145))     // Japan
        model.regionDidChange(GeoBox(south: -25, west: 170, north: -10, east: -165))  // Fiji/Samoa
        await model.settle()
        #expect(model.queryCount == before + 1)
        #expect(Set(model.pinsInView.map(\.label)) == ["Suva", "Apia"])
        #expect(model.countText == "2 places in view")
    }

    @Test("padding: a box inside the fetched one makes no query")
    func padding() async throws {
        let (model, _, _) = try await Self.model()
        await model.start()
        let before = model.queryCount
        model.regionDidChange(GeoBox(south: 44.3, west: -116.1, north: 49.1, east: -104))
        await model.settle()
        #expect(model.queryCount == before)
        #expect(Set(model.pinsInView.map(\.label)) == ["Montana", "Butte"])
        #expect(model.countText == "2 places in view")
    }

    @Test("zooming back inside the fetched box cancels a pending fetch")
    func cancelPending() async throws {
        let (model, _, _) = try await Self.model(debounce: .milliseconds(200))
        await model.start()
        let before = model.queryCount
        model.regionDidChange(GeoBox(south: 40, west: 0, north: 50, east: 10))
        #expect(model.isLoading == false)
        model.regionDidChange(GeoBox(south: 44.3, west: -116.1, north: 49.1, east: -104))
        await model.settle()
        #expect(model.queryCount == before)
        #expect(model.fetchedBox == MapModel.initialRegion.padded(by: 0.5))
    }

    @Test("birthplace toggle filters locally")
    func birthplaces() async throws {
        let (model, _, _) = try await Self.model()
        await model.start()
        model.regionDidChange(.world)
        await model.settle()
        let queries = model.queryCount
        #expect(model.pins.count == 7)
        #expect(!model.displayedPins.contains { $0.label == "Tokyo" })
        #expect(model.countText == "6 places in view")
        model.showsBirthplaces = true
        #expect(model.displayedPins.contains { $0.label == "Tokyo" })
        #expect(model.countText == "7 places in view")
        #expect(model.queryCount == queries)
    }

    @Test("empty state: an empty box inside the fetched one")
    func emptyState() async throws {
        let (model, _, _) = try await Self.model()
        await model.start()
        model.regionDidChange(GeoBox(south: 30, west: -40, north: 31, east: -39))
        await model.settle()
        #expect(model.showsEmptyState)
        #expect(model.countText == "No places in view")
        model.regionDidChange(GeoBox(south: 46, west: -113, north: 47, east: -112))   // Butte
        #expect(model.countText == "1 place in view")
    }

    @Test("focus: resolves, flies and opens the sheet; unknown places set a message")
    func focus() async throws {
        let (model, _, _) = try await Self.model()
        await model.focus(on: "USA")
        let focus = try #require(model.focus)
        #expect(focus.center == PlaceFixture.unitedStates)
        #expect(focus.latitudeDelta == MapModel.focusSpan && focus.longitudeDelta == MapModel.focusSpan)
        #expect(model.sheet?.label == "United States")
        model.focusHandled(focus.id + 1)
        #expect(model.focus != nil)
        model.focusHandled(focus.id)
        #expect(model.focus == nil)
        model.deselect()
        await model.focus(on: "Gethen")
        #expect(model.message == "“Gethen” is not on the map")
        #expect(model.sheet == nil && model.focus == nil)
        model.clearMessage()
        #expect(model.message == nil)
    }

    @Test("select keeps the same sheet for the same label")
    func select() async throws {
        let (model, _, _) = try await Self.model()
        model.select(label: "Montana")
        let first = try #require(model.sheet)
        model.select(label: "Montana")
        #expect(model.sheet === first)
        model.select(label: "Butte")
        #expect(model.sheet?.label == "Butte" && model.sheet !== first)
    }

    @Test("search is debounced, needs 2 characters, and choose flies to the result")
    func search() async throws {
        let (model, _, _) = try await Self.model()
        model.setSearchText("m")
        #expect(!model.isSearching && model.searchResults.isEmpty && !model.showsNoSearchMatches)
        model.setSearchText("mo")
        model.setSearchText("mon")
        model.setSearchText("mont")
        #expect(model.isSearching)
        await model.settle()
        #expect(model.searchCount == 1)
        #expect(model.searchResults.first?.label == "Montana")
        model.setSearchText("zzz")
        await model.settle()
        #expect(model.searchResults.isEmpty && model.showsNoSearchMatches)
        model.setSearchText("lond")
        await model.settle()
        let london = try #require(model.searchResults.first)
        model.choose(london)
        #expect(model.sheet?.label == "London")
        #expect(model.focus?.center == london.coordinate)
        #expect(model.searchText == "" && model.searchResults.isEmpty)
    }

    @Test("place sheet loads its books and header; a status change patches its row")
    func sheet() async throws {
        let (_, controller, store) = try await Self.model()
        let sheet = PlaceSheetModel(label: "Montana", store: store, userData: controller)
        await sheet.load()
        #expect(sheet.books.books.map(\.key) == ["/works/M2", "/works/M3", "/works/M1"])
        #expect(sheet.summary?.bookCount == 3 && sheet.hasLoadedSummary && sheet.authors.isEmpty)
        _ = try await controller.setStatus(key: "/works/M1", to: .reading)
        #expect(sheet.books.books.first { $0.key == "/works/M1" }?.status == .reading)
        let london = PlaceSheetModel(label: "London", store: store)
        await london.load()
        #expect(london.authors.count == 2 && london.books.books.count == 1)
        let nowhere = PlaceSheetModel(label: "Nowhere", store: store)
        await nowhere.load()
        #expect(nowhere.summary == nil && nowhere.hasLoadedSummary && nowhere.books.books.isEmpty)
    }

    @Test("term pages know whether a place is on the map")
    func termPlaceLocation() async throws {
        let store = try await PlaceFixture.store()
        let montana = TermModel(kind: .place, name: "Montana", store: store)
        await montana.load()
        #expect(montana.placeLocation?.isOnMap == true && montana.placeLocation?.label == "Montana")
        let gethen = TermModel(kind: .place, name: "Gethen", store: store)
        await gethen.load()
        #expect(gethen.placeLocation?.isOnMap == false)
        #expect(gethen.placeLocation?.notOnMapReason == "Not on the map: fictional or not a real place")
        let subject = TermModel(kind: .subject, name: "Montana", store: store)
        await subject.load()
        #expect(subject.placeLocation == nil)
    }

    @Test("AppSession builds the map model")
    func session() async throws {
        let store = try await PlaceFixture.store()
        let session = AppSession(store: store)
        await session.map.start()
        #expect(session.map.hasLoaded)
    }
}
