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
///   $now`, so when the Book pre-existed nothing else is written
///   (D11).
/// - `added_on = $now` lands on every node the import creates
///   (Book, Author, Subject, Place, Person, Era, Genre; D9), ON CREATE only.
/// - `$now` is the import's `Date`, bound as a UTC DATETIME; every statement
///   of one save binds the same instant, which is what the guard compares.
enum ImportQueries {
    /// The five term writes, in this order.
    static let termTargets: [TermTarget] = TermTarget.allCases

    static func bookExists(key: String) throws -> Statement {
        try Statement("MATCH (b:Book {key: $key}) RETURN b.key AS key", ["key": key])
    }

    /// The Book whose wishlist Item has this ISBN-13 (or ISBN-10), or whose
    /// own `isbn13` (an earlier app import) matches. `$isbn10` is null for 979.
    static func bookByISBN(_ isbn: ISBN) throws -> Statement {
        try Statement("""
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
            """, ["isbn13": isbn.isbn13, "isbn10": isbn.isbn10])
    }

    static func existingBooks(keys: [String]) throws -> Statement {
        try Statement("""
            UNWIND $keys AS k
            MATCH (b:Book {key: k})
            RETURN b.key AS key
            """, ["keys": keys])
    }

    static func existingAuthors(keys: [String]) throws -> Statement {
        try Statement("""
            UNWIND $keys AS k
            MATCH (a:Author {key: k})
            RETURN a.key AS key
            """, ["keys": keys])
    }

    /// The names with no Place node yet, in input order (D12).
    static func missingPlaces(names: [String]) throws -> Statement {
        try Statement("""
            UNWIND $names AS name
            OPTIONAL MATCH (p:Place {name: name})
            WITH name, p
            WHERE p IS NULL
            RETURN name
            """, ["names": names])
    }

    /// W1. `created` is true when this statement created the Book (also on
    /// an exact replay with the same `$now`), false when it existed.
    static func saveBook(_ draft: ImportDraft, now: Date) throws -> Statement {
        try Statement("""
            MERGE (b:Book {key: $key})
            ON CREATE SET b += $props, b.source = 'app', b.match = $match, b.added_on = $now
            RETURN b.key AS key, b.added_on = $now AS created
            """, [
                "key": draft.key,
                "props": draft.properties,
                "match": draft.match.rawValue,
                "now": now,
            ])
    }

    /// W2. Existing authors only gain the WRITTEN_BY edge (D6).
    static func saveAuthors(key: String, authors: [ImportAuthor], now: Date) throws -> Statement {
        let rows: [CypherValue] = authors.map { author in
            .map(["key": .string(author.key), "source": .string(author.source), "props": .map(author.properties)])
        }
        return try Statement("""
            MATCH (b:Book {key: $key}) WHERE b.added_on = $now
            UNWIND $authors AS a
            MERGE (au:Author {key: a.key})
            ON CREATE SET au += a.props, au.source = a.source, au.added_on = $now
            MERGE (b)-[w:WRITTEN_BY]->(au)
            SET w.role = 'Author'
            RETURN count(au) AS authors
            """, ["key": key, "authors": rows, "now": now])
    }

    /// W3 for one term list; the label and relationship come from `target`.
    static func saveTerms(_ target: TermTarget, key: String, names: [String], now: Date) throws -> Statement {
        try Statement("""
            MATCH (b:Book {key: $key}) WHERE b.added_on = $now
            UNWIND $names AS name
            MERGE (t:\(target.label) {name: name})
            ON CREATE SET t.added_on = $now
            MERGE (b)-[:\(target.relationship)]->(t)
            RETURN count(t) AS terms
            """, ["key": key, "names": names, "now": now])
    }

    /// W1, then W2 if there are authors, then one W3 per non-empty list.
    static func saveStatements(_ draft: ImportDraft, now: Date) throws -> [Statement] {
        var statements = [try saveBook(draft, now: now)]
        if !draft.authors.isEmpty {
            statements.append(try saveAuthors(key: draft.key, authors: draft.authors, now: now))
        }
        for target in termTargets {
            let names = target.names(in: draft.terms)
            if !names.isEmpty {
                statements.append(try saveTerms(target, key: draft.key, names: names, now: now))
            }
        }
        return statements
    }

