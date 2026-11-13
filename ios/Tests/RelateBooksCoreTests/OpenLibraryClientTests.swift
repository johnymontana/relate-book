import Testing
import Foundation
@testable import RelateBooksCore

@Suite("Open Library client")
struct OpenLibraryClientTests {
    static func client(_ transport: FakeTransport, interval: Duration = .zero,
                       retryDelay: Duration = .milliseconds(10)) -> OpenLibraryClient {
        OpenLibraryClient(transport: transport, minimumInterval: interval, retryDelay: retryDelay)
    }

    @Test("User-Agent (no contact, no e-mail) and Accept headers")
    func headers() async throws {
        let transport = FakeTransport(FakeTransport.perfectStormRoutes())
        let client = Self.client(transport)
        #expect(client.userAgent == "RelateBooks/0.1.0 (+https://github.com/johnymontana/relate-book)")
        #expect(!client.userAgent.contains("@"))
        #expect(OpenLibraryClient.userAgent(appVersion: "1.2") == "RelateBooks/1.2 (+https://github.com/johnymontana/relate-book)")
        _ = try await client.searchISBN("9780393337013")
        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == client.userAgent)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(OpenLibraryClient.defaultInterval == .milliseconds(1050))
    }

    @Test("URLs: one fields item, limits, record paths")
    func urls() {
        let isbn = OpenLibraryClient.searchURL(q: "isbn:9780393337013", fields: OpenLibraryClient.docFields, limit: 1).absoluteString
        #expect(isbn.hasPrefix("https://openlibrary.org/search.json?"))
        #expect(isbn.contains("q=isbn:9780393337013"))
        #expect(isbn.contains("fields=key,title,subtitle,author_key,"))
        #expect(isbn.contains("editions.physical_format,editions.language"))
        #expect(isbn.hasSuffix("limit=1"))
        let list = OpenLibraryClient.searchURL(q: "perfect storm", fields: OpenLibraryClient.listFields, limit: 20).absoluteString
        #expect(list.contains("q=perfect%20storm") && list.contains("limit=20"))
        #expect(list.contains("fields=key,title,author_name,author_key,cover_i,first_publish_year,edition_count"))
        #expect(!OpenLibraryClient.docFields.contains("isbn") && !OpenLibraryClient.docFields.contains("editions.id_amazon"))
        #expect(OpenLibraryClient.recordURL(path: "/works/OL2670211W").absoluteString == "https://openlibrary.org/works/OL2670211W.json")
        #expect(OpenLibraryClient.recordURL(path: "/isbn/9780393337013").absoluteString == "https://openlibrary.org/isbn/9780393337013.json")
    }

    @Test("search: fewer than 3 characters makes no request; results drop non-works")
    func searchRules() async throws {
        let transport = FakeTransport(FakeTransport.perfectStormRoutes())
        let client = Self.client(transport)
        #expect(try await client.search(text: " ab ").isEmpty)
        #expect(await transport.requestCount == 0)
        let docs = try await client.search(text: "  perfect storm ")
        #expect(docs.count == 19)
        #expect(await transport.paths == ["/search.json?q=perfect storm"])
    }

    @Test("404 is nil for work, author and edition")
    func notFound() async throws {
        let client = Self.client(FakeTransport())
        #expect(try await client.work(key: "/works/OL1W") == nil)
        #expect(try await client.author(key: "/authors/OL1A") == nil)
        #expect(try await client.edition(isbn: "9780393337013") == nil)
        #expect(try await client.searchWork(key: "/works/OL1W") == nil)
    }

    @Test("503 with Retry-After 0 is retried once; 500 is an error")
    func retryOnce() async throws {
        let transport = FakeTransport(["/works/OL2670211W.json": [.status(503, retryAfter: "0"), .fixture("work-OL2670211W.json")],
                                       "/works/OL1W.json": [.status(500)]])
        let client = Self.client(transport)
        #expect(try await client.work(key: "/works/OL2670211W")?.title == "The Perfect Storm")
        #expect(await client.requestCount == 2)
        await #expect(throws: OpenLibraryError.http(500)) { try await client.work(key: "/works/OL1W") }
        #expect(await client.requestCount == 3)
    }

    @Test("429 without Retry-After twice → .http(429) after one retry")
    func retryTwice() async throws {
        let transport = FakeTransport(["/works/OL1W.json": [.status(429)]])
        let client = Self.client(transport)
        await #expect(throws: OpenLibraryError.http(429)) { try await client.work(key: "/works/OL1W") }
        #expect(await client.requestCount == 2)
    }

    @Test("a long Retry-After is not retried and holds every later caller")
    func longRetryAfter() async throws {
        let transport = FakeTransport(["/works/OL1W.json": [.status(429, retryAfter: "30")],
                                       "/works/OL2670211W.json": [.fixture("work-OL2670211W.json")]])
        let client = Self.client(transport)
        await #expect(throws: OpenLibraryError.rateLimited(seconds: 30)) { try await client.work(key: "/works/OL1W") }
        #expect(await client.requestCount == 1)
        #expect(OpenLibraryError.rateLimited(seconds: 30).errorDescription == "Open Library asked us to slow down; try again in 30 s.")
        let held = Task { try await client.work(key: "/works/OL2670211W") }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await transport.requestCount == 1)
        held.cancel()
        await #expect(throws: CancellationError.self) { try await held.value }
        #expect(await transport.paths == ["/works/OL1W.json"])
    }

    @Test("429 with Retry-After 5 is retried after 5 s", .timeLimit(.minutes(1)))
    func retryAfterFive() async throws {
        let transport = FakeTransport(["/works/OL2670211W.json": [.status(429, retryAfter: "5"), .fixture("work-OL2670211W.json")]])
        let client = Self.client(transport)
        #expect(try await client.work(key: "/works/OL2670211W") != nil)
        #expect(await client.requestCount == 2)
        let starts = await transport.startTimes
        #expect(starts[1] - starts[0] >= .seconds(5))
    }

    @Test("URLSessionTransport keeps nothing: ephemeral, no cache, no cookies, 15 s timeout")
    func sessionConfiguration() {
        let configuration = URLSessionTransport.makeSession().configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.timeoutIntervalForRequest == 15)
        #expect(configuration.timeoutIntervalForResource == 30)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("URLErrors map to offline / timedOut")
    func urlErrors() async throws {
        let transport = FakeTransport(["/works/OL1W.json": [.failure(.notConnectedToInternet)],
                                       "/works/OL2W.json": [.failure(.timedOut)],
                                       "/works/OL3W.json": [.failure(.cannotFindHost)]])
        let client = Self.client(transport)
        await #expect(throws: OpenLibraryError.offline) { try await client.work(key: "/works/OL1W") }
        await #expect(throws: OpenLibraryError.timedOut) { try await client.work(key: "/works/OL2W") }
        await #expect(throws: OpenLibraryError.offline) { try await client.work(key: "/works/OL3W") }
        #expect(OpenLibraryError.offline.errorDescription == "You're offline. Adding a book needs Open Library; the rest of the app works offline.")
        #expect(OpenLibraryError.http(503).errorDescription == "Open Library didn't answer (HTTP 503). Try again in a moment.")
    }

    @Test("a body that is not a JSON object is an invalid response")
    func invalidBody() async throws {
        let transport = FakeTransport(["/works/OL1W.json": [FakeTransport.Reply(body: Data("[]".utf8))],
                                       "/works/OL2W.json": [FakeTransport.Reply(body: Data("<html>".utf8))]])
        let client = Self.client(transport)
        await #expect(throws: OpenLibraryError.invalidResponse("not a JSON object")) { try await client.work(key: "/works/OL1W") }
        await #expect(throws: OpenLibraryError.invalidResponse("not JSON")) { try await client.work(key: "/works/OL2W") }
    }

    @Test("rate: three concurrent calls start at least the interval apart, one at a time")
    func rate() async throws {
        let transport = FakeTransport(FakeTransport.perfectStormRoutes(), delay: .milliseconds(5))
        let client = Self.client(transport, interval: .milliseconds(60))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { _ = try await client.work(key: "/works/OL2670211W") } }
            try await group.waitForAll()
        }
        let starts = await transport.startTimes
        #expect(starts.count == 3)
        for i in 1..<starts.count {
            #expect(starts[i] - starts[i - 1] >= .milliseconds(58))
        }
        #expect(await transport.maxConcurrent == 1)
    }

    @Test("a caller cancelled while queued never sends (and 50 cancel races lose nothing)")
    func cancelWhileQueued() async throws {
        let transport = FakeTransport(FakeTransport.perfectStormRoutes())
        let client = Self.client(transport)
        await transport.hold()
        let first = Task { try await client.work(key: "/works/OL2670211W") }
        #expect(await waitUntil { await transport.requestCount == 1 })
        let second = Task { try await client.author(key: "/authors/OL389527A") }
        #expect(await waitUntil { await client.gate.waiterCount == 1 })
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        await transport.release()
        #expect(try await first.value != nil)
        #expect(await transport.paths == ["/works/OL2670211W.json"])

        for i in 0..<50 {
            await transport.hold()
            let before = await transport.requestCount
            let holder = Task { try await client.work(key: "/works/OL2670211W") }
            #expect(await waitUntil { await transport.requestCount == before + 1 })
            let racer = Task { try await client.author(key: "/authors/OL389527A") }
            switch i % 3 {
            case 0:
                racer.cancel()
            case 1:
                await Task.yield()
                racer.cancel()
            default:
                await Task.yield()
                await transport.release()
                await Task.yield()
                racer.cancel()
            }
            await transport.release()
            _ = try await holder.value
            do {
                _ = try await racer.value
            } catch is CancellationError {
                // fine: cancelled before or while queued, or mid-request
            }
        }
        #expect(await client.gate.waiterCount == 0)
        #expect(try await client.author(key: "/authors/OL2801780A")?.name == "Anne Collins")
    }
}

