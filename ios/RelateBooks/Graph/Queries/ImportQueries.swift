import Foundation
import Relate

/// One label/relationship pair the importer writes terms to (the
/// extension's `WRITE_TERMS` table). An enum, not a table of KeyPaths: a
/// static array of tuples holding KeyPaths is not Sendable in Swift 6.
enum TermTarget: String, CaseIterable, Sendable {
    case subject, place, person, era, genre

    /// "Subject" | "Place" | "Person" | "Era" | "Genre"
    var label: String {
        switch self {
        case .subject: "Subject"
        case .place: "Place"
        case .person: "Person"
        case .era: "Era"
        case .genre: "Genre"
        }
    }

    /// "ABOUT" | "SET_IN" | "FEATURES" | "SET_DURING" | "IN_GENRE"
    var relationship: String {
        switch self {
        case .subject: "ABOUT"
        case .place: "SET_IN"
        case .person: "FEATURES"
        case .era: "SET_DURING"
        case .genre: "IN_GENRE"
        }
    }

    /// The matching list of `terms`.
    func names(in terms: ImportTerms) -> [String] {
        switch self {
        case .subject: terms.subjects
        case .place: terms.places
        case .person: terms.people
        case .era: terms.eras
        case .genre: terms.genres
        }
    }
}

/// Cypher for the add-book flow (phase 5, D-E, D5-D12, D15), verified on a
/// copy of the bundled store (spec "Verified Cypher" V1-V12).
///
/// - Values are always parameters; labels and relationship types come only
///   from the fixed `TermTarget` table, never from data.
/// - The save is one transaction of MERGE statements and never deletes
///   (Relate 0.16.1 and 1.0.1, LABS-1188). W1 sets every Book property only ON
///   CREATE, so an existing Book is never overwritten; every later
///   statement starts with `MATCH (b:Book {key: $key}) WHERE b.added_on =
///   datetime($now)`, so when the Book pre-existed nothing else is written
///   (D11).
/// - `added_on = datetime($now)` lands on every node the import creates
///   (Book, Author, Subject, Place, Person, Era, Genre; D9), ON CREATE only.
/// - `$now` is always `Timestamps.instant(now)`.
enum ImportQueries {
    /// The five term writes, in this order.
    static let termTargets: [TermTarget] = TermTarget.allCases

    static func bookExists(key: String) -> Statement {
        Statement("MATCH (b:Book {key: $key}) RETURN b.key AS key", ["key": .string(key)])
    }

    /// The Book whose wishlist Item has this ISBN-13 (or ISBN-10), or whose
    /// own `isbn13` (an earlier app import) matches. `$isbn10` is null for 979.
    static func bookByISBN(_ isbn: ISBN) -> Statement {
        Statement("""
            CALL {
              MATCH (i:Item)-[:EDITION_OF]->(b:Book) WHERE i.isbn13 = $isbn13 RETURN b
              UNION
              MATCH (i:Item)-[:EDITION_OF]->(b:Book) WHERE $isbn10 IS NOT NULL AND i.isbn10 = $isbn10 RETURN b
              UNION
              MATCH (b:Book) WHERE b.isbn13 = $isbn13 RETURN b
            }
            RETURN b.key AS key, b.title AS title
            ORDER BY key
            LIMIT 1
            """, ["isbn13": .string(isbn.isbn13), "isbn10": isbn.isbn10.map(CypherValue.string) ?? .null])
    }

    static func existingBooks(keys: [String]) -> Statement {
        Statement("""
            UNWIND $keys AS k
            MATCH (b:Book {key: k})
            RETURN b.key AS key
            """, ["keys": .list(keys.map(CypherValue.string))])
    }

    static func existingAuthors(keys: [String]) -> Statement {
        Statement("""
            UNWIND $keys AS k
            MATCH (a:Author {key: k})
            RETURN a.key AS key
            """, ["keys": .list(keys.map(CypherValue.string))])
    }

    /// The names with no Place node yet, in input order (D12).
    static func missingPlaces(names: [String]) -> Statement {
        Statement("""
            UNWIND $names AS name
            OPTIONAL MATCH (p:Place {name: name})
            WITH name, p
            WHERE p IS NULL
            RETURN name
            """, ["names": .list(names.map(CypherValue.string))])
    }

    /// W1. `created` is true when this statement created the Book (also on
    /// an exact replay with the same `$now`), false when it existed.
    static func saveBook(_ draft: ImportDraft, now: Date) -> Statement {
        Statement("""
            MERGE (b:Book {key: $key})
            ON CREATE SET b += $props, b.source = 'app', b.match = $match, b.added_on = datetime($now)
            RETURN b.key AS key, b.added_on = datetime($now) AS created
            """, [
                "key": .string(draft.key),
                "props": .map(draft.properties),
                "match": .string(draft.match.rawValue),
                "now": .string(Timestamps.instant(now)),
            ])
    }

