import Relate

/// Cypher for the Map tab, the place sheet and "Show on map" (phase 4).
///
/// The store's `Place` nodes carry `location` (a WGS-84 point) and
/// `geocoded_label` from `wishlist-to-graph --geocode`. Every node that
/// shares a label carries the same point, so one label is one pin, and
/// counts are DISTINCT books and authors across the label's nodes (summing
/// per-node counts would count Olympic National Park's 5 books twice).
///
/// Values are always parameters. Box corners are four Double parameters
/// built into `point({latitude:…, longitude:…})`, the shape verified to use
/// the POINT INDEX `place_location`; label lookups use the RANGE index
/// `place_label`.
enum PlaceQueries {
    static let searchLimit = 20
    static let minimumSearchLength = 2

    /// One row per label inside `box`: `label, location, books, authors,
    /// placeNames`, most books first. The caller passes each half of
    /// `box.split()` (see `GeoBox.split()` for why).
    static func region(_ box: GeoBox) -> Statement {
        precondition(!box.crossesAntimeridian, "split a box that crosses the antimeridian first")
        return Statement("""
            MATCH (p:Place)
            WHERE point.withinBBox(p.location, point({latitude: $south, longitude: $west}), point({latitude: $north, longitude: $east}))
            OPTIONAL MATCH (b:Book)-[:SET_IN]->(p)
            WITH p.geocoded_label AS label, collect(DISTINCT p) AS places, count(DISTINCT b) AS books
            UNWIND places AS q
            OPTIONAL MATCH (a:Author)-[:BORN_IN]->(q)
            WITH label, places, books, count(DISTINCT a) AS authors
            RETURN label, places[0].location AS location, books, authors,
                   [x IN places | x.name] AS placeNames
            ORDER BY books DESC, authors DESC, label
            """, [
                "south": .float(box.south), "west": .float(box.west),
                "north": .float(box.north), "east": .float(box.east),
            ])
    }

    /// Located labels whose label or any heading contains `text`
    /// (case-insensitive); labels starting with the text first.
    static func search(_ text: String, limit: Int = searchLimit) -> Statement {
        Statement("""
            MATCH (p:Place)
            WHERE p.location IS NOT NULL
              AND (toLower(p.name) CONTAINS toLower($q) OR toLower(p.geocoded_label) CONTAINS toLower($q))
            WITH DISTINCT p.geocoded_label AS label
            MATCH (p:Place {geocoded_label: label})
            OPTIONAL MATCH (b:Book)-[:SET_IN]->(p)
            WITH label, collect(DISTINCT p) AS places, count(DISTINCT b) AS books
            UNWIND places AS q
            OPTIONAL MATCH (a:Author)-[:BORN_IN]->(q)
            WITH label, places, books, count(DISTINCT a) AS authors
            RETURN label, places[0].location AS location, books, authors, [x IN places | x.name] AS placeNames
            ORDER BY toLower(label) STARTS WITH toLower($q) DESC, books DESC, authors DESC, label
            LIMIT $limit
            """, ["q": .string(text), "limit": CypherValue(max(0, limit))])
    }

    /// The sheet header: no row when no node has the label.
    static func summary(label: String) -> Statement {
        Statement("""
            MATCH (p:Place {geocoded_label: $label})
            WITH collect(p) AS places
            WHERE size(places) > 0
            RETURN places[0].location AS location,
                   [x IN places | x.name] AS placeNames,
                   COUNT { MATCH (b:Book)-[:SET_IN]->(x:Place {geocoded_label: $label}) RETURN DISTINCT b } AS books,
                   COUNT { MATCH (a:Author)-[:BORN_IN]->(x:Place {geocoded_label: $label}) RETURN DISTINCT a } AS authors
            """, ["label": .string(label)])
    }

    /// Books set in any node with the label, title order (as term pages),
    /// `BookSummary` columns.
    static func books(label: String, skip: Int, limit: Int = LibraryQueries.pageSize) -> Statement {
        Statement("""
            MATCH (b:Book)-[:SET_IN]->(:Place {geocoded_label: $label})
            WITH DISTINCT b
            WITH b, toLower(coalesce(b.title, b.key)) AS sortKey
            \(TermQueries.order)
            SKIP $skip LIMIT $limit
            \(LibraryQueries.summaryProjection())
            \(TermQueries.order)
            """, ["label": .string(label), "skip": CypherValue(max(0, skip)), "limit": CypherValue(max(0, limit))])
    }

    /// Authors born in any node with the label, by book count then name.
    static func authors(label: String) -> Statement {
        Statement("""
            MATCH (a:Author)-[:BORN_IN]->(:Place {geocoded_label: $label})
            WITH DISTINCT a
            RETURN a.key AS key, a.name AS name, COUNT { MATCH (a)<-[:WRITTEN_BY]-(:Book) } AS bookCount
            ORDER BY bookCount DESC, toLower(a.name), a.key
            """, ["label": .string(label)])
    }

    /// A label or a heading (case-insensitive) to its located label; an
    /// exact label match wins, then an exact heading match.
    static func resolve(_ text: String) -> Statement {
        Statement("""
            MATCH (p:Place)
            WHERE p.location IS NOT NULL
              AND (toLower(p.geocoded_label) = toLower($q) OR toLower(p.name) = toLower($q))
            RETURN p.geocoded_label AS label, p.location AS location
            ORDER BY p.geocoded_label = $q DESC, p.name = $q DESC, toLower(p.geocoded_label) = toLower($q) DESC
            LIMIT 1
            """, ["q": .string(text)])
    }

