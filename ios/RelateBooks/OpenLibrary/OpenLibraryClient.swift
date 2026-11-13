import Foundation

/// Why an Open Library request failed. A 404 is not an error: the record
/// does not exist and the call returns nil.
enum OpenLibraryError: Error, Equatable, LocalizedError {
    /// URLError .notConnectedToInternet, .networkConnectionLost,
    /// .dataNotAllowed, .cannotFindHost, .cannotConnectToHost,
    /// .internationalRoamingOff.
    case offline
    /// URLError .timedOut.
    case timedOut
    /// Any other non-2xx status (after the one 429/503 retry).
    case http(Int)
    /// 429/503 whose Retry-After was over 5 s (not retried; every caller
    /// waits it out through the gate, D3).
    case rateLimited(seconds: Int)
    /// Not JSON, or not a JSON object.
    case invalidResponse(String)
    /// Any other URLError (its localized description).
    case transport(String)

    /// D32 copy.
    var errorDescription: String? {
        switch self {
        case .offline:
            "You're offline. Adding a book needs Open Library; the rest of the app works offline."
        case .timedOut:
            "Open Library didn't answer in time. Try again in a moment."
        case .http(let status):
            "Open Library didn't answer (HTTP \(status)). Try again in a moment."
        case .rateLimited(let seconds):
            "Open Library asked us to slow down; try again in \(seconds) s."
        case .invalidResponse(let detail):
            "Open Library sent an unexpected answer (\(detail))."
        case .transport(let detail):
            "Couldn't reach Open Library: \(detail)"
        }
    }

    /// Maps a URLError; `.cancelled` is nil (the caller throws CancellationError).
    static func from(_ error: URLError) -> OpenLibraryError? {
        switch error.code {
        case .cancelled:
            return nil
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .cannotFindHost,
             .cannotConnectToHost, .internationalRoamingOff:
            return .offline
        case .timedOut:
            return .timedOut
        default:
            return .transport(error.localizedDescription)
        }
    }
}

