import Foundation

/// The one seam between the app and the network (phase 5, D-B). Core tests
/// pass a fake; the app passes `URLSessionTransport`, or
/// `StubOpenLibraryTransport` under DEBUG `--stub-network`.
protocol HTTPTransport: Sendable {
    /// Performs `request` and returns the body and the final HTTP response
    /// (after redirects). Throws `URLError` or `CancellationError`; never
    /// throws for a non-2xx status (the caller decides).
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession with a 15 s request timeout, no cookies, no response cache,
/// and redirects followed (Open Library's `/isbn/` answers 302). Search URLs
/// carry the user's search text, so nothing is kept on disk (C11).
struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    init(session: URLSession = URLSessionTransport.makeSession()) {
        self.session = session
    }

    /// `URLSessionConfiguration.ephemeral` with a 15 s request (idle)
    /// timeout and a 30 s resource (overall) timeout, no
    /// URL cache, `.reloadIgnoringLocalCacheData`, and no cookie storage or
    /// cookie handling. A core test asserts these values.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        // Overall cap per request: a server trickling bytes would never
        // hit the 15 s idle timeout and "Looking up…" would spin forever.
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenLibraryError.invalidResponse("not an HTTP response")
        }
        return (data, http)
    }
}