    /// W2. Existing authors only gain the WRITTEN_BY edge (D6).
    static func saveAuthors(key: String, authors: [ImportAuthor], now: Date) -> Statement {
        let rows: [CypherValue] = authors.map { author in
            .map(["key": .string(author.key), "source": .string(author.source), "props": .map(author.properties)])
        }
        return Statement("""
            MATCH (b:Book {key: $key}) WHERE b.added_on = datetime($now)
            UNWIND $authors AS a
            MERGE (au:Author {key: a.key})
            ON CREATE SET au += a.props, au.source = a.source, au.added_on = datetime($now)
            MERGE (b)-[w:WRITTEN_BY]->(au)
            SET w.role = 'Author'
            RETURN count(au) AS authors
            """, ["key": .string(key), "authors": .list(rows), "now": .string(Timestamps.instant(now))])
    }

    /// W3 for one term list; the label and relationship come from `target`.
    static func saveTerms(_ target: TermTarget, key: String, names: [String], now: Date) -> Statement {
        Statement("""
            MATCH (b:Book {key: $key}) WHERE b.added_on = datetime($now)
            UNWIND $names AS name
            MERGE (t:\(target.label) {name: name})
            ON CREATE SET t.added_on = datetime($now)
            MERGE (b)-[:\(target.relationship)]->(t)
            RETURN count(t) AS terms
            """, ["key": .string(key), "names": .list(names.map(CypherValue.string)), "now": .string(Timestamps.instant(now))])
    }

    /// W1, then W2 if there are authors, then one W3 per non-empty list.
    static func saveStatements(_ draft: ImportDraft, now: Date) -> [Statement] {
        var statements = [saveBook(draft, now: now)]
        if !draft.authors.isEmpty {
            statements.append(saveAuthors(key: draft.key, authors: draft.authors, now: now))
        }
        for target in termTargets {
            let names = target.names(in: draft.terms)
            if !names.isEmpty {
                statements.append(saveTerms(target, key: draft.key, names: names, now: now))
            }
        }
        return statements
    }

    /// The nearest labelled, located Place within `radiusMeters` (POINT
    /// index; the 1 km label reuse rule, D15).
    static func nearestLabel(_ c: GeoCoordinate, radiusMeters: Double) -> Statement {
        Statement("""
            MATCH (p:Place)
            WHERE point.distance(p.location, point({latitude: $lat, longitude: $lon})) < $radius AND p.geocoded_label IS NOT NULL
            WITH p, point.distance(p.location, point({latitude: $lat, longitude: $lon})) AS meters
            RETURN p.geocoded_label AS label, p.location AS location, meters
            ORDER BY meters, label
            LIMIT 1
            """, ["lat": .float(c.latitude), "lon": .float(c.longitude), "radius": .float(radiusMeters)])
    }

    /// Every located label with its point (482 in the bundled store; one
    /// label keeps one point). `PlaceMatch.resolveLabel` compares them by
    /// `fold`, which Cypher cannot express (case and accents).
    static func locatedLabels() -> Statement {
        Statement("""
            MATCH (p:Place)
            WHERE p.location IS NOT NULL AND p.geocoded_label IS NOT NULL
            RETURN DISTINCT p.geocoded_label AS label, p.location AS location
            """)
    }

    /// Writes a located place; a no-op when it already has a `location`.
    static func placeLocated(name: String, write: PlaceLocationWrite) -> Statement {
        Statement("""
            MATCH (p:Place {name: $name})
            WHERE p.location IS NULL
            SET p.location = point({latitude: $lat, longitude: $lon}), p.geocoded_label = $label,
                p.geo_source = $source, p.geo_status = 'ok', p.geo_lat = $rawLat, p.geo_lon = $rawLon,
                p.geo_display_name = $displayName, p.geo_place_type = $placeType, p.geo_query = $query,
                p.geo_region = $region
            RETURN p.name AS name, p.geocoded_label AS label
            """, [
                "name": .string(name),
                "lat": .float(write.coordinate.latitude), "lon": .float(write.coordinate.longitude),
                "label": .string(write.label), "source": .string(write.source),
                "rawLat": .float(write.raw.latitude), "rawLon": .float(write.raw.longitude),
                "displayName": .string(write.displayName), "placeType": .string(write.placeType),
                "query": .string(write.query), "region": write.region.map(CypherValue.string) ?? .null,
            ])
    }

