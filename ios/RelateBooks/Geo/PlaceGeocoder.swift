import Foundation

/// One forward-geocoding result, reduced to Sendable values (a
/// `CLPlacemark` is not Sendable and never leaves `CLPlaceGeocoder`).
struct GeocodeCandidate: Sendable, Equatable {
    let coordinate: GeoCoordinate
    var name: String? = nil
    var locality: String? = nil
    var subLocality: String? = nil
    var administrativeArea: String? = nil
    var subAdministrativeArea: String? = nil
    var country: String? = nil
    var isoCountryCode: String? = nil
    var ocean: String? = nil
    var inlandWater: String? = nil
    var areasOfInterest: [String] = []

    /// Unique (by `fold`) non-nil values of name, locality,
    /// administrativeArea, country, ocean and inlandWater, ", "-joined
    /// (`geo_display_name`).
    var displayName: String {
        var seen: Set<String> = []
        var parts: [String] = []
        for value in [name, locality, administrativeArea, country, ocean, inlandWater] {
            guard let value, !value.isEmpty, seen.insert(HeadingNormalizer.fold(value)).inserted else { continue }
            parts.append(value)
        }
        return parts.joined(separator: ", ")
    }

    /// The most specific kind present (`geo_place_type`): "areaOfInterest",
    /// "locality", "subAdministrativeArea", "administrativeArea", "country",
    /// "inlandWater", "ocean", else "other".
    var placeType: String {
        if !areasOfInterest.isEmpty { return "areaOfInterest" }
        if locality != nil { return "locality" }
        if subAdministrativeArea != nil { return "subAdministrativeArea" }
        if administrativeArea != nil { return "administrativeArea" }
        if country != nil { return "country" }
        if inlandWater != nil { return "inlandWater" }
        if ocean != nil { return "ocean" }
        return "other"
    }

    /// administrativeArea ?? country (`geo_region`).
    var region: String? { administrativeArea ?? country }

    /// The same candidate with a US or Canadian postal abbreviation in
    /// `administrativeArea` spelled out ("MA" → "Massachusetts"). CLGeocoder
    /// with the en_US locale returns US states abbreviated, while the
    /// extension and the bundled store use full names in `geo_region` and in
    /// label suffixes ("Cambridge, Massachusetts").
    func expandingRegionAbbreviation() -> GeocodeCandidate {
        guard let area = administrativeArea, let full = RegionNames.fullName(area, isoCountryCode: isoCountryCode, country: country)
        else { return self }
        var copy = self
        copy.administrativeArea = full
        return copy
    }

    /// The candidate is the region itself (a country or a first-level
    /// division, e.g. "Cuba", "California"): its placeType is country or
    /// administrativeArea and that field folds to `labelBase`.
    func isRegion(labelBase: String) -> Bool {
        let target = HeadingNormalizer.fold(labelBase)
        switch placeType {
        case "country": return country.map(HeadingNormalizer.fold) == target
        case "administrativeArea": return administrativeArea.map(HeadingNormalizer.fold) == target
        default: return false
        }
    }

    /// The fields acceptance looks at (D15), in this order.
    var matchFields: [String] {
        [name, locality, subLocality, administrativeArea, subAdministrativeArea, country, ocean, inlandWater]
            .compactMap { $0 } + areasOfInterest
    }
}

/// A located Place's label and point (one label keeps one point).
struct LocatedLabel: Sendable, Equatable {
    let label: String
    let coordinate: GeoCoordinate
}

extension GeoCoordinate {
    /// Great-circle distance in metres (haversine, R = 6371 km, as the
    /// extension's `haversine_km`).
    func distanceMeters(to other: GeoCoordinate) -> Double {
        let p1 = latitude * .pi / 180, p2 = other.latitude * .pi / 180
        let dp = p2 - p1, dl = (other.longitude - longitude) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * 6_371_000 * asin(min(1, a.squareRoot()))
    }
}

/// Postal abbreviations CLGeocoder returns for US states and territories
/// and Canadian provinces and territories, with their full names.
enum RegionNames {
    static let unitedStates: [String: String] = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California",
        "CO": "Colorado", "CT": "Connecticut", "DE": "Delaware", "DC": "District of Columbia",
        "FL": "Florida", "GA": "Georgia", "HI": "Hawaii", "ID": "Idaho", "IL": "Illinois",
        "IN": "Indiana", "IA": "Iowa", "KS": "Kansas", "KY": "Kentucky", "LA": "Louisiana",
        "ME": "Maine", "MD": "Maryland", "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota",
        "MS": "Mississippi", "MO": "Missouri", "MT": "Montana", "NE": "Nebraska", "NV": "Nevada",
        "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico", "NY": "New York",
        "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma", "OR": "Oregon",
        "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina", "SD": "South Dakota",
        "TN": "Tennessee", "TX": "Texas", "UT": "Utah", "VT": "Vermont", "VA": "Virginia",
        "WA": "Washington", "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming",
        "PR": "Puerto Rico", "GU": "Guam", "VI": "U.S. Virgin Islands", "AS": "American Samoa",
        "MP": "Northern Mariana Islands",
    ]
    static let canada: [String: String] = [
        "AB": "Alberta", "BC": "British Columbia", "MB": "Manitoba", "NB": "New Brunswick",
        "NL": "Newfoundland and Labrador", "NS": "Nova Scotia", "NT": "Northwest Territories",
        "NU": "Nunavut", "ON": "Ontario", "PE": "Prince Edward Island", "QC": "Quebec",
        "SK": "Saskatchewan", "YT": "Yukon",
    ]

    /// The full name for a postal abbreviation in the US or Canada (by ISO
    /// code, else by country name); nil for anything else.
    static func fullName(_ area: String, isoCountryCode: String?, country: String?) -> String? {
        let code = area.trimmingCharacters(in: .whitespaces).uppercased()
        guard code.count == 2 else { return nil }
        let iso = isoCountryCode?.uppercased()
        if iso == "US" || (iso == nil && country == "United States") { return unitedStates[code] }
        if iso == "CA" || (iso == nil && country == "Canada") { return canada[code] }
        return nil
    }
}

