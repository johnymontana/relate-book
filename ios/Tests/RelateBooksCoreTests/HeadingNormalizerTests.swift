import Testing
import Foundation
@testable import RelateBooksCore

@Suite("Heading normaliser")
struct HeadingNormalizerTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let heading: String
        let skipped: Bool
        let query: String?
        let fallback: String?
        let labelBase: String
        let reason: String?
        var testDescription: String { heading }
    }

    static func lookup(_ h: String, _ q: String, _ f: String? = nil, _ base: String) -> Case {
        Case(heading: h, skipped: false, query: q, fallback: f, labelBase: base, reason: nil)
    }

    static func skip(_ h: String, _ base: String, _ reason: String) -> Case {
        Case(heading: h, skipped: true, query: nil, fallback: nil, labelBase: base, reason: reason)
    }

    /// Produced by the extension's own `normalize_heading` with `SYNONYMS = {}` (spec A.9).
    static let table: [Case] = [
        lookup("Gloucester (Mass.)", "Gloucester, Massachusetts", nil, "Gloucester"),
        lookup("Pasadena (Calif.)", "Pasadena, California", nil, "Pasadena"),
        lookup("San Francisco (Calif.)", "San Francisco, California", nil, "San Francisco"),
        lookup("North Atlantic Ocean", "North Atlantic Ocean", nil, "North Atlantic Ocean"),
        lookup("New England", "New England", nil, "New England"),
        lookup("Washington (State)", "Washington State", nil, "Washington State"),
        lookup("Washington (D.C.)", "Washington, District of Columbia", nil, "Washington"),
        lookup("Everest, Mount (China and Nepal)", "Everest, Mount, China", "Everest, Mount, Nepal", "Everest, Mount"),
        lookup("Baikonur (Kazakhstan)", "Baikonur, Kazakhstan", nil, "Baikonur"),
        lookup("Sahara Desert (Africa)", "Sahara Desert, Africa", nil, "Sahara Desert"),
        lookup("South China Sea region", "South China Sea region", "South China Sea", "South China Sea region"),
        skip("Epsilon Eridani", "Epsilon Eridani", "non-terrestrial"),
        skip("40 Eridani", "40 Eridani", "non-terrestrial"),
        skip("Tau Ceti", "Tau Ceti", "non-terrestrial"),
        skip("Earth", "Earth", "non-terrestrial"),
        skip("Mars (Planet)", "Mars", "non-terrestrial"),
        skip("Gethen", "Gethen", "fictional setting"),
        skip("Middle-earth (Imaginary place)", "Middle-earth", "fictional setting"),
        lookup("Cuba", "Cuba", nil, "Cuba"),
        lookup("Gulf Stream", "Gulf Stream", nil, "Gulf Stream"),
        lookup("Killick-Claw", "Killick-Claw", nil, "Killick-Claw"),
        lookup("Brooklyn (New York, N.Y.)", "Brooklyn, New York City", nil, "Brooklyn"),
        lookup("Paris (France)", "Paris, France", nil, "Paris"),
        lookup("Salinas River Valley (Calif.)", "Salinas River Valley, California", "Salinas River, California", "Salinas River Valley"),
        lookup("Idaho and Mont.", "Idaho and Mont.", nil, "Idaho and Mont."),
        lookup("Yellowstone National Park (Wyo.)", "Yellowstone National Park, Wyoming", nil, "Yellowstone National Park"),
        skip("Q975", "Q975", "unresolved Wikidata id"),
        lookup("Lake Tahoe (Calif. and Nev.)", "Lake Tahoe, California", "Lake Tahoe, Nevada", "Lake Tahoe"),
        lookup("  Missoula  (Mont.) ", "Missoula, Montana", nil, "Missoula"),
        lookup("London (England)", "London, England", nil, "London"),
        lookup("Trinidad and Tobago", "Trinidad and Tobago", nil, "Trinidad and Tobago"),
        lookup("Kyoto (Japan) ; Tokyo", "Kyoto, Japan", nil, "Kyoto"),
        skip("Oregon)", "Oregon)", "malformed heading"),
        skip("1984", "1984", "malformed heading"),
    ]

    @Test("normalize matches the extension", arguments: table)
    func normalize(_ c: Case) {
        let h = HeadingNormalizer.normalize(c.heading)
        #expect(h.name == c.heading)
        #expect(h.status == (c.skipped ? .skipped : .lookup))
        #expect(h.query == c.query)
        #expect(h.fallbackQuery == c.fallback)
        #expect(h.labelBase == c.labelBase)
        #expect(h.skipReason == c.reason)
    }

    @Test("qualifier labels (the collision suffix)")
    func qualifierLabels() {
        #expect(HeadingNormalizer.normalize("Gloucester (Mass.)").qualifierLabel == "Massachusetts")
        #expect(HeadingNormalizer.normalize("Everest, Mount (China and Nepal)").qualifierLabel == "China")
        #expect(HeadingNormalizer.normalize("Brooklyn (New York, N.Y.)").qualifierLabel == "New York City")
        #expect(HeadingNormalizer.normalize("Lake Tahoe (Calif. and Nev.)").qualifierLabel == "California")
        #expect(HeadingNormalizer.normalize("Portland (Me.)").qualifierLabel == "Maine")
        for h in ["Cuba", "North Atlantic Ocean", "South China Sea region", "Washington (State)"] {
            #expect(HeadingNormalizer.normalize(h).qualifierLabel == nil, "\(h)")
        }
    }

    @Test("fold, tokens and significant")
    func textKeys() {
        #expect(HeadingNormalizer.fold("  Île-de-France  ") == "ile-de-france")
        #expect(HeadingNormalizer.fold("São  Tomé") == "sao tome")
        #expect(HeadingNormalizer.fold("Nor’easter") == "nor'easter")
        #expect(HeadingNormalizer.significant("Washington State") == ["washington"])
        #expect(HeadingNormalizer.significant("South China Sea region") == ["south", "china", "sea"])
        #expect(HeadingNormalizer.significant("The City") == ["the", "city"])
        #expect(HeadingNormalizer.tokens("Mt. Hood") == ["mount", "hood"])
        #expect(HeadingNormalizer.tokens("Ft Smith") == ["fort", "smith"])
        #expect(HeadingNormalizer.tokens("St. Louis") == ["saint", "louis"])
        #expect(HeadingNormalizer.tokens("Nor'easter") == ["noreaster"])
    }

    struct AcceptCase: Sendable, CustomTestStringConvertible {
        let base: String
        let candidate: GeocodeCandidate
        let accepts: Bool
        var testDescription: String { base }
    }

    static let origin = GeoCoordinate(latitude: 0, longitude: 0)
    static let acceptTable: [AcceptCase] = [
        AcceptCase(base: "Gloucester", candidate: GeocodeCandidate(coordinate: origin, locality: "Gloucester"), accepts: true),
        AcceptCase(base: "North Atlantic Ocean", candidate: GeocodeCandidate(coordinate: origin, ocean: "North Atlantic Ocean"), accepts: true),
        AcceptCase(base: "Washington State", candidate: GeocodeCandidate(coordinate: origin, administrativeArea: "Washington"), accepts: true),
        AcceptCase(base: "Everest, Mount", candidate: GeocodeCandidate(coordinate: origin, name: "Mount Everest"), accepts: true),
        AcceptCase(base: "South China Sea region", candidate: GeocodeCandidate(coordinate: origin, ocean: "South China Sea"), accepts: true),
        AcceptCase(base: "Killick-Claw", candidate: GeocodeCandidate(coordinate: origin, name: "Killick Road"), accepts: false),
        AcceptCase(base: "St. Louis", candidate: GeocodeCandidate(coordinate: origin, locality: "Saint Louis"), accepts: true),
        AcceptCase(base: "The Hague", candidate: GeocodeCandidate(coordinate: origin, locality: "Den Haag"), accepts: false),
        AcceptCase(base: "Yosemite", candidate: GeocodeCandidate(coordinate: origin, areasOfInterest: ["Yosemite National Park"]), accepts: true),
    ]

    @Test("candidate acceptance (D15)", arguments: acceptTable)
    func accepts(_ c: AcceptCase) {
        #expect(PlaceMatch.accepts(c.candidate, labelBase: c.base) == c.accepts)
    }

    @Test("preferred labels, suffixes and candidate summaries")
    func labels() throws {
        let gloucester = try #require(StubPlaceGeocoder.fixtureTable["Gloucester, Massachusetts"]?.first)
        let ocean = try #require(StubPlaceGeocoder.fixtureTable["North Atlantic Ocean"]?.first)
        #expect(PlaceMatch.preferredLabel(gloucester, labelBase: "Gloucester") == "Gloucester")
        #expect(PlaceMatch.preferredLabel(ocean, labelBase: "North Atlantic Ocean") == "North Atlantic Ocean")
        let washington = GeocodeCandidate(coordinate: Self.origin, administrativeArea: "Washington", country: "United States")
        #expect(PlaceMatch.preferredLabel(washington, labelBase: "Washington State") == "Washington State")
        let accented = GeocodeCandidate(coordinate: Self.origin, locality: "Montréal")
        #expect(PlaceMatch.preferredLabel(accented, labelBase: "Montreal") == "Montréal")
        #expect(gloucester.displayName == "Gloucester, MA, United States" && gloucester.region == "MA")
        let expanded = gloucester.expandingRegionAbbreviation()
        #expect(expanded.displayName == "Gloucester, Massachusetts, United States")
        #expect(expanded.placeType == "locality" && expanded.region == "Massachusetts")
        #expect(ocean.displayName == "North Atlantic Ocean" && ocean.placeType == "ocean" && ocean.region == nil)
        let portland = HeadingNormalizer.normalize("Portland (Me.)")
        let maine = GeocodeCandidate(coordinate: GeoCoordinate(latitude: 43.6591, longitude: -70.2568), locality: "Portland",
                                     administrativeArea: "Maine", country: "United States")
        #expect(PlaceMatch.suffixed("Portland", heading: portland, candidate: maine) == "Portland, Maine")
        #expect(PlaceMatch.suffixed("Cuba", heading: HeadingNormalizer.normalize("Cuba"),
                                    candidate: GeocodeCandidate(coordinate: Self.origin, country: "Cuba")) == "Cuba")
        #expect(PlaceMatch.coordinateSuffixed("Portland, Maine", maine.coordinate) == "Portland, Maine (43.66, -70.26)")
    }
}
