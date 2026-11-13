import Foundation

/// A WGS-84 latitude/longitude pair. Core never imports MapKit; the map
/// view converts to `CLLocationCoordinate2D` in `Features/Map/`.
struct GeoCoordinate: Sendable, Hashable {
    let latitude: Double
    let longitude: Double
}

/// A lat/lon rectangle. Longitudes run west -> east and may cross the
/// antimeridian (`west > east`). Latitudes are clamped to -90...90 and
/// longitudes wrapped to -180...180; a longitude span of 360 degrees or more
/// becomes the whole world (-180...180).
struct GeoBox: Sendable, Hashable {
    let south: Double
    let west: Double
    let north: Double
    let east: Double

    static let world = GeoBox(south: -90, west: -180, north: 90, east: 180)

    /// Clamps the latitudes (swapping them when south > north) and wraps the
    /// longitudes. Pass `west > east` (or unwrapped values such as
    /// `east: 190`) for a box that crosses the antimeridian.
    init(south: Double, west: Double, north: Double, east: Double) {
        let lo = Self.clampLatitude(min(south, north))
        let hi = Self.clampLatitude(max(south, north))
        self.south = lo
        self.north = hi
        if west <= east, east - west >= 360 {
            self.west = -180
            self.east = 180
        } else {
            self.west = Self.wrapLongitude(west)
            self.east = Self.wrapLongitude(east)
        }
    }

    /// A box around `center` (an `MKCoordinateRegion`'s shape).
    /// `longitudeDelta >= 360` gives the whole world's longitudes.
    init(center: GeoCoordinate, latitudeDelta: Double, longitudeDelta: Double) {
        let halfLat = abs(latitudeDelta) / 2
        let lonDelta = abs(longitudeDelta)
        if lonDelta >= 360 {
            self.init(south: center.latitude - halfLat, west: -180, north: center.latitude + halfLat, east: 180)
        } else {
            self.init(south: center.latitude - halfLat, west: center.longitude - lonDelta / 2,
                      north: center.latitude + halfLat, east: center.longitude + lonDelta / 2)
        }
    }

    var crossesAntimeridian: Bool { west > east }

    /// Degrees of longitude covered, 0...360.
    var longitudeSpan: Double { crossesAntimeridian ? east + 360 - west : east - west }
    var latitudeSpan: Double { north - south }
    var isWorldLongitude: Bool { west == -180 && east == 180 }

    var center: GeoCoordinate {
        var lon = west + longitudeSpan / 2
        if lon > 180 { lon -= 360 }
        return GeoCoordinate(latitude: (south + north) / 2, longitude: lon)
    }

    /// A crossing box is queried as two: `[west...180, -180...east]`.
    /// Otherwise `[self]`. Relate 0.16.1's `point.withinBBox` did not wrap
    /// the antimeridian (west 170, east -170 matched nothing); 1.0.1 does,
    /// but the split keeps region queries independent of that engine detail.
    func split() -> [GeoBox] {
        guard crossesAntimeridian else { return [self] }
        return [
            GeoBox(south: south, west: west, north: north, east: 180),
            GeoBox(south: south, west: -180, north: north, east: east),
        ]
    }

    /// Grows each side by `fraction` of the span (0.5: a box twice as tall
    /// and wide as the original). Latitudes clamp; a longitude span reaching
    /// 360 degrees becomes the world's.
    func padded(by fraction: Double) -> GeoBox {
        let f = max(0, fraction)
        let latPad = latitudeSpan * f
        let lonSpan = longitudeSpan
        let s = south - latPad
        let n = north + latPad
        if isWorldLongitude || lonSpan * (1 + 2 * f) >= 360 {
            return GeoBox(south: s, west: -180, north: n, east: 180)
        }
        let lonPad = lonSpan * f
        return GeoBox(south: s, west: west - lonPad, north: n, east: west + lonSpan + lonPad)
    }

    /// True when `other` lies entirely inside this box (crossing boxes
    /// included).
    func contains(_ other: GeoBox) -> Bool {
        guard other.south >= south, other.north <= north else { return false }
        if isWorldLongitude { return true }
        if other.isWorldLongitude { return false }
        // Compare unwrapped intervals [w, w + span], allowing a 360 shift.
        let w = west, e = west + longitudeSpan
        let ow = other.west, oe = other.west + other.longitudeSpan
        for shift in [-360.0, 0, 360] where ow + shift >= w && oe + shift <= e {
            return true
        }
        return false
    }

