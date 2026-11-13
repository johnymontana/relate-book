import Foundation
import Relate

/// A read-only view over one result record (or one map inside a collected
/// list) with tolerant typed accessors. Queries return scalar columns and
/// collected lists of maps; every model decodes through this.
struct Row: Sendable {
    let values: [String: CypherValue]

    init(_ values: [String: CypherValue]) { self.values = values }

    subscript(_ column: String) -> CypherValue { values[column] ?? .null }

    /// A non-empty string (empty strings decode as nil).
    func string(_ column: String) -> String? {
        guard let s = self[column].stringValue else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : s
    }

    func requiredString(_ column: String) throws -> String {
        guard let s = string(column) else { throw GraphError.missingColumn(column) }
        return s
    }

    /// An integer, also accepting a float with no fraction or a numeric
    /// string (series positions are stored as strings like "4").
    func int(_ column: String) -> Int? {
        switch self[column] {
        case .int(let v): return Int(v)
        case .float(let v) where v.rounded() == v && v.isFinite: return Int(v)
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    func requiredInt(_ column: String) throws -> Int {
        guard let v = int(column) else { throw GraphError.missingColumn(column) }
        return v
    }

    func double(_ column: String) -> Double? { self[column].doubleValue }

    func bool(_ column: String) -> Bool? { self[column].boolValue }

    func url(_ column: String) -> URL? {
        guard let s = string(column), let url = URL(string: s), url.scheme != nil else { return nil }
        return url
    }

    /// An image URL the app can load: `http` is upgraded to `https`, since
    /// App Transport Security blocks plain http (every Author.image_url in
    /// the store is http://commons.wikimedia.org/...; Wikimedia serves the
    /// same path over https). No ATS exception is added.
    func imageURL(_ column: String) -> URL? {
        url(column).map(ImageURLs.secure)
    }

    /// The column's text form whether it is stored as a string or a number
    /// (series positions: "4", 4, or "1.5").
    func text(_ column: String) -> String? {
        switch self[column] {
        case .string: return string(column)
        case .int(let v): return String(v)
        case .float(let v): return v.rounded() == v ? String(Int(v)) : String(v)
        default: return nil
        }
    }

    /// A list of non-empty strings; nulls and non-strings are dropped.
    func strings(_ column: String) -> [String] {
        (self[column].listValue ?? []).compactMap { value in
            guard let s = value.stringValue, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return s
        }
    }

    /// A collected list of maps (`[(..) | {k: v}]`), each as a `Row`.
    func rows(_ column: String) -> [Row] {
        (self[column].listValue ?? []).compactMap { $0.mapValue.map(Row.init) }
    }

    /// A point in time: a DATETIME (components plus offset), a
    /// LOCALDATETIME (read as UTC), or an ISO-8601 string with or without
    /// fractional seconds.
    func instant(_ column: String) -> Date? {
        switch self[column] {
        case .dateTime(let d):
            return Row.gregorianUTC(year: d.year, month: d.month, day: d.day, hour: d.hour, minute: d.minute,
                                    second: d.second, nanosecond: d.nanosecond, offsetSeconds: d.offsetSeconds)
        case .localDateTime(let d):
            return Row.gregorianUTC(year: d.year, month: d.month, day: d.day, hour: d.hour, minute: d.minute,
                                    second: d.second, nanosecond: d.nanosecond, offsetSeconds: 0)
        case .string(let s):
            let text = s.trimmingCharacters(in: .whitespaces)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
            return try? Date.ISO8601FormatStyle().parse(text)
        default:
            return nil
        }
    }

    /// A WGS-84 point column (srid 4326, or 4979 ignoring height) as a
    /// coordinate. For the geographic srids x is longitude and y latitude.
    /// Cartesian points, out-of-range values and non-points decode as nil.
    func point(_ column: String) -> GeoCoordinate? {
        guard let p = self[column].pointValue, p.srid == 4326 || p.srid == 4979,
              p.x.isFinite, p.y.isFinite,
              (-90.0...90.0).contains(p.y), (-180.0...180.0).contains(p.x) else { return nil }
        return GeoCoordinate(latitude: p.y, longitude: p.x)
    }

    /// A calendar day: a DATE, or a "yyyy-MM-dd" string.
    func day(_ column: String) -> LocalDay? {
        switch self[column] {
        case .date(let d):
            return LocalDay(year: Int(d.year), month: Int(d.month), day: Int(d.day))
        case .string(let s):
            return LocalDay(iso: s)
        default:
            return nil
        }
    }

    private static func gregorianUTC(year: Int64, month: Int64, day: Int64, hour: Int64, minute: Int64,
                                     second: Int64, nanosecond: Int64, offsetSeconds: Int64) -> Date? {
        DateComponents(calendar: Calendar(identifier: .gregorian),
                       timeZone: TimeZone(secondsFromGMT: Int(offsetSeconds)),
                       year: Int(year), month: Int(month), day: Int(day),
                       hour: Int(hour), minute: Int(minute), second: Int(second),
                       nanosecond: Int(nanosecond)).date
    }
}

enum ImageURLs {
    /// `http://host/...` → `https://host/...`; Wikimedia `Special:FilePath`
    /// originals (often several MB) also get `?width=400`, a server-side thumbnail.
    static func secure(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        if parts.scheme?.lowercased() == "http" { parts.scheme = "https" }
        if parts.host?.hasSuffix("wikimedia.org") == true,
           parts.percentEncodedPath.contains("Special:FilePath"), parts.query == nil {
            parts.queryItems = [URLQueryItem(name: "width", value: "400")]
        }
        return parts.url ?? url
    }
}

extension QueryResult {
    var rowsView: [Row] { records.map(Row.init) }
}

/// A parameterized Cypher statement. Query builders return these so tests
/// can inspect the text, and `GraphStore.run` executes them.
struct Statement: Sendable, Equatable {
    let cypher: String
    let parameters: [String: CypherValue]

    init(_ cypher: String, _ parameters: [String: CypherValue] = [:]) {
        self.cypher = cypher
        self.parameters = parameters
    }
}

extension GraphStore {
    /// Runs a `Statement` and logs its engine-reported time.
    @discardableResult
    func run(_ statement: Statement, label: String = "query") throws -> QueryResult {
        let result = try query(statement.cypher, statement.parameters)
        Log.query.debug("\(label, privacy: .public): \(result.rows.count) rows in \(result.elapsedMs, format: .fixed(precision: 2)) ms")
        return result
    }
}