@Suite("Request gate")
struct RequestGateTests {
    actor Order {
        var values: [Int] = []
        func add(_ v: Int) { values.append(v) }
    }

    @Test("waiters run in FIFO order")
    func fifo() async throws {
        let gate = RequestGate()
        let order = Order()
        try await gate.acquire()
        var tasks: [Task<Void, Error>] = []
        for i in 0..<5 {
            tasks.append(Task { try await gate.withGate { await order.add(i) } })
            #expect(await waitUntil { await gate.waiterCount == i + 1 })
        }
        await gate.release()
        for task in tasks { try await task.value }
        #expect(await order.values == [0, 1, 2, 3, 4])
        #expect(await gate.waiterCount == 0)
    }

    @Test("delayNextStart holds the next acquire")
    func delay() async throws {
        let gate = RequestGate()
        await gate.delayNextStart(by: .milliseconds(100))
        let start = ContinuousClock.now
        try await gate.withGate { }
        #expect(ContinuousClock.now - start >= .milliseconds(95))
    }

    @Test("withGate releases after a throwing body")
    func releasesOnThrow() async throws {
        struct Boom: Error {}
        let gate = RequestGate(minimumInterval: .zero)
        await #expect(throws: Boom.self) { try await gate.withGate { throw Boom() } }
        let start = ContinuousClock.now
        try await gate.withGate { }
        #expect(ContinuousClock.now - start < .milliseconds(50))
    }
}
