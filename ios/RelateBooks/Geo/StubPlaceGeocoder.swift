#if DEBUG
import Foundation

/// A deterministic geocoder for tests and DEBUG `--stub-network` (D-C):
/// fixed candidates per query, [] for anything else. Records every query
/// and the highest number of calls in flight at once (D13 tests).
actor StubPlaceGeocoder: PlaceGeocoder {
    nonisolated let sourceName = "stub"

    /// The fixture book's two new places (The Perfect Storm, spec A.12).
    /// Gloucester has the shape real CLGeocoder (en_US) returns: the state
    /// abbreviated ("MA"); `PlaceLocator` spells it out.
    static let fixtureTable: [String: [GeocodeCandidate]] = [
        "Gloucester, Massachusetts": [
            GeocodeCandidate(coordinate: GeoCoordinate(latitude: 42.6159, longitude: -70.6620),
                             name: "Gloucester", locality: "Gloucester", administrativeArea: "MA",
                             subAdministrativeArea: "Essex County", country: "United States", isoCountryCode: "US"),
        ],
        "North Atlantic Ocean": [
            GeocodeCandidate(coordinate: GeoCoordinate(latitude: 40.0, longitude: -45.0),
                             name: "North Atlantic Ocean", ocean: "North Atlantic Ocean"),
        ],
    ]

    private let table: [String: [GeocodeCandidate]]
    private let delay: Duration
    private let error: (any Error)?
    private let errors: [String: any Error]
    private(set) var queries: [String] = []
    /// Highest number of `geocode` calls in flight at once.
    private(set) var maxInFlight = 0
    private var inFlight = 0

    /// - `error`: thrown by every call (after `delay`).
    /// - `errors`: thrown for those queries only.
    init(table: [String: [GeocodeCandidate]] = StubPlaceGeocoder.fixtureTable, delay: Duration = .zero,
         error: (any Error)? = nil, errors: [String: any Error] = [:]) {
        self.table = table
        self.delay = delay
        self.error = error
        self.errors = errors
    }

    func geocode(_ query: String) async throws -> [GeocodeCandidate] {
        queries.append(query)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let error = errors[query] ?? error { throw error }
        return table[query] ?? []
    }
}
#endif