    /// One heading's map status (term page "Show on map").
    static func location(name: String) -> Statement {
        Statement("""
            MATCH (p:Place {name: $name})
            RETURN p.geocoded_label AS label, p.location AS location, p.geo_status AS status
            """, ["name": .string(name)])
    }

    /// Labels within `radiusMeters` of `center`, nearest first (Haversine,
    /// R = 6,378,140 m in Relate). Served by the point index.
    static func nearMe(_ center: GeoCoordinate, radiusMeters: Double, limit: Int = 20) -> Statement {
        Statement("""
            MATCH (p:Place)
            WHERE point.distance(p.location, point({latitude: $lat, longitude: $lon})) < $radius
            WITH p.geocoded_label AS label, collect(p) AS places,
                 min(point.distance(p.location, point({latitude: $lat, longitude: $lon}))) AS meters
            RETURN label, places[0].location AS location, toInteger(meters) AS meters, [x IN places | x.name] AS placeNames
            ORDER BY meters, label
            LIMIT $limit
            """, [
                "lat": .float(center.latitude), "lon": .float(center.longitude),
                "radius": .float(radiusMeters), "limit": CypherValue(max(0, limit)),
            ])
    }

    /// `PERF`/guard helper: how many Place nodes have a location.
    static let locatedCount = "MATCH (p:Place) WHERE p.location IS NOT NULL RETURN count(p) AS count"
}

extension GraphStore {
    /// Pins inside `box`: one region query per `box.split()` half, merged by
    /// label (a label sits at one point, so a duplicate keeps the first),
    /// sorted by books, then authors, then label. Rows without a label or a
    /// valid point are skipped.
    func placePins(in box: GeoBox) throws -> [PlacePin] {
        var seen: Set<String> = []
        var pins: [PlacePin] = []
        for part in box.split() {
            for row in try run(PlaceQueries.region(part), label: "placePins").rowsView {
                guard let pin = try? PlacePin(row: row) else { continue }
                if seen.insert(pin.label).inserted { pins.append(pin) }
            }
        }
        return pins.sorted(by: Self.pinOrder)
    }

    /// Located labels matching `text`; `[]` (no query) when the trimmed text
    /// is shorter than 2 characters.
    func searchPlaces(_ text: String, limit: Int = PlaceQueries.searchLimit) throws -> [PlacePin] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= PlaceQueries.minimumSearchLength else { return [] }
        return try run(PlaceQueries.search(query, limit: limit), label: "searchPlaces")
            .rowsView.compactMap { try? PlacePin(row: $0) }
    }

    /// nil when no node has the label (or it has no valid point).
    func placeSummary(label: String) throws -> PlaceSummary? {
        guard let row = try run(PlaceQueries.summary(label: label), label: "placeSummary").rowsView.first,
              let coordinate = row.point("location") else { return nil }
        return PlaceSummary(label: label, coordinate: coordinate, bookCount: row.int("books") ?? 0,
                            authorCount: row.int("authors") ?? 0, placeNames: row.strings("placeNames").sorted())
    }

    func placeBooks(label: String, skip: Int = 0, limit: Int = LibraryQueries.pageSize) throws -> [BookSummary] {
        try run(PlaceQueries.books(label: label, skip: skip, limit: limit), label: "placeBooks")
            .rowsView.map(BookSummary.init(row:))
    }

    func placeAuthors(label: String) throws -> [AuthorSummary] {
        try run(PlaceQueries.authors(label: label), label: "placeAuthors").rowsView.map(AuthorSummary.init(row:))
    }

    /// A label or heading (case-insensitive) to its pin's label and point;
    /// nil when it is not on the map.
    func resolvePlace(_ text: String) throws -> (label: String, coordinate: GeoCoordinate)? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              let row = try run(PlaceQueries.resolve(query), label: "resolvePlace").rowsView.first,
              let label = row.string("label"), let coordinate = row.point("location") else { return nil }
        return (label, coordinate)
    }

    /// The heading's map status; an unknown heading has every field nil.
    func placeLocation(name: String) throws -> PlaceLocation {
        let row = try run(PlaceQueries.location(name: name), label: "placeLocation").rowsView.first
        return PlaceLocation(name: name, label: row?.string("label"), coordinate: row?.point("location"),
                             status: row?.string("status"))
    }

    /// Labels near `center` (phase 4: core and tests only).
    func placesNear(_ center: GeoCoordinate, radiusMeters: Double, limit: Int = 20) throws -> [NearbyPlace] {
        try run(PlaceQueries.nearMe(center, radiusMeters: radiusMeters, limit: limit), label: "placesNear")
            .rowsView.compactMap { row in
                guard let label = row.string("label"), let coordinate = row.point("location") else { return nil }
                return NearbyPlace(label: label, coordinate: coordinate, meters: row.int("meters") ?? 0,
                                   placeNames: row.strings("placeNames").sorted())
            }
    }

    func locatedPlaceCount() throws -> Int {
        Int(try run(Statement(PlaceQueries.locatedCount), label: "locatedPlaceCount").scalar().intValue ?? 0)
    }

    nonisolated static func pinOrder(_ a: PlacePin, _ b: PlacePin) -> Bool {
        if a.books != b.books { return a.books > b.books }
        if a.authors != b.authors { return a.authors > b.authors }
        return a.label < b.label
    }
}
