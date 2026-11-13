import Foundation

/// What `GraphStore.writePlaceLocated` writes (D-F, D15, D17).
struct PlaceLocationWrite: Sendable, Equatable {
    let label: String
    /// `location`: the reused label's point, or `raw`.
    let coordinate: GeoCoordinate
    /// `geo_lat` / `geo_lon`: what the geocoder returned.
    let raw: GeoCoordinate
    /// `geo_source`: the geocoder's `sourceName`.
    let source: String
    let displayName: String
    let placeType: String
    /// `geo_query`: the query that succeeded (the fallback if it was used).
    let query: String
    /// `geo_region`: administrativeArea ?? country.
    let region: String?
}

/// What happened to one heading.
enum PlaceGeocodeOutcome: Sendable, Equatable {
    case located(name: String, label: String, coordinate: GeoCoordinate, reusedLabel: Bool)
    /// "no result" | "no matching result" | "timed out" | "geocoder error: <desc>" |
    /// "store error: <desc>" | "already located" | "cancelled".
    case unresolved(name: String, reason: String)
    case skipped(name: String, reason: String)
    /// Beyond `maxPlaces` (D13): nothing written, no `geo_status`.
    case notAttempted(name: String)

    var name: String {
        switch self {
        case .located(let name, _, _, _), .unresolved(let name, _), .skipped(let name, _), .notAttempted(let name):
            name
        }
    }

    /// The label, for `.located` only.
    var label: String? {
        if case .located(_, let label, _, _) = self { return label }
        return nil
    }

    var isLocated: Bool { label != nil }
}

/// Geocodes Places one at a time and writes the result on the node (D-F,
/// D13, D15). US and Canadian state abbreviations from the geocoder are
/// spelled out before matching (`geo_region`, label suffixes).
///
/// - Never throws: every failure becomes an outcome and, except
///   `.notAttempted` and a cancellation while queued, a `placeFailed`
///   write (`geo_status` unresolved or skipped, `geo_reason`).
/// - Only touches places whose `location` is null (the statements' guard),
///   so a bundled, already located Place is never modified.
/// - Copies share `gate` (an actor), so every geocoder request is serial
///   across imports; `AppSession` holds one locator. The gate is held for a
///   heading's query and its fallback.
struct PlaceLocator: Sendable {
    let store: GraphStore
    let geocoder: any PlaceGeocoder
    let gate: RequestGate
    /// At most this many places per `locate(_:)` call (D13).
    var maxPlaces = 10
    var requestTimeout: Duration = .seconds(10)
    /// An existing located Place this close lends its label and point (D-F),
    /// whatever its name. Beyond it, a same-named label (by `fold`) within
    /// `PlaceMatch.mergeRadiusMeters` is reused too (`assign_labels`).
    var reuseRadiusMeters = 1_000.0

    init(store: GraphStore, geocoder: any PlaceGeocoder, gate: RequestGate = RequestGate()) {
        self.store = store
        self.geocoder = geocoder
        self.gate = gate
    }

