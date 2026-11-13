import Testing
import Foundation
import Relate
@testable import RelateBooksCore

@Suite("Place locator")
struct PlaceLocatorTests {
    static let newPlaces = ["Gloucester (Mass.)", "North Atlantic Ocean", "Appalachia", "Portland (Me.)", "Killick-Claw",
                            "Epsilon Eridani", "Salinas River Valley (Calif.)", "Gulf Stream", "Cuba"]

    static func store() async throws -> GraphStore {
        let store = try await GraphStore.inMemory()
        try await store.query("UNWIND $names AS name CREATE (:Place {name: name})",
                              ["names": .list(newPlaces.map(CypherValue.string))])
        try await store.query("""
            CREATE (:Place {name: 'Appalachian region', geocoded_label: 'Appalachia', geo_status: 'ok',
                            location: point({latitude: 37.5, longitude: -81.5})})
            CREATE (:Place {name: 'Portland', geocoded_label: 'Portland', geo_status: 'ok',
                            location: point({latitude: 45.5202, longitude: -122.6742})})
            CREATE (:Place {name: 'Portland (Or.)', geocoded_label: 'Portland', geo_status: 'ok',
                            location: point({latitude: 45.5202, longitude: -122.6742})})
            """)
        return store
    }

    static var table: [String: [GeocodeCandidate]] {
        var t = StubPlaceGeocoder.fixtureTable
        t["Appalachia"] = [GeocodeCandidate(coordinate: GeoCoordinate(latitude: 37.5003, longitude: -81.5004), name: "Appalachia")]
        t["Portland, Maine"] = [GeocodeCandidate(coordinate: GeoCoordinate(latitude: 43.6591, longitude: -70.2568), locality: "Portland",
                                                 administrativeArea: "Maine", country: "United States")]
        t["Salinas River Valley, California"] = []
        t["Salinas River, California"] = [GeocodeCandidate(coordinate: GeoCoordinate(latitude: 36.6, longitude: -121.6),
                                                           name: "Salinas River Valley", inlandWater: "Salinas River")]
        t["Gulf Stream"] = [GeocodeCandidate(coordinate: GeoCoordinate(latitude: 30, longitude: -75), name: "Killick Road")]
        return t
    }

    static func geocoder(delay: Duration = .zero) -> StubPlaceGeocoder {
        StubPlaceGeocoder(table: table, delay: delay, errors: ["Cuba": URLError(.notConnectedToInternet)])
    }

    static func props(_ store: GraphStore, _ name: String) async throws -> Row {
        try await store.query("""
            MATCH (p:Place {name: $name})
            RETURN p.location AS location, p.geocoded_label AS label, p.geo_source AS source, p.geo_status AS status,
                   p.geo_lat AS lat, p.geo_lon AS lon, p.geo_display_name AS display, p.geo_place_type AS type,
                   p.geo_query AS query, p.geo_region AS region, p.geo_reason AS reason
            """, ["name": .string(name)]).rowsView[0]
    }

