import Foundation
import XCTest
@testable import VersePosting

/// URLProtocol stub for the safety tests: serves a body, a redirect, or a long body in chunks. No request leaves the process.
final class SafetyStub: URLProtocol, @unchecked Sendable {
    enum Reply { case redirect(to: String), body(Data), chunks(count: Int, size: Int) }
    nonisolated(unsafe) static var replies: [String: Reply] = [:]
    nonisolated(unsafe) static var requested: [String] = []
    nonisolated(unsafe) static var chunksSent = 0
    private static let lock = NSLock()
    private let stopped = NSLock()
    private var isStopped = false

    static func reset() { lock.withLock { replies = [:]; requested = []; chunksSent = 0 } }
    static func set(_ url: String, _ r: Reply) { lock.withLock { replies[url] = r } }
    static var requestedURLs: [String] { lock.withLock { requested } }
    static var sentChunks: Int { lock.withLock { chunksSent } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let reply = SafetyStub.lock.withLock { () -> Reply? in SafetyStub.requested.append(url.absoluteString); return SafetyStub.replies[url.absoluteString] }
        switch reply {
        case .redirect(let to):
            let resp = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": to])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: to)!), redirectResponse: resp)
            // As a real server connection does: if the delegate refuses the redirect, the 3xx answer is the final response.
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .body(let d):
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: d)
            client?.urlProtocolDidFinishLoading(self)
        case .chunks(let count, let size):
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            DispatchQueue.global().async {
                for _ in 0..<count {
                    if self.stopped.withLock({ self.isStopped }) { return }
                    SafetyStub.lock.withLock { SafetyStub.chunksSent += 1 }
                    self.client?.urlProtocol(self, didLoad: Data(repeating: 0x61, count: size))
                    Thread.sleep(forTimeInterval: 0.002)
                }
                self.client?.urlProtocolDidFinishLoading(self)
            }
        case nil:
            let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stopped.withLock { isStopped = true } }
}

final class PostingFetcherSafetyTests: XCTestCase {
    var session: URLSession!

    override func setUp() {
        SafetyStub.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SafetyStub.self]
        session = URLSession(configuration: cfg)
    }

    // MARK: the address check (pure, no DNS)

    func testBlockedHosts() {
        let blocked = [
            "localhost", "LOCALHOST", "foo.localhost", "printer.local", "metadata.google.internal", "intranet", "router.lan",
            "127.0.0.1", "127.1", "2130706433", "0x7f000001", "0x7f.0.0.1", "0.0.0.0", "10.1.2.3", "172.16.0.1", "172.31.255.255",
            "192.168.1.1", "169.254.169.254", "100.64.0.1", "198.18.0.1", "224.0.0.1", "255.255.255.255",
            "::1", "::", "[::1]", "fe80::1", "fe80::1%en0", "fc00::1", "fd12:3456::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:10.0.0.1",
            "64:ff9b::7f00:1", "",
        ]
        for h in blocked { XCTAssertTrue(PostingFetcher.isBlockedHost(h), "\(h) should be blocked") }
        let allowed = ["example.com", "jobs.ashbyhq.com", "www.linkedin.com", "8.8.8.8", "172.32.0.1", "172.15.0.1", "100.63.0.1",
                       "1.1.1.1", "2606:4700:4700::1111", "::ffff:8.8.8.8", "192.0.2.1"]
        for h in allowed { XCTAssertFalse(PostingFetcher.isBlockedHost(h), "\(h) should be allowed") }
    }

    func testFetchRefusesLoopbackAndPrivateURLsWithoutARequest() async {
        for u in ["http://127.0.0.1/job", "https://localhost:8080/x", "http://169.254.169.254/latest/meta-data/", "http://[::1]/", "http://192.168.0.10/jobs"] {
            do {
                _ = try await PostingFetcher.fetch(URL(string: u)!, session: session)
                XCTFail("\(u) should be refused")
            } catch {
                XCTAssertEqual(error as? PostingError, .unreadable, u)
            }
        }
        XCTAssertEqual(SafetyStub.requestedURLs, [], "nothing may be requested")
    }

    func testARedirectToALoopbackAddressIsNotFollowed() async {
        SafetyStub.set("https://jobs.example.com/p/1", .redirect(to: "http://127.0.0.1:9/secret"))
        SafetyStub.set("http://127.0.0.1:9/secret", .body(Data(String(repeating: "secret ", count: 100).utf8)))
        do {
            _ = try await PostingFetcher.fetch(URL(string: "https://jobs.example.com/p/1")!, session: session)
            XCTFail("the redirect target must not be read")
        } catch {
            XCTAssertEqual(error as? PostingError, .unreadable)
        }
        XCTAssertEqual(SafetyStub.requestedURLs, ["https://jobs.example.com/p/1"], "the loopback URL must never be requested")
    }

    func testARedirectToAPublicAddressIsStillFollowed() async throws {
        SafetyStub.set("https://short.example.com/p", .redirect(to: "https://jobs.example.com/p/2"))
        SafetyStub.set("https://jobs.example.com/p/2", .body(Data("hello".utf8)))
        let data = try await PostingFetcher.get(URL(string: "https://short.example.com/p")!, session: session)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello")
    }

    // MARK: the 3 MB cap

    func testTheBodyIsCappedAndNotDownloadedInFull() async throws {
        // 200 chunks of 100 KB = 20 MB offered; the cap is 3 MB.
        SafetyStub.set("https://big.example.com/page", .chunks(count: 200, size: 100_000))
        let data = try await PostingFetcher.get(URL(string: "https://big.example.com/page")!, session: session)
        XCTAssertLessThanOrEqual(data.count, PostingFetcher.maxBodyBytes + 100_000)
        XCTAssertGreaterThanOrEqual(data.count, PostingFetcher.maxBodyBytes)
        try await Task.sleep(for: .milliseconds(150))
        let sent = SafetyStub.sentChunks
        XCTAssertLessThan(sent, 200, "the transfer must stop at the cap, not run to the end (sent \(sent) chunks)")
    }
}