/// Anonymous Open Library client (D-A, D1-D3).
///
/// - One request in flight, FIFO; each start is at least `minimumInterval`
///   after the previous start (Open Library allows about 1 request/s
///   anonymously; 1.05 s is the extension's anonymous interval).
/// - Every request sends `User-Agent: RelateBooks/<version>
///   (+https://github.com/johnymontana/relate-book)` and `Accept:
///   application/json`. No contact string and no e-mail address.
/// - 404 → nil. 429/503 → one retry when Retry-After is absent (after
///   `retryDelay`, 2 s) or at most 5 s (after that long); a longer
///   Retry-After is not retried: the call throws `.rateLimited(seconds:)`
///   and the gate holds every later caller until it has passed.
/// - A caller cancelled while waiting for its turn throws CancellationError
///   and never sends; a request in flight is cancelled through task
///   cancellation (URLSession honours it).
actor OpenLibraryClient {
    static let baseURL = URL(string: "https://openlibrary.org")!
    /// The extension's `OL_SEARCH_FIELDS` minus `isbn` (a huge list, unused)
    /// and `editions.id_amazon` (it only matches an ASIN).
    static let docFields: [String] = [
        "key", "title", "subtitle", "author_key", "author_name", "first_publish_year", "cover_i",
        "subject", "place", "person", "time", "ratings_average", "ratings_count", "readinglog_count",
        "want_to_read_count", "currently_reading_count", "already_read_count", "number_of_pages_median",
        "edition_count", "first_sentence", "language", "id_goodreads", "id_amazon", "editions",
        "editions.key", "editions.title", "editions.isbn", "editions.publisher", "editions.publish_date",
        "editions.number_of_pages", "editions.physical_format", "editions.language",
    ]
    /// Result rows only.
    static let listFields: [String] = [
        "key", "title", "author_name", "author_key", "cover_i", "first_publish_year", "edition_count",
    ]
    static let searchLimit = 20
    static let minimumSearchLength = 3
    /// 1.05 s, the extension's anonymous interval (D2): a margin under 1 req/s,
    /// since the gap is measured between local starts.
    static let defaultInterval: Duration = .milliseconds(1050)
    /// The longest Retry-After the client waits out with one retry (D3).
    static let maximumRetryWait = 5
    static let requestTimeout: TimeInterval = 15

    /// "RelateBooks/0.1.0 (+https://github.com/johnymontana/relate-book)"
    static func userAgent(appVersion: String) -> String {
        "RelateBooks/\(appVersion) (+https://github.com/johnymontana/relate-book)"
    }

    nonisolated let userAgent: String
    nonisolated let minimumInterval: Duration
    /// Requests actually sent, the retry included (tests, logs).
    private(set) var requestCount = 0

    private let transport: any HTTPTransport
    /// The client's FIFO gate (tests read `waiterCount`).
    let gate: RequestGate
    private let retryDelay: Duration

    /// `retryDelay`: the wait before the one retry when a 429/503 has no
    /// Retry-After (2 s; tests pass a few ms).
    init(transport: any HTTPTransport, appVersion: String = "0.1.0",
         minimumInterval: Duration = OpenLibraryClient.defaultInterval,
         retryDelay: Duration = .seconds(2)) {
        self.transport = transport
        self.userAgent = Self.userAgent(appVersion: appVersion)
        self.minimumInterval = minimumInterval
        self.retryDelay = retryDelay
        self.gate = RequestGate(minimumInterval: minimumInterval)
    }

    // MARK: Endpoints

    /// Free-text search for the result list: `q=<text>`, `listFields`,
    /// `limit`. Trims `text`; fewer than 3 characters returns [] without a
    /// request. Docs that are not works are dropped.
    func search(text: String, limit: Int = OpenLibraryClient.searchLimit) async throws -> [OLSearchDoc] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= Self.minimumSearchLength else { return [] }
        let json = try await getJSON(Self.searchURL(q: query, fields: Self.listFields, limit: limit))
        return OLSearchResponse(json: json ?? .null).docs
    }

    /// `q=isbn:<isbn>`, `docFields`, limit 1. The editions sub-doc is
    /// filtered to that ISBN.
    func searchISBN(_ isbn: String) async throws -> [OLSearchDoc] {
        let json = try await getJSON(Self.searchURL(q: "isbn:\(isbn)", fields: Self.docFields, limit: 1))
        return OLSearchResponse(json: json ?? .null).docs
    }

    /// `q=key:"<workKey>"`, `docFields`, limit 1; nil when there is no doc.
    func searchWork(key: String) async throws -> OLSearchDoc? {
        let json = try await getJSON(Self.searchURL(q: "key:\"\(key)\"", fields: Self.docFields, limit: 1))
        return OLSearchResponse(json: json ?? .null).docs.first
    }

    /// `GET <workKey>.json`; nil on 404.
    func work(key: String) async throws -> OLWork? {
        try await getJSON(Self.recordURL(path: key)).map(OLWork.init(json:))
    }

    /// `GET <authorKey>.json` (a key like "/authors/OL389527A"); nil on 404.
    func author(key: String) async throws -> OLAuthor? {
        try await getJSON(Self.recordURL(path: key)).map(OLAuthor.init(json:))
    }

    /// `GET /isbn/<isbn>.json` (302 → /books/OL…M.json, followed); nil on 404.
    func edition(isbn: String) async throws -> OLEdition? {
        try await getJSON(Self.recordURL(path: "/isbn/\(isbn)")).map(OLEdition.init(json:))
    }

    // MARK: URLs

    /// `https://openlibrary.org/search.json?q=…&fields=a,b,c&limit=N`. The
    /// comma-separated field list is one query item.
    nonisolated static func searchURL(q: String, fields: [String], limit: Int) -> URL {
        var parts = URLComponents(url: baseURL.appendingPathComponent("search.json"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "fields", value: fields.joined(separator: ",")),
            URLQueryItem(name: "limit", value: String(max(1, limit))),
        ]
        return parts.url!
    }

    /// `https://openlibrary.org<path>.json` for a key path like "/works/OL1W".
    nonisolated static func recordURL(path: String) -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "openlibrary.org"
        parts.path = (path.hasPrefix("/") ? path : "/" + path) + ".json"
        return parts.url!
    }

    // MARK: Sending

    /// The JSON object at `url`; nil on 404. Throws `OpenLibraryError`
    /// (`.invalidResponse` when the body is not a JSON object) or
    /// CancellationError.
    private func getJSON(_ url: URL) async throws -> JSONValue? {
        guard let data = try await send(url) else { return nil }
        let json = try JSONValue.parse(data)
        guard json.isObject else { throw OpenLibraryError.invalidResponse("not a JSON object") }
        return json
    }

    /// One gated send plus at most one gated retry for 429/503 (D3).
    private func send(_ url: URL) async throws -> Data? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var retried = false
        while true {
            let (data, response) = try await gate.withGate { try await self.perform(request) }
            let status = response.statusCode
            if (200..<300).contains(status) { return data }
            if status == 404 { return nil }
            guard status == 429 || status == 503 else { throw OpenLibraryError.http(status) }
            let retryAfter = Self.retryAfterSeconds(response)
            if let seconds = retryAfter, seconds > Self.maximumRetryWait {
                await gate.delayNextStart(by: .seconds(seconds))
                Log.store.notice("Open Library rate limited (HTTP \(status)); Retry-After \(seconds) s")
                throw OpenLibraryError.rateLimited(seconds: seconds)
            }
            if retried {
                if let seconds = retryAfter {
                    await gate.delayNextStart(by: .seconds(seconds))
                    throw OpenLibraryError.rateLimited(seconds: seconds)
                }
                throw OpenLibraryError.http(status)
            }
            retried = true
            await gate.delayNextStart(by: retryAfter.map { .seconds($0) } ?? retryDelay)
        }
    }

    /// Runs inside the gate: one transport call, counted.
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        requestCount += 1
        // The path only (a search's text stays out of the log).
        Log.store.notice("Open Library request \(self.requestCount, privacy: .public): \(request.url?.path ?? "?", privacy: .public)")
        do {
            return try await transport.data(for: request)
        } catch let error as URLError {
            if let mapped = OpenLibraryError.from(error) { throw mapped }
            throw CancellationError()
        }
    }

    /// `Retry-After` as a non-negative integer number of seconds; an
    /// HTTP-date or anything else counts as absent.
    nonisolated static func retryAfterSeconds(_ response: HTTPURLResponse) -> Int? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              let seconds = Int(value), seconds >= 0 else { return nil }
        return seconds
    }
}
