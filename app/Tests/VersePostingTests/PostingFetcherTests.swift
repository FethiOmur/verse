import Foundation
import XCTest
@testable import VersePosting

/// URLProtocol stub: no test touches the network. Responses are keyed by exact URL string.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply { case body(Data, status: Int), failure(URLError.Code) }
    nonisolated(unsafe) static var replies: [String: Reply] = [:]
    nonisolated(unsafe) static var requested: [String] = []
    private static let lock = NSLock()

    static func reset() { lock.withLock { replies = [:]; requested = [] } }
    static func set(_ url: String, _ reply: Reply) { lock.withLock { replies[url] = reply } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = request.url!.absoluteString
        let reply = StubProtocol.lock.withLock { () -> Reply? in
            StubProtocol.requested.append(key)
            return StubProtocol.replies[key]
        }
        switch reply {
        case .body(let data, let status):
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case nil:
            let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

final class PostingFetcherTests: XCTestCase {
    var session: URLSession!

    override func setUp() {
        StubProtocol.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: cfg)
    }

    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func stub(_ url: String, fixture name: String, status: Int = 200) throws {
        StubProtocol.set(url, .body(try fixture(name), status: status))
    }

    func stubHTML(_ url: String, _ html: String) {
        StubProtocol.set(url, .body(Data(html.utf8), status: 200))
    }

    // MARK: sources

    func testLinkedInGuestEndpoint() async throws {
        try stub("https://www.linkedin.com/jobs-guest/jobs/api/jobPosting/9900112233", fixture: "linkedin.html")
        let p = try await PostingFetcher.fetch(URL(string: "https://www.linkedin.com/jobs/view/9900112233/?trk=x")!, session: session)
        XCTAssertEqual(p.source, .linkedin)
        XCTAssertEqual(p.title, "Junior AI Engineer/Generative AI Developer (Milano/Roma)")
        XCTAssertEqual(p.company, "Meridian Consulting")
        XCTAssertTrue(p.text.hasPrefix("Meridian Consulting, parte del gruppo Engineering"), p.text.prefix(80).description)
        XCTAssertTrue(p.text.contains("- Python"))
        XCTAssertFalse(p.text.contains("Show more"))
        XCTAssertFalse(p.text.contains("<"))
    }

    func testLinkedInSlugAndCurrentJobIdURLs() async throws {
        try stub("https://www.linkedin.com/jobs-guest/jobs/api/jobPosting/9900112233", fixture: "linkedin.html")
        let slug = URL(string: "https://it.linkedin.com/jobs/view/junior-ai-engineer-at-be-9900112233?trk=public")!
        let a = try await PostingFetcher.fetch(slug, session: session)
        XCTAssertEqual(a.source, .linkedin)
        let coll = URL(string: "https://www.linkedin.com/jobs/collections/recommended/?currentJobId=9900112233")!
        let b = try await PostingFetcher.fetch(coll, session: session)
        XCTAssertEqual(b.source, .linkedin)
    }

    func testAshbyMatchesIdOnBoard() async throws {
        try stub("https://api.ashbyhq.com/posting-api/job-board/brightwave", fixture: "ashby.json")
        let u = URL(string: "https://jobs.ashbyhq.com/brightwave/11111111-2222-3333-4444-555555555555")!
        let p = try await PostingFetcher.fetch(u, session: session)
        XCTAssertEqual(p.source, .ashby)
        XCTAssertEqual(p.title, "AI Engineer")
        XCTAssertEqual(p.company, "brightwave")
        XCTAssertTrue(p.text.hasPrefix("Ciao, we're Brightwave"), p.text.prefix(60).description)
        XCTAssertFalse(p.text.contains("<"))
    }

    func testAshbyUnknownIdIsUnreadable() async throws {
        try stub("https://api.ashbyhq.com/posting-api/job-board/brightwave", fixture: "ashby.json")
        let u = URL(string: "https://jobs.ashbyhq.com/brightwave/00000000-0000-0000-0000-000000000000")!
        await assertThrows(.unreadable) { _ = try await PostingFetcher.fetch(u, session: self.session) }
    }

    func testGreenhouse() async throws {
        try stub("https://boards-api.greenhouse.io/v1/boards/anthropic/jobs/4461450008", fixture: "greenhouse.json")
        for host in ["boards.greenhouse.io", "job-boards.greenhouse.io"] {
            let u = URL(string: "https://\(host)/anthropic/jobs/4461450008")!
            let p = try await PostingFetcher.fetch(u, session: session)
            XCTAssertEqual(p.source, .greenhouse)
            XCTAssertEqual(p.title, "Account Executive, AI Native")
            XCTAssertEqual(p.company, "Anthropic")
            XCTAssertTrue(p.text.hasPrefix("About Anthropic"), p.text.prefix(40).description)
            XCTAssertFalse(p.text.contains("&lt;"))
            XCTAssertFalse(p.text.contains("<"))
        }
    }

    func testLever() async throws {
        try stub("https://api.lever.co/v0/postings/spotify/223f9722-3579-4ff2-b123-e4cc7b0c1a64", fixture: "lever.json")
        let u = URL(string: "https://jobs.lever.co/spotify/223f9722-3579-4ff2-b123-e4cc7b0c1a64")!
        let p = try await PostingFetcher.fetch(u, session: session)
        XCTAssertEqual(p.source, .lever)
        XCTAssertEqual(p.title, "Art Director - Mexico")
        XCTAssertEqual(p.company, "Spotify")
        XCTAssertTrue(p.text.hasPrefix("The Marketing team in Latin America"), p.text.prefix(50).description)
        XCTAssertTrue(p.text.contains("What You'll Do"))
        XCTAssertTrue(p.text.contains("- Bring creative concepts"))
    }

    // MARK: generic pages

    func testJSONLDJobPosting() async throws {
        let html = """
        <html><head><title>x</title><script type="application/ld+json">
        {"@context":"https://schema.org","@type":"JobPosting","title":"Backend Engineer","hiringOrganization":{"@type":"Organization","name":"Acme Srl"},
         "description":"&lt;p&gt;Build the payments core for Acme.&lt;/p&gt;&lt;ul&gt;&lt;li&gt;Go and Postgres&lt;/li&gt;&lt;li&gt;On-call rota&lt;/li&gt;&lt;/ul&gt;&lt;p&gt;You will own services end to end and work with product and design on the roadmap every quarter.&lt;/p&gt;"}
        </script></head><body><nav>Home Jobs</nav></body></html>
        """
        stubHTML("https://careers.acme.example/backend", html)
        let p = try await PostingFetcher.fetch(URL(string: "https://careers.acme.example/backend")!, session: session)
        XCTAssertEqual(p.source, .page)
        XCTAssertEqual(p.title, "Backend Engineer")
        XCTAssertEqual(p.company, "Acme Srl")
        XCTAssertTrue(p.text.hasPrefix("Build the payments core for Acme."))
        XCTAssertTrue(p.text.contains("- Go and Postgres"))
    }

    func testJSONLDInGraphArray() async throws {
        let html = """
        <script type="application/ld+json">{"@graph":[{"@type":"WebSite","name":"s"},{"@type":["JobPosting"],"title":"Data Analyst","hiringOrganization":"Globex","description":"Analyse data for the whole company, build dashboards, and talk to stakeholders about what the numbers mean for them every week of the year."}]}</script>
        """
        stubHTML("https://globex.example/j", html)
        let p = try await PostingFetcher.fetch(URL(string: "https://globex.example/j")!, session: session)
        XCTAssertEqual(p.title, "Data Analyst")
        XCTAssertEqual(p.company, "Globex")
    }

    func testReadablePagePrefersMainAndStripsNoise() async throws {
        let filler = String(repeating: "We are looking for a person who loves shipping software. ", count: 4)
        let html = """
        <html><head><title>Senior Dev - Initech Careers</title><style>.a{color:red}</style><script>var tracking = 1;</script></head>
        <body><header><nav>Menu Careers About</nav></header>
        <main><h1>Senior Dev</h1><p>\(filler)</p><ul><li>Swift</li><li>Testing</li></ul></main>
        <footer>Cookie policy &amp; terms</footer></body></html>
        """
        stubHTML("https://initech.example/careers/1", html)
        let p = try await PostingFetcher.fetch(URL(string: "https://initech.example/careers/1")!, session: session)
        XCTAssertEqual(p.source, .page)
        XCTAssertEqual(p.title, "Senior Dev")
        XCTAssertTrue(p.text.contains("- Swift"))
        XCTAssertFalse(p.text.contains("Menu Careers"))
        XCTAssertFalse(p.text.contains("tracking"))
        XCTAssertFalse(p.text.contains("Cookie"))
        XCTAssertFalse(p.text.contains("color:red"))
    }

    func testPageWithoutJobContentIsUnreadable() async throws {
        stubHTML("https://example.com/", "<html><head><title>Example</title></head><body><nav>Home</nav><p>Hello.</p></body></html>")
        await assertThrows(.unreadable) { _ = try await PostingFetcher.fetch(URL(string: "https://example.com/")!, session: self.session) }
    }

    func testHTTPErrorIsUnreadableAndTransportErrorIsNetwork() async throws {
        // Unstubbed URL -> 404.
        await assertThrows(.unreadable) { _ = try await PostingFetcher.fetch(URL(string: "https://nope.example/x")!, session: self.session) }
        StubProtocol.set("https://down.example/x", .failure(.notConnectedToInternet))
        await assertThrows(.network) { _ = try await PostingFetcher.fetch(URL(string: "https://down.example/x")!, session: self.session) }
        StubProtocol.set("https://api.lever.co/v0/postings/acme/abc", .failure(.timedOut))
        await assertThrows(.network) { _ = try await PostingFetcher.fetch(URL(string: "https://jobs.lever.co/acme/abc")!, session: self.session) }
    }

    func testNonHTTPURLIsUnreadable() async throws {
        await assertThrows(.unreadable) { _ = try await PostingFetcher.fetch(URL(string: "file:///etc/hosts")!, session: self.session) }
    }

    // MARK: pasted + normalisation

    func testPastedTrimsAndNormalises() {
        let p = PostingFetcher.pasted("  \n Senior Dev\t at   Initech \r\n\r\n\r\n\r\n• Swift\n  ◦ Tests\n* Go\n\n  ")
        XCTAssertEqual(p.source, .pasted)
        XCTAssertNil(p.url)
        XCTAssertEqual(p.text, "Senior Dev at Initech\n\n- Swift\n- Tests\n- Go")
        XCTAssertEqual(p.title, "Senior Dev at Initech")
    }

    func testTextCappedAt30000() {
        let p = PostingFetcher.pasted(String(repeating: "word ", count: 20_000))
        XCTAssertLessThanOrEqual(p.text.count, 30_000)
        XCTAssertGreaterThan(p.text.count, 29_000)
    }

    func testHTMLEntitiesAndBlocks() {
        let t = HTMLText.plain("<h2>Role &amp; scope</h2><p>One<br>two&nbsp;three &#8217; &#x2019;</p><ol><li>a</li><li>b</li></ol>")
        XCTAssertEqual(t, "Role & scope\n\nOne\ntwo three ’ ’\n\n- a\n- b")
    }

    func assertThrows(_ expected: PostingError, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("expected \(expected)", file: file, line: line) }
        catch let e as PostingError { XCTAssertEqual(e, expected, file: file, line: line) }
        catch { XCTFail("unexpected \(error)", file: file, line: line) }
    }
}