    /// The nearest labelled, located Place within `radiusMeters` (POINT
    /// index; the 1 km label reuse rule, D15).
    static func nearestLabel(_ c: GeoCoordinate, radiusMeters: Double) throws -> Statement {
        try Statement("""
            MATCH (p:Place)
            WHERE point.distance(p.location, $center) < $radius AND p.geocoded_label IS NOT NULL
            WITH p, point.distance(p.location, $center) AS meters
            RETURN p.geocoded_label AS label, p.location AS location, meters
            ORDER BY meters, label
            LIMIT 1
            """, ["center": try c.point(), "radius": radiusMeters])
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
    static func placeLocated(name: String, write: PlaceLocationWrite) throws -> Statement {
        try Statement("""
            MATCH (p:Place {name: $name})
            WHERE p.location IS NULL
            SET p.location = $location, p.geocoded_label = $label,
                p.geo_source = $source, p.geo_status = 'ok', p.geo_lat = $rawLat, p.geo_lon = $rawLon,
                p.geo_display_name = $displayName, p.geo_place_type = $placeType, p.geo_query = $query,
                p.geo_region = $region
            RETURN p.name AS name, p.geocoded_label AS label
            """, [
                "name": name,
                "location": try write.coordinate.point(),
                "label": write.label, "source": write.source,
                "rawLat": write.raw.latitude, "rawLon": write.raw.longitude,
                "displayName": write.displayName, "placeType": write.placeType,
                "query": write.query, "region": write.region,
            ])
    }

    /// `$status` is 'unresolved' or 'skipped'; `$query` may be null. A
    /// no-op when the place already has a `location`.
    static func placeFailed(name: String, status: String, query: String?, reason: String) throws -> Statement {
        try Statement("""
            MATCH (p:Place {name: $name})
            WHERE p.location IS NULL
            SET p.geo_status = $status, p.geo_query = $query, p.geo_reason = $reason
            RETURN p.name AS name, p.geo_status AS status
            """, ["name": name, "status": status, "query": query,
                  "reason": reason])
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
    func bookExists(key: String) async throws -> Bool {
        !(try await read(ImportQueries.bookExists(key: key)).rows.isEmpty)
    }

    /// D5 step 1: the key of the Book with this ISBN, or nil.
    func bookKey(matching isbn: ISBN) async throws -> String? {
        try await bookMatch(matching: isbn)?.key
    }

    /// The key and title of the Book with this ISBN, or nil.
    func bookMatch(matching isbn: ISBN) async throws -> (key: String, title: String?)? {
        guard let row = try await readWithSubquery(ImportQueries.bookByISBN(isbn)).rowsView.first,
              let key = row.string("key") else { return nil }
        return (key, row.string("title"))
    }

    /// [] → [] without a query.
    func existingBookKeys(_ keys: [String]) async throws -> Set<String> {
        guard !keys.isEmpty else { return [] }
        return Set(try await read(ImportQueries.existingBooks(keys: keys)).rowsView.compactMap { $0.string("key") })
    }

    func existingAuthorKeys(_ keys: [String]) async throws -> Set<String> {
        guard !keys.isEmpty else { return [] }
        return Set(try await read(ImportQueries.existingAuthors(keys: keys)).rowsView.compactMap { $0.string("key") })
    }

    /// Input order preserved.
    func missingPlaceNames(_ names: [String]) async throws -> [String] {
        guard !names.isEmpty else { return [] }
        let missing = Set(try await read(ImportQueries.missingPlaces(names: names)).rowsView.compactMap { $0.string("name") })
        return names.filter { missing.contains($0) }
    }

    /// Saves a draft (D-E, D11, D12), as one write transaction:
    /// 1. an existing Book → `.existing` (nothing written);
    /// 2. reads which of the draft's places do not exist yet;
    /// 3. runs W1-W3;
    /// 4. W1 `created` false → `.existing`; else `.created(key, newPlaces)`,
    ///    the places this save created.
    ///
    /// The checks and the writes share the transaction, so no other write
    /// lands between them: writes through the store run one at a time.
    func saveImport(_ draft: ImportDraft, now: Date) async throws -> ImportSaveResult {
        let key = draft.key
        let places = draft.terms.places
        let exists = try ImportQueries.bookExists(key: key)
        let missing = places.isEmpty ? nil : try ImportQueries.missingPlaces(names: places)
        let save = try ImportQueries.saveStatements(draft, now: now)
        return try await database.write { tx in
            if !(try tx.run(exists).isEmpty) { return .existing(key: key) }
            var newPlaces: [String] = []
            if let missing {
                let absent = Set(try tx.run(missing).rowsView.compactMap { $0.string("name") })
                newPlaces = places.filter { absent.contains($0) }
            }
            let results = try tx.run(save)
            guard results.first?.rowsView.first?.bool("created") == true else { return .existing(key: key) }
            return .created(key: key, newPlaces: newPlaces)
        }
    }

    /// The label and point of the nearest located Place within `meters`.
    func nearestPlaceLabel(to c: GeoCoordinate, within meters: Double) async throws -> (label: String, coordinate: GeoCoordinate)? {
        guard let row = try await read(ImportQueries.nearestLabel(c, radiusMeters: meters)).rowsView.first,
              let label = row.string("label"), let point = row.point("location") else { return nil }
        return (label, point)
    }

    func locatedLabels() async throws -> [LocatedLabel] {
        try await read(ImportQueries.locatedLabels()).rowsView.compactMap { row in
            guard let label = row.string("label"), let point = row.point("location") else { return nil }
            return LocatedLabel(label: label, coordinate: point)
        }
    }

    /// False when the place is missing or already has a location.
    @discardableResult
    func writePlaceLocated(name: String, _ write: PlaceLocationWrite) async throws -> Bool {
        !(try await self.write(ImportQueries.placeLocated(name: name, write: write)).rows.isEmpty)
    }

    /// False when the place is missing or already has a location.
    @discardableResult
    func writePlaceFailed(name: String, status: String, query: String?, reason: String) async throws -> Bool {
        !(try await write(ImportQueries.placeFailed(name: name, status: status, query: query, reason: reason)).rows.isEmpty)
    }
}