/// Forward geocoding of one query (D-F). Implementations: `CLPlaceGeocoder`
/// (the app) and `StubPlaceGeocoder` (DEBUG: tests and `--stub-network`).
protocol PlaceGeocoder: Sendable {
    /// Written to `geo_source`: "clgeocoder" | "stub".
    var sourceName: String { get }
    /// Candidates in the geocoder's order; [] when nothing matched. Throws
    /// on errors (network, throttling) and CancellationError.
    func geocode(_ query: String) async throws -> [GeocodeCandidate]
}

/// Candidate acceptance and labels (D15). Pure.
enum PlaceMatch {
    /// `significant(labelBase) ⊆ tokens(field)` for some `matchFields` entry
    /// (the extension's tolerance: "Washington State" accepts the
    /// administrative area "Washington"; "Killick-Claw" rejects "Killick Road").
    static func accepts(_ candidate: GeocodeCandidate, labelBase: String) -> Bool {
        let needed = HeadingNormalizer.significant(labelBase)
        guard !needed.isEmpty else { return false }
        return candidate.matchFields.contains { needed.isSubset(of: Set(HeadingNormalizer.tokens($0))) }
    }

    /// The first of locality, administrativeArea and country whose `fold`
    /// equals `fold(labelBase)` (the geocoder's spelling), else `labelBase`.
    static func preferredLabel(_ candidate: GeocodeCandidate, labelBase: String) -> String {
        let target = HeadingNormalizer.fold(labelBase)
        for value in [candidate.locality, candidate.administrativeArea, candidate.country] {
            if let value, HeadingNormalizer.fold(value) == target { return value }
        }
        return labelBase
    }

    /// "<label>, <qualifier or region>" (D15 step 3: the label is taken by a
    /// place more than 1 km away). Unchanged when there is no suffix.
    static func suffixed(_ label: String, heading: NormalizedHeading, candidate: GeocodeCandidate) -> String {
        guard let suffix = heading.qualifierLabel ?? candidate.administrativeArea ?? candidate.country,
              !suffix.isEmpty, HeadingNormalizer.fold(suffix) != HeadingNormalizer.fold(label) else { return label }
        return "\(label), \(suffix)"
    }

    /// The extension's same-base merge radius (`assign_labels`: same
    /// `fold(label_base)` within 50 km joins one label and pin).
    static let sameNameRadiusMeters = 50_000.0
    /// Region-sized merge radii. The extension also merges by OSM id, which
    /// cannot be ported; Apple's and Nominatim's centres for one country or
    /// state lie tens to hundreds of km apart (Cuba, Russia, Canada), so a
    /// candidate that is itself a region merges into a same-named label much
    /// further away. Two same-named regions are thousands of km apart
    /// (Georgia the country and the US state: ~10,000 km).
    static let countryRadiusMeters = 3_000_000.0
    static let administrativeAreaRadiusMeters = 1_000_000.0

    /// How far a same-named located label may be and still be this place.
    static func mergeRadiusMeters(_ candidate: GeocodeCandidate, labelBase: String) -> Double {
        guard candidate.isRegion(labelBase: labelBase) else { return sameNameRadiusMeters }
        return candidate.placeType == "country" ? countryRadiusMeters : administrativeAreaRadiusMeters
    }

    /// D15 steps 2–4 against the store's located labels (no label within
    /// 1 km). Labels compare by `fold`, as `assign_labels` does.
    ///  1. A label folding to `preferred` (else to `suffixed`) within
    ///     `radius`: this is that place; reuse its label and point.
    ///  2. `preferred` if no located place uses it.
    ///  3. `suffixed` if it differs and is free.
    ///  4. `suffixed (lat, lon)`.
    static func resolveLabel(preferred: String, suffixed: String, at coordinate: GeoCoordinate, radius: Double,
                             existing: [LocatedLabel]) -> (label: String, coordinate: GeoCoordinate, reused: Bool) {
        func nearest(named name: String) -> LocatedLabel? {
            let key = HeadingNormalizer.fold(name)
            return existing
                .filter { HeadingNormalizer.fold($0.label) == key }
                .map { ($0, $0.coordinate.distanceMeters(to: coordinate)) }
                .filter { $0.1 <= radius }
                .min { $0.1 < $1.1 }?.0
        }
        if let hit = nearest(named: preferred) ?? (suffixed != preferred ? nearest(named: suffixed) : nil) {
            return (hit.label, hit.coordinate, true)
        }
        let taken = Set(existing.map { HeadingNormalizer.fold($0.label) })
        if !taken.contains(HeadingNormalizer.fold(preferred)) { return (preferred, coordinate, false) }
        if suffixed != preferred, !taken.contains(HeadingNormalizer.fold(suffixed)) { return (suffixed, coordinate, false) }
        return (coordinateSuffixed(suffixed, coordinate), coordinate, false)
    }

    /// "<label> (12.35, -45.68)" (D15 step 4: still taken).
    static func coordinateSuffixed(_ label: String, _ c: GeoCoordinate) -> String {
        String(format: "%@ (%.2f, %.2f)", label, c.latitude, c.longitude)
    }
}
