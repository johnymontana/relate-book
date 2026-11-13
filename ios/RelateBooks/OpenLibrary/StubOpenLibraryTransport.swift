#if DEBUG
import Foundation

/// Canned Open Library responses for The Perfect Storm (D-C, D29), for
/// tests and DEBUG `--stub-network`. Routes (exact; `q` compared after
/// percent-decoding, case-insensitively):
///
/// | Request | Response |
/// | --- | --- |
/// | /search.json q=isbn:9780393337013 | search-isbn13.json |
/// | /search.json q=isbn:0393337014 | search-isbn10.json |
/// | /search.json q=key:"/works/OL2670211W" | search-key.json |
/// | /search.json q contains "perfect storm" | search-title.json |
/// | /search.json anything else | search-notfound.json (200) |
/// | /works/OL2670211W.json | work-OL2670211W.json |
/// | /authors/OL389527A.json, /authors/OL2801780A.json | author-<id>.json |
/// | /isbn/9780393337013.json, /isbn/0393337014.json | edition-OL24495814M.json (as if the 302 was followed) |
/// | anything else | 404, empty body |
///
/// Each response waits `latency` first, so the 1.05 s client gate and the
/// progress steps behave as they do against the real service.
actor StubOpenLibraryTransport: HTTPTransport {
    private let latency: Duration
    private let fixtures: [String: String]
    /// Every URL requested, in order.
    private(set) var requestedURLs: [URL] = []

    init(latency: Duration = .milliseconds(150), fixtures: [String: String] = StubOpenLibraryFixtures.all) {
        self.latency = latency
        self.fixtures = fixtures
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        requestedURLs.append(url)
        if latency > .zero { try await Task.sleep(for: latency) }
        if let name = Self.fixtureName(for: url), let body = fixtures[name] {
            return (Data(body.utf8), Self.response(url, status: 200))
        }
        return (Data(), Self.response(url, status: 404))
    }

    /// The fixture file for `url`; nil means 404.
    nonisolated static func fixtureName(for url: URL) -> String? {
        let path = url.path
        if path == "/search.json" {
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "q" }?.value?.lowercased() ?? ""
            switch q {
            case "isbn:9780393337013": return "search-isbn13.json"
            case "isbn:0393337014": return "search-isbn10.json"
            case "key:\"/works/ol2670211w\"": return "search-key.json"
            default: return q.contains("perfect storm") ? "search-title.json" : "search-notfound.json"
            }
        }
        switch path {
        case "/works/OL2670211W.json": return "work-OL2670211W.json"
        case "/authors/OL389527A.json": return "author-OL389527A.json"
        case "/authors/OL2801780A.json": return "author-OL2801780A.json"
        case "/isbn/9780393337013.json", "/isbn/0393337014.json": return "edition-OL24495814M.json"
        default: return nil
        }
    }

    private static func response(_ url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"])!
    }
}
#endif