    /// Locates `names` in order. `progress(done, total)` runs after each
    /// attempted place, with total = min(count, maxPlaces).
    func locate(_ names: [String],
                progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }) async -> [PlaceGeocodeOutcome] {
        let total = min(names.count, maxPlaces)
        var outcomes: [PlaceGeocodeOutcome] = []
        for (index, name) in names.enumerated() {
            guard index < maxPlaces else {
                outcomes.append(.notAttempted(name: name))
                continue
            }
            let outcome = await locate(name: name)
            outcomes.append(outcome)
            Log.store.notice("geocode \(name, privacy: .public) (\(self.geocoder.sourceName, privacy: .public)): \(String(describing: outcome), privacy: .public)")
            await progress(index + 1, total)
        }
        return outcomes
    }

    /// One heading, holding the gate for its query and fallback.
    func locate(name: String) async -> PlaceGeocodeOutcome {
        do {
            return try await gate.withGate { await self.locateHoldingGate(name) }
        } catch {
            return .unresolved(name: name, reason: "cancelled")
        }
    }

    // MARK: Private

    private enum Attempt: Sendable {
        case candidates([GeocodeCandidate])
        case timedOut
        case failed(String)
    }

    private func locateHoldingGate(_ name: String) async -> PlaceGeocodeOutcome {
        let heading = HeadingNormalizer.normalize(name)
        guard heading.status == .lookup, let query = heading.query else {
            let reason = heading.skipReason ?? "not a place"
            do {
                try await store.writePlaceFailed(name: name, status: "skipped", query: nil, reason: reason)
            } catch {
                return .unresolved(name: name, reason: "store error: \(error.localizedDescription)")
            }
            return .skipped(name: name, reason: reason)
        }

        var sawCandidate = false
        var winner: (candidate: GeocodeCandidate, query: String)?
        for q in [query] + [heading.fallbackQuery].compactMap({ $0 }) {
            switch await attempt(q) {
            case .timedOut:
                return await fail(name, query: query, reason: "timed out")
            case .failed(let description):
                return await fail(name, query: query, reason: "geocoder error: \(description)")
            case .candidates(let candidates):
                sawCandidate = sawCandidate || !candidates.isEmpty
                if let match = candidates.map({ $0.expandingRegionAbbreviation() })
                    .first(where: { PlaceMatch.accepts($0, labelBase: heading.labelBase) }) {
                    winner = (match, q)
                }
            }
            if winner != nil { break }
        }
        guard let winner else {
            return await fail(name, query: query, reason: sawCandidate ? "no matching result" : "no result")
        }

        do {
            let candidate = winner.candidate
            var label: String
            var point = candidate.coordinate
            var reused = false
            if let near = try await store.nearestPlaceLabel(to: candidate.coordinate, within: reuseRadiusMeters) {
                label = near.label
                point = near.coordinate
                reused = true
            } else {
                let preferred = PlaceMatch.preferredLabel(candidate, labelBase: heading.labelBase)
                let resolved = PlaceMatch.resolveLabel(
                    preferred: preferred,
                    suffixed: PlaceMatch.suffixed(preferred, heading: heading, candidate: candidate),
                    at: candidate.coordinate,
                    radius: PlaceMatch.mergeRadiusMeters(candidate, labelBase: heading.labelBase),
                    existing: try await store.locatedLabels())
                label = resolved.label
                point = resolved.coordinate
                reused = resolved.reused
            }
            let write = PlaceLocationWrite(label: label, coordinate: point, raw: candidate.coordinate,
                                           source: geocoder.sourceName, displayName: candidate.displayName,
                                           placeType: candidate.placeType, query: winner.query, region: candidate.region)
            guard try await store.writePlaceLocated(name: name, write) else {
                return .unresolved(name: name, reason: "already located")
            }
            return .located(name: name, label: label, coordinate: point, reusedLabel: reused)
        } catch {
            return .unresolved(name: name, reason: "store error: \(error.localizedDescription)")
        }
    }

    /// Writes `geo_status: 'unresolved'` and returns the outcome.
    private func fail(_ name: String, query: String?, reason: String) async -> PlaceGeocodeOutcome {
        do {
            try await store.writePlaceFailed(name: name, status: "unresolved", query: query, reason: reason)
        } catch {
            return .unresolved(name: name, reason: "store error: \(error.localizedDescription)")
        }
        return .unresolved(name: name, reason: reason)
    }

    /// One geocoder call raced against `requestTimeout`; the loser is cancelled.
    private func attempt(_ query: String) async -> Attempt {
        let geocoder = self.geocoder
        let timeout = requestTimeout
        return await withTaskGroup(of: Attempt?.self) { group in
            group.addTask {
                do {
                    return .candidates(try await geocoder.geocode(query))
                } catch is CancellationError {
                    return nil
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .timedOut
                } catch {
                    return nil
                }
            }
            var result: Attempt = .failed("cancelled")
            for await value in group {
                if let value {
                    result = value
                    break
                }
            }
            group.cancelAll()
            return result
        }
    }
}
