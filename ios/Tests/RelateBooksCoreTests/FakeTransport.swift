import Foundation
@testable import RelateBooksCore

/// A scripted `HTTPTransport` for the Open Library tests (no network).
///
/// Routes are keyed by `"<path>?q=<decoded q>"` for searches or by
/// `"<path>"`; each route is a list of replies served in order, the last
/// one repeating. Unknown routes answer 404. It records every request,
/// its start time and the highest number of requests in flight, and can
/// hold requests until `release()` (a "gate") or delay each one.
actor FakeTransport: HTTPTransport {
    struct Reply: Sendable {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
        var error: URLError?

        /// A recorded fixture with status 200.
        static func fixture(_ name: String) -> Reply {
            Reply(body: (try? FixtureFiles.openLibrary(name)) ?? Data())
        }

        static func status(_ status: Int, retryAfter: String? = nil) -> Reply {
            Reply(status: status, headers: retryAfter.map { ["Retry-After": $0] } ?? [:])
        }

        static func failure(_ code: URLError.Code) -> Reply {
            Reply(error: URLError(code))
        }
    }

    private var routes: [String: [Reply]]
    private(set) var requests: [URLRequest] = []
    private(set) var startTimes: [ContinuousClock.Instant] = []
    private(set) var maxConcurrent = 0
    private var current = 0
    private var delay: Duration
    private var isHeld = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ routes: [String: [Reply]] = [:], delay: Duration = .zero) {
        self.routes = routes
        self.delay = delay
    }

    /// The Perfect Storm's routes, like `StubOpenLibraryTransport`.
    static func perfectStormRoutes() -> [String: [Reply]] {
        [
            "/search.json?q=isbn:9780393337013": [.fixture("search-isbn13.json")],
            "/search.json?q=isbn:0393337014": [.fixture("search-isbn10.json")],
            "/search.json?q=key:\"/works/OL2670211W\"": [.fixture("search-key.json")],
            "/search.json?q=perfect storm": [.fixture("search-title.json")],
            "/works/OL2670211W.json": [.fixture("work-OL2670211W.json")],
            "/authors/OL389527A.json": [.fixture("author-OL389527A.json")],
            "/authors/OL2801780A.json": [.fixture("author-OL2801780A.json")],
        ]
    }

    var urls: [URL] { requests.compactMap(\.url) }
    var requestCount: Int { requests.count }
    var paths: [String] { urls.map(Self.key) }

    func setRoute(_ key: String, _ replies: [Reply]) { routes[key] = replies }
    func setDelay(_ delay: Duration) { self.delay = delay }

    /// Holds every later request until `release()`.
    func hold() { isHeld = true }

    func release() {
        isHeld = false
        let waiters = heldWaiters
        heldWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        requests.append(request)
        startTimes.append(.now)
        current += 1
        maxConcurrent = max(maxConcurrent, current)
        defer { current -= 1 }
        if delay > .zero { try await Task.sleep(for: delay) }
        if isHeld { await withCheckedContinuation { heldWaiters.append($0) } }
        let key = Self.key(url)
        let routeKey = routes[key] != nil ? key : url.path
        guard var replies = routes[routeKey], let reply = replies.first else {
            return (Data(), Self.response(url, 404, [:]))
        }
        if replies.count > 1 {
            replies.removeFirst()
            routes[routeKey] = replies
        }
        if let error = reply.error { throw error }
        return (reply.body, Self.response(url, reply.status, reply.headers))
    }

    static func key(_ url: URL) -> String {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        return url.path + (q.map { "?q=" + $0 } ?? "")
    }

    private static func response(_ url: URL, _ status: Int, _ headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Records every `UserDataChange` a controller publishes.
@MainActor
final class ChangeRecorder {
    private(set) var changes: [UserDataChange] = []

    init(_ controller: UserDataController) {
        controller.subscribe(self) { [weak self] change in self?.changes.append(change) }
    }

    var placesLocatedLabels: [[String]] {
        changes.compactMap { if case .placesLocated(let labels) = $0 { return labels } else { return nil } }
    }

    var addedKeys: [String] {
        changes.compactMap { if case .bookAdded(let key) = $0 { return key } else { return nil } }
    }
}