    @Test("Gloucester: a new label and all ten properties")
    func gloucester() async throws {
        let store = try await Self.store()
        let locator = PlaceLocator(store: store, geocoder: Self.geocoder())
        let outcome = await locator.locate(name: "Gloucester (Mass.)")
        #expect(outcome == .located(name: "Gloucester (Mass.)", label: "Gloucester",
                                    coordinate: GeoCoordinate(latitude: 42.6159, longitude: -70.6620), reusedLabel: false))
        let p = try await Self.props(store, "Gloucester (Mass.)")
        #expect(p.point("location") == GeoCoordinate(latitude: 42.6159, longitude: -70.6620))
        #expect(p.string("label") == "Gloucester" && p.string("source") == "stub" && p.string("status") == "ok")
        #expect(p.double("lat") == 42.6159 && p.double("lon") == -70.6620)
        #expect(p.string("display") == "Gloucester, Massachusetts, United States" && p.string("type") == "locality")
        #expect(p.string("query") == "Gloucester, Massachusetts" && p.string("region") == "Massachusetts" && p["reason"] == .null)
        let ocean = await locator.locate(name: "North Atlantic Ocean")
        #expect(ocean.label == "North Atlantic Ocean")
        let o = try await Self.props(store, "North Atlantic Ocean")
        #expect(o.string("type") == "ocean" && o["region"] == .null && o.point("location") == GeoCoordinate(latitude: 40, longitude: -45))
    }

    @Test("within 1 km of a located place: its label and its point are reused")
    func reuse() async throws {
        let store = try await Self.store()
        let outcome = await PlaceLocator(store: store, geocoder: Self.geocoder()).locate(name: "Appalachia")
        #expect(outcome == .located(name: "Appalachia", label: "Appalachia", coordinate: GeoCoordinate(latitude: 37.5, longitude: -81.5),
                                    reusedLabel: true))
        let p = try await Self.props(store, "Appalachia")
        #expect(p.point("location") == GeoCoordinate(latitude: 37.5, longitude: -81.5))
        #expect(p.double("lat") == 37.5003 && p.double("lon") == -81.5004)
    }

    @Test("a label taken far away gets the qualifier, then coordinates")
    func collisions() async throws {
        let store = try await Self.store()
        let locator = PlaceLocator(store: store, geocoder: Self.geocoder())
        #expect(await locator.locate(name: "Portland (Me.)").label == "Portland, Maine")

        let other = try await Self.store()
        try await other.query("""
            CREATE (:Place {name: 'Portland, Maine (old)', geocoded_label: 'Portland, Maine', geo_status: 'ok',
                            location: point({latitude: 10, longitude: 10})})
            """)
        #expect(await PlaceLocator(store: other, geocoder: Self.geocoder()).locate(name: "Portland (Me.)").label
                == "Portland, Maine (43.66, -70.26)")
    }

    @Test("fallback query, failures and skips")
    func failures() async throws {
        let store = try await Self.store()
        let geocoder = Self.geocoder()
        let locator = PlaceLocator(store: store, geocoder: geocoder)
        #expect(await locator.locate(name: "Salinas River Valley (Calif.)").label == "Salinas River Valley")
        #expect(try await Self.props(store, "Salinas River Valley (Calif.)").string("query") == "Salinas River, California")

        #expect(await locator.locate(name: "Killick-Claw") == .unresolved(name: "Killick-Claw", reason: "no result"))
        #expect(await locator.locate(name: "Gulf Stream") == .unresolved(name: "Gulf Stream", reason: "no matching result"))
        guard case .unresolved(_, let reason) = await locator.locate(name: "Cuba") else {
            Issue.record("Cuba should be unresolved"); return
        }
        #expect(reason.hasPrefix("geocoder error: "))
        #expect(await locator.locate(name: "Epsilon Eridani") == .skipped(name: "Epsilon Eridani", reason: "non-terrestrial"))
        #expect(!(await geocoder.queries).contains { $0.contains("Eridani") })

        let killick = try await Self.props(store, "Killick-Claw")
        #expect(killick.string("status") == "unresolved" && killick.string("reason") == "no result" && killick["location"] == .null)
        #expect(killick.string("query") == "Killick-Claw")
        let eridani = try await Self.props(store, "Epsilon Eridani")
        #expect(eridani.string("status") == "skipped" && eridani.string("reason") == "non-terrestrial" && eridani["query"] == .null)
        #expect(try await store.placeLocation(name: "Epsilon Eridani").notOnMapReason == "Not on the map: fictional or not a real place")
    }

    @Test("a slow geocoder times out")
    func timeout() async throws {
        let store = try await Self.store()
        var locator = PlaceLocator(store: store, geocoder: Self.geocoder(delay: .milliseconds(200)))
        locator.requestTimeout = .milliseconds(50)
        #expect(await locator.locate(name: "Gloucester (Mass.)") == .unresolved(name: "Gloucester (Mass.)", reason: "timed out"))
        #expect(try await Self.props(store, "Gloucester (Mass.)").string("status") == "unresolved")
    }

    @Test("maxPlaces caps an import; progress counts the attempted ones")
    func cap() async throws {
        let store = try await Self.store()
        var locator = PlaceLocator(store: store, geocoder: Self.geocoder())
        locator.maxPlaces = 2
        let progress = ProgressLog()
        let outcomes = await locator.locate(["Gloucester (Mass.)", "North Atlantic Ocean", "Appalachia"]) { done, total in
            await progress.add(done, total)
        }
        #expect(outcomes.map(\.isLocated) == [true, true, false])
        #expect(outcomes[2] == .notAttempted(name: "Appalachia"))
        #expect(try await Self.props(store, "Appalachia")["status"] == .null)
        #expect(await progress.values == [[1, 2], [2, 2]])
    }

    actor ProgressLog {
        var values: [[Int]] = []
        func add(_ done: Int, _ total: Int) { values.append([done, total]) }
    }

    @Test("an already located place is left unchanged")
    func alreadyLocated() async throws {
        let store = try await Self.store()
        try await store.query("MATCH (p:Place {name: 'Gloucester (Mass.)'}) SET p.location = point({latitude: 1, longitude: 2}), p.geocoded_label = 'Mine'")
        #expect(await PlaceLocator(store: store, geocoder: Self.geocoder()).locate(name: "Gloucester (Mass.)")
                == .unresolved(name: "Gloucester (Mass.)", reason: "already located"))
        let p = try await Self.props(store, "Gloucester (Mass.)")
        #expect(p.string("label") == "Mine" && p["status"] == .null && p.point("location") == GeoCoordinate(latitude: 1, longitude: 2))
        // Bundled places are never touched by a failure write either.
        #expect(try await store.writePlaceFailed(name: "Portland", status: "unresolved", query: nil, reason: "x") == false)
    }

    @Test("the new pin shows on the map with its book")
    func onTheMap() async throws {
        let store = try await Self.store()
        try await store.query("MATCH (p:Place {name: 'Gloucester (Mass.)'}) CREATE (:Book {key: '/works/OLX1W', title: 'Storm'})-[:SET_IN]->(p)")
        _ = await PlaceLocator(store: store, geocoder: Self.geocoder()).locate(name: "Gloucester (Mass.)")
        let pins = try await store.placePins(in: GeoBox(south: 41, west: -73.6, north: 43, east: -69.8))
        #expect(pins.first { $0.label == "Gloucester" }?.books == 1)
        #expect(try await store.placeLocation(name: "Gloucester (Mass.)").isOnMap)
    }

    @Test("geocoding is serial across imports, also through copies of the locator (D13)")
    func serial() async throws {
        let store = try await Self.store()
        let geocoder = Self.geocoder(delay: .milliseconds(50))
        let locator = PlaceLocator(store: store, geocoder: geocoder)
        let copy = locator
        async let a = locator.locate(["Gloucester (Mass.)", "Appalachia"])
        async let b = copy.locate(["North Atlantic Ocean", "Portland (Me.)"])
        let all = await a + b
        #expect(all.allSatisfy { $0.isLocated })
        #expect(await geocoder.maxInFlight == 1)
        #expect(await geocoder.queries.count == 4)
    }

    // MARK: Same-named labels (assign_labels' fold(label_base) merge)

    /// The bundled store's Nominatim points for these labels.
    static let california = GeoCoordinate(latitude: 36.7014631, longitude: -118.755997)
    static let newEngland = GeoCoordinate(latitude: 44.2057083, longitude: -70.7537839)
    static let russia = GeoCoordinate(latitude: 64.6863136, longitude: 97.7453061)
    static let georgiaState = GeoCoordinate(latitude: 32.3293809, longitude: -83.1137366)

    static func regionStore(newHeadings: [String]) async throws -> GraphStore {
        let store = try await GraphStore.inMemory()
        try await store.query("UNWIND $names AS name CREATE (:Place {name: name})",
                              ["names": .list(newHeadings.map(CypherValue.string))])
        for (name, label, c) in [("California", "California", california), ("New England", "New England", newEngland),
                                 ("Russia", "Russia", russia), ("Georgia", "Georgia", georgiaState)] {
            try await store.query("""
                CREATE (:Place {name: $name, geocoded_label: $label, geo_status: 'ok',
                                location: point({latitude: $lat, longitude: $lon})})
                """, ["name": .string(name), "label": .string(label), "lat": .float(c.latitude), "lon": .float(c.longitude)])
        }
        return store
    }

    static func query(_ heading: String) -> String { HeadingNormalizer.normalize(heading).query ?? heading }

    @Test("a region heading reuses the same-named label far beyond 1 km (California, Russia)")
    func regionMerge() async throws {
        let headings = ["California (U.S.)", "Russia (Federation)", "Georgia (Republic)"]
        let store = try await Self.regionStore(newHeadings: headings)
        // CLGeocoder's shapes: the state abbreviated, centres ~80 km and ~470 km from Nominatim's.
        let table: [String: [GeocodeCandidate]] = [
            Self.query("California (U.S.)"): [GeocodeCandidate(coordinate: GeoCoordinate(latitude: 37.2, longitude: -119.4),
                                                               name: "California", administrativeArea: "CA",
                                                               country: "United States", isoCountryCode: "US")],
            Self.query("Russia (Federation)"): [GeocodeCandidate(coordinate: GeoCoordinate(latitude: 61.5, longitude: 105.3),
                                                                 name: "Russia", country: "Russia", isoCountryCode: "RU")],
            Self.query("Georgia (Republic)"): [GeocodeCandidate(coordinate: GeoCoordinate(latitude: 42.3, longitude: 43.4),
                                                                name: "Georgia", country: "Georgia", isoCountryCode: "GE")],
        ]
        let locator = PlaceLocator(store: store, geocoder: StubPlaceGeocoder(table: table))
        #expect(await locator.locate(name: "California (U.S.)")
                == .located(name: "California (U.S.)", label: "California", coordinate: Self.california, reusedLabel: true))
        let ca = try await Self.props(store, "California (U.S.)")
        #expect(ca.string("region") == "California" && ca.string("display") == "California, United States")
        #expect(ca.double("lat") == 37.2 && ca.point("location") == Self.california)
        #expect(await locator.locate(name: "Russia (Federation)")
                == .located(name: "Russia (Federation)", label: "Russia", coordinate: Self.russia, reusedLabel: true))
        // Same name, ~10,000 km away: a different place, so its own label and pin.
        let georgia = await locator.locate(name: "Georgia (Republic)")
        #expect(georgia.label != "Georgia" && georgia.label?.hasPrefix("Georgia") == true)
        #expect(try await Self.props(store, "Georgia (Republic)").point("location") == GeoCoordinate(latitude: 42.3, longitude: 43.4))
        // One label still keeps one point.
        let points = try await store.query("""
            MATCH (p:Place) WHERE p.geocoded_label IN ['California', 'Russia']
            RETURN p.geocoded_label AS label, count(DISTINCT p.location) AS points
            """).rowsView
        #expect(points.count == 2 && points.allSatisfy { $0.int("points") == 1 })
    }

    @Test("a same-named label is matched ignoring case and accents, within 50 km for a non-region")
    func foldedSameName() async throws {
        let store = try await Self.regionStore(newHeadings: ["new england", "Springfield (Mass.)"])
        try await store.query("""
            CREATE (:Place {name: 'Springfield (Ill.)', geocoded_label: 'Springfield', geo_status: 'ok',
                            location: point({latitude: 39.7990, longitude: -89.6440})})
            """)
        let table: [String: [GeocodeCandidate]] = [
            // ~30 km from the stored point: Apple and Nominatim disagree on a region's centre.
            Self.query("new england"): [GeocodeCandidate(coordinate: GeoCoordinate(latitude: 43.95, longitude: -70.6),
                                                         name: "New England", country: "United States", isoCountryCode: "US")],
            Self.query("Springfield (Mass.)"): [GeocodeCandidate(coordinate: GeoCoordinate(latitude: 42.1015, longitude: -72.5898),
                                                                 name: "Springfield", locality: "Springfield",
                                                                 administrativeArea: "MA", country: "United States",
                                                                 isoCountryCode: "US")],
        ]
        let locator = PlaceLocator(store: store, geocoder: StubPlaceGeocoder(table: table))
        #expect(await locator.locate(name: "new england")
                == .located(name: "new england", label: "New England", coordinate: Self.newEngland, reusedLabel: true))
        // A same-named city ~1,300 km away is somewhere else: the full state name is the suffix.
        #expect(await locator.locate(name: "Springfield (Mass.)").label == "Springfield, Massachusetts")
        #expect(try await Self.props(store, "Springfield (Mass.)").string("region") == "Massachusetts")
    }

    @Test("resolveLabel: fold match, radius, suffix and coordinates (pure)")
    func resolveLabel() {
        let here = GeoCoordinate(latitude: 10, longitude: 10)
        let near = GeoCoordinate(latitude: 10.2, longitude: 10)   // ~22 km
        let far = GeoCoordinate(latitude: 20, longitude: 10)      // ~1,100 km
        let r = PlaceMatch.sameNameRadiusMeters
        let hit = PlaceMatch.resolveLabel(preferred: "Zürich", suffixed: "Zürich, X", at: here, radius: r,
                                          existing: [LocatedLabel(label: "zurich", coordinate: near)])
        #expect(hit.label == "zurich" && hit.coordinate == near && hit.reused)
        let free = PlaceMatch.resolveLabel(preferred: "Zürich", suffixed: "Zürich, X", at: here, radius: r, existing: [])
        #expect(free.label == "Zürich" && free.coordinate == here && !free.reused)
        let taken = PlaceMatch.resolveLabel(preferred: "Zürich", suffixed: "Zürich, X", at: here, radius: r,
                                            existing: [LocatedLabel(label: "ZURICH", coordinate: far)])
        #expect(taken.label == "Zürich, X" && !taken.reused)
        let suffixNear = PlaceMatch.resolveLabel(preferred: "Zürich", suffixed: "Zürich, X", at: here, radius: r,
                                                 existing: [LocatedLabel(label: "Zürich", coordinate: far),
                                                            LocatedLabel(label: "zürich, x", coordinate: near)])
        #expect(suffixNear.label == "zürich, x" && suffixNear.reused)
        let both = PlaceMatch.resolveLabel(preferred: "Zürich", suffixed: "Zürich, X", at: here, radius: r,
                                           existing: [LocatedLabel(label: "Zürich", coordinate: far),
                                                      LocatedLabel(label: "Zürich, x", coordinate: far)])
        #expect(both.label == "Zürich, X (10.00, 10.00)" && !both.reused)
        #expect(abs(here.distanceMeters(to: near) - 22_239) < 50)
    }

    @Test("US and Canadian abbreviations are spelled out; others are left alone")
    func regionNames() {
        let origin = GeoCoordinate(latitude: 0, longitude: 0)
        func area(_ a: String, _ iso: String?, _ country: String? = nil) -> String? {
            GeocodeCandidate(coordinate: origin, administrativeArea: a, country: country, isoCountryCode: iso)
                .expandingRegionAbbreviation().administrativeArea
        }
        #expect(area("MA", "US") == "Massachusetts" && area("FL", "us") == "Florida" && area("DC", "US") == "District of Columbia")
        #expect(area("QC", "CA") == "Quebec" && area("BC", nil, "Canada") == "British Columbia")
        #expect(area("CA", nil, "United States") == "California")
        #expect(area("Massachusetts", "US") == "Massachusetts" && area("ZZ", "US") == "ZZ" && area("NY", "AU") == "NY")
    }
}