    func contains(_ c: GeoCoordinate) -> Bool {
        guard c.latitude >= south, c.latitude <= north else { return false }
        if crossesAntimeridian { return c.longitude >= west || c.longitude <= east }
        return c.longitude >= west && c.longitude <= east
    }

    static func clampLatitude(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(90, max(-90, value))
    }

    /// Into -180...180; values already in range (including 180) are kept.
    static func wrapLongitude(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        if (-180...180).contains(value) { return value }
        var v = (value + 180).truncatingRemainder(dividingBy: 360)
        if v < 0 { v += 360 }
        return v - 180
    }
}

/// Drives a pin's colour, glyph and display priority in the UI.
enum PinTier: Int, Sendable, Comparable, CaseIterable {
    /// No books, only authors born there.
    case birthplace
    /// 1 book.
    case one
    /// 2...4 books.
    case few
    /// 5...14 books.
    case several
    /// 15 or more books.
    case many

    init(books: Int) {
        switch books {
        case ..<1: self = .birthplace
        case 1: self = .one
        case 2...4: self = .few
        case 5...14: self = .several
        default: self = .many
        }
    }

    static func < (lhs: PinTier, rhs: PinTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One map pin: every `Place` node sharing a `geocoded_label` (the
/// extension gives all of them the same point).
struct PlacePin: Sendable, Hashable, Identifiable {
    let label: String
    let coordinate: GeoCoordinate
    /// DISTINCT books SET_IN any node with this label.
    let books: Int
    /// DISTINCT authors BORN_IN any node with this label.
    let authors: Int
    /// The headings behind the pin, sorted.
    let placeNames: [String]

    var id: String { label }
    var isBirthplaceOnly: Bool { books == 0 }
    var tier: PinTier { PinTier(books: books) }

    /// "29 books · 0 authors"
    var countsText: String {
        "\(PlaceText.books(books)) · \(PlaceText.authors(authors))"
    }

    init(label: String, coordinate: GeoCoordinate, books: Int, authors: Int, placeNames: [String]) {
        self.label = label
        self.coordinate = coordinate
        self.books = books
        self.authors = authors
        self.placeNames = placeNames.sorted()
    }

    /// Columns `label`, `location` (both required), `books`, `authors`, `placeNames`.
    init(row: Row) throws {
        let label = try row.requiredString("label")
        guard let coordinate = row.point("location") else { throw GraphError.missingColumn("location") }
        self.init(label: label, coordinate: coordinate, books: row.int("books") ?? 0,
                  authors: row.int("authors") ?? 0, placeNames: row.strings("placeNames"))
    }
}

/// Header facts for the place sheet. Books page through `PagedBooks`;
/// authors are a full list.
struct PlaceSummary: Sendable, Hashable {
    let label: String
    let coordinate: GeoCoordinate
    let bookCount: Int
    let authorCount: Int
    /// Sorted headings behind the label.
    let placeNames: [String]

    /// Headings other than the label itself ("Also filed as: …"); empty when
    /// the only heading is the label.
    var otherNames: [String] {
        placeNames == [label] ? [] : placeNames
    }
}

/// A Place heading's map status, for the term page's "Show on map".
struct PlaceLocation: Sendable, Hashable {
    let name: String
    let label: String?
    let coordinate: GeoCoordinate?
    /// `geo_status`: "ok", "unresolved", "skipped", or nil (never tried).
    let status: String?

    var isOnMap: Bool { label != nil && coordinate != nil }

    var notOnMapReason: String {
        status == "skipped"
            ? "Not on the map: fictional or not a real place"
            : "Not on the map: location unknown"
    }
}

/// A near-me result (core only in phase 4; no UI).
struct NearbyPlace: Sendable, Hashable {
    let label: String
    let coordinate: GeoCoordinate
    let meters: Int
    let placeNames: [String]
}

/// Count phrases shared by pins, the sheet and the count label.
enum PlaceText {
    static func books(_ n: Int) -> String { n == 1 ? "1 book" : "\(n) books" }
    static func authors(_ n: Int) -> String { n == 1 ? "1 author" : "\(n) authors" }
    static func places(_ n: Int) -> String { n == 1 ? "1 place" : "\(n) places" }
}
