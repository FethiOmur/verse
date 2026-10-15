import Foundation
import XCTest
@testable import VersePosting

/// Manual check against real postings. Skipped unless VERSE_LIVE_POSTING_URLS is set (space-separated URLs):
///   VERSE_LIVE_POSTING_URLS="https://jobs.ashbyhq.com/brightwave/<id>" swift test --filter LivePostingTests
final class LivePostingTests: XCTestCase {
    func testLiveFetch() async throws {
        let raw = ProcessInfo.processInfo.environment["VERSE_LIVE_POSTING_URLS"] ?? ""
        try XCTSkipIf(raw.isEmpty, "set VERSE_LIVE_POSTING_URLS to run")
        for s in raw.split(separator: " ") {
            let p = try await PostingFetcher.fetch(URL(string: String(s))!)
            print("LIVE \(p.source.rawValue) | title: \(p.title) | company: \(p.company ?? "nil") | chars: \(p.text.count)")
            print("LIVE first line: \(p.text.split(separator: "\n").first ?? "")")
        }
    }
}