    /// `$status` is 'unresolved' or 'skipped'; `$query` may be null. A
    /// no-op when the place already has a `location`.
    static func placeFailed(name: String, status: String, query: String?, reason: String) -> Statement {
        Statement("""
            MATCH (p:Place {name: $name})
            WHERE p.location IS NULL
            SET p.geo_status = $status, p.geo_query = $query, p.geo_reason = $reason
            RETURN p.name AS name, p.geo_status AS status
            """, ["name": .string(name), "status": .string(status), "query": query.map(CypherValue.string) ?? .null,
                  "reason": .string(reason)])
    }
}

/// What `saveImport` did.
enum ImportSaveResult: Sendable, Equatable {
    /// `newPlaces`: in draft order, only the places this save created.
    case created(key: String, newPlaces: [String])
    case existing(key: String)

    var key: String {
        switch self {
        case .created(let key, _), .existing(let key): key
        }
    }
}

extension GraphStore {
    func bookExists(key: String) throws -> Bool {
        !(try run(ImportQueries.bookExists(key: key), label: "bookExists").rows.isEmpty)
    }

    /// D5 step 1: the key of the Book with this ISBN, or nil.
    func bookKey(matching isbn: ISBN) throws -> String? {
        try bookMatch(matching: isbn)?.key
    }

    /// The key and title of the Book with this ISBN, or nil.
    func bookMatch(matching isbn: ISBN) throws -> (key: String, title: String?)? {
        guard let row = try run(ImportQueries.bookByISBN(isbn), label: "bookByISBN").rowsView.first,
              let key = row.string("key") else { return nil }
        return (key, row.string("title"))
    }

    /// [] → [] without a query.
    func existingBookKeys(_ keys: [String]) throws -> Set<String> {
        guard !keys.isEmpty else { return [] }
        return Set(try run(ImportQueries.existingBooks(keys: keys), label: "existingBooks").rowsView.compactMap { $0.string("key") })
    }

    func existingAuthorKeys(_ keys: [String]) throws -> Set<String> {
        guard !keys.isEmpty else { return [] }
        return Set(try run(ImportQueries.existingAuthors(keys: keys), label: "existingAuthors").rowsView.compactMap { $0.string("key") })
    }

    /// Input order preserved.
    func missingPlaceNames(_ names: [String]) throws -> [String] {
        guard !names.isEmpty else { return [] }
        let missing = Set(try run(ImportQueries.missingPlaces(names: names), label: "missingPlaces").rowsView.compactMap { $0.string("name") })
        return names.filter { missing.contains($0) }
    }

    /// Saves a draft (D-E, D11, D12):
    /// 1. an existing Book → `.existing` (nothing written);
    /// 2. reads which of the draft's places do not exist yet;
    /// 3. runs W1-W3 in one transaction;
    /// 4. W1 `created` false (a race past step 1) → `.existing`; else
    ///    `.created(key, newPlaces)`, the places this save created.
    func saveImport(_ draft: ImportDraft, now: Date) throws -> ImportSaveResult {
        if try bookExists(key: draft.key) { return .existing(key: draft.key) }
        let newPlaces = try missingPlaceNames(draft.terms.places)
        let results = try transaction(ImportQueries.saveStatements(draft, now: now), label: "saveImport")
        let total = results.reduce(0) { $0 + $1.elapsedMs }
        Log.query.debug("saveImport \(draft.key, privacy: .public): \(results.count) statements in \(total, format: .fixed(precision: 2)) ms")
        guard results.first?.rowsView.first?.bool("created") == true else { return .existing(key: draft.key) }
        return .created(key: draft.key, newPlaces: newPlaces)
    }

    /// The label and point of the nearest located Place within `meters`.
    func nearestPlaceLabel(to c: GeoCoordinate, within meters: Double) throws -> (label: String, coordinate: GeoCoordinate)? {
        guard let row = try run(ImportQueries.nearestLabel(c, radiusMeters: meters), label: "nearestLabel").rowsView.first,
              let label = row.string("label"), let point = row.point("location") else { return nil }
        return (label, point)
    }

    func locatedLabels() throws -> [LocatedLabel] {
        try run(ImportQueries.locatedLabels(), label: "locatedLabels").rowsView.compactMap { row in
            guard let label = row.string("label"), let point = row.point("location") else { return nil }
            return LocatedLabel(label: label, coordinate: point)
        }
    }

    /// False when the place is missing or already has a location.
    @discardableResult
    func writePlaceLocated(name: String, _ write: PlaceLocationWrite) throws -> Bool {
        !(try run(ImportQueries.placeLocated(name: name, write: write), label: "placeLocated").rows.isEmpty)
    }

    /// False when the place is missing or already has a location.
    @discardableResult
    func writePlaceFailed(name: String, status: String, query: String?, reason: String) throws -> Bool {
        !(try run(ImportQueries.placeFailed(name: name, status: status, query: query, reason: reason), label: "placeFailed").rows.isEmpty)
    }
}
