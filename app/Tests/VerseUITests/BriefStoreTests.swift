import Foundation
@testable import VerseUI
import XCTest

/// `brief.json` (memory spec 3.5): reading, staleness, and the request line.
final class BriefStoreTests: XCTestCase {
    private var scratch: MemoryFixtures.Scratch!

    override func setUpWithError() throws { scratch = try MemoryFixtures.scratch() }
    override func tearDownWithError() throws { scratch.remove() }

    private var fixture: URL { MemoryFixtures.fixturesDir.appendingPathComponent("brief.json") }

    func testTheFixtureBriefDecodes() throws {
        let b = try XCTUnwrap(BriefStore.load(url: fixture))
        XCTAssertEqual(b.version, 1)
        XCTAssertEqual(b.entity, "e-3k9xq2ma")
        XCTAssertEqual(b.name, "Marta Velin")
        XCTAssertEqual(b.model, "claude-sonnet-5-5")
        XCTAssertEqual(b.newestSession, "halden-pilot-review")
        XCTAssertEqual(b.forSession, "halden-weekly-prep")
        XCTAssertEqual(b.madeAt, ISO8601DateFormatter().date(from: "2026-10-21T09:12:00Z"))
        XCTAssertEqual(b.costUSD, 0.048, accuracy: 1e-9)
        XCTAssertEqual(b.droppedUncited, 1)
        XCTAssertEqual(b.sessions.map(\.key), ["sp0m2vx", "sk3f9qa"])
        XCTAssertEqual(b.sections.map(\.id), ["discussed", "promised_owner", "promised_them", "open", "tone"])
        XCTAssertEqual(b.sections[0].points[0].text, "The pilot covers two teams, not four")
        XCTAssertEqual(b.sections[0].points[0].cites, [.init(key: "sk3f9qa", session: "halden-kickoff", kind: "turn", stamp: "0:24")])
        XCTAssertNil(b.sections[1].points[0].cites[1].stamp, "a summary citation has no stamp")
        XCTAssertTrue(b.sections[2].points.isEmpty)
    }

    func testFractionalSecondsAndMissingOptionalFieldsStillDecode() throws {
        var text = try String(contentsOf: fixture, encoding: .utf8)
        text = text.replacingOccurrences(of: "2026-10-21T09:12:00Z", with: "2026-10-21T09:12:00.250Z")
            .replacingOccurrences(of: "\"cost_usd\": 0.048,\n  \"dropped_uncited\": 1", with: "\"extra\": true")
        let b = try XCTUnwrap(BriefStore.decode(Data(text.utf8)))
        XCTAssertEqual(b.costUSD, 0)
        XCTAssertEqual(b.droppedUncited, 0)
    }

    func testEncodingUsesSnakeCaseKeys() throws {
        let b = try XCTUnwrap(BriefStore.load(url: fixture))
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: enc.encode(b)) as? [String: Any])
        XCTAssertNotNil(o["made_at"])
        XCTAssertNotNil(o["newest_session"])
        XCTAssertNotNil(o["dropped_uncited"])
        XCTAssertNil(o["madeAt"])
    }

    func testIsStale() throws {
        let b = try XCTUnwrap(BriefStore.load(url: fixture))
        XCTAssertTrue(b.isStale(newestSession: "halden-weekly-call"), "a newer session exists")
        XCTAssertFalse(b.isStale(newestSession: "halden-pilot-review"), "the same session")
        XCTAssertFalse(b.isStale(newestSession: nil), "no session known")
    }

    func testMissingOrGarbageFileIsNil() throws {
        let paths = scratch.paths
        XCTAssertNil(BriefStore.load(entity: "e-none", paths: paths))
        XCTAssertNil(BriefStore.load(sessionDir: scratch.sessions.appendingPathComponent("halden-kickoff")))
        try MemoryFixtures.write("not json at all", to: paths.brief(entity: "e-bad"))
        XCTAssertNil(BriefStore.load(entity: "e-bad", paths: paths))
        try MemoryFixtures.write("{\"version\":1}", to: paths.brief(entity: "e-partial"))
        XCTAssertNil(BriefStore.load(entity: "e-partial", paths: paths), "missing required fields")
    }

    func testLoadsFromTheEntityPathAndTheSessionFolder() throws {
        let paths = scratch.paths
        paths.ensureDirectories()
        try FileManager.default.copyItem(at: fixture, to: paths.brief(entity: "e-3k9xq2ma"))
        XCTAssertEqual(BriefStore.load(entity: "e-3k9xq2ma", paths: paths)?.name, "Marta Velin")
        let prep = scratch.sessions.appendingPathComponent("halden-weekly-prep", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: prep.appendingPathComponent("brief.json"))
        XCTAssertEqual(BriefStore.load(sessionDir: prep)?.forSession, "halden-weekly-prep")
        XCTAssertEqual(paths.brief(entity: "e-3k9xq2ma").lastPathComponent, "e-3k9xq2ma.json")
        XCTAssertEqual(paths.brief(entity: "e-3k9xq2ma").deletingLastPathComponent().lastPathComponent, "briefs")
    }

    func testRequestLineGolden() throws {
        let tz = TimeZone(secondsFromGMT: 3600)!
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-28T10:00:00+01:00"))
        let r = BriefRequest(entity: .init(id: "e-3k9xq2ma", kind: "person", name: "Marta Velin", company: "Halden Works"),
                             sessions: ["halden-pilot-review", "halden-kickoff"],
                             upcoming: .init(title: "Halden weekly", start: start, attendees: ["Marta Velin", "Joe Arkwright"]),
                             lang: "en", sessionOut: URL(fileURLWithPath: "/m/sessions/halden-weekly"))
        let line = r.startLine(db: URL(fileURLWithPath: "/m/memory/index.sqlite"), out: URL(fileURLWithPath: "/m/memory/briefs/e-3k9xq2ma.json"),
                               ownerName: "Dana", timeZone: tz)
        XCTAssertEqual(line, #"{"db":"/m/memory/index.sqlite","entity":{"company":"Halden Works","id":"e-3k9xq2ma","kind":"person","name":"Marta Velin"},"lang":"en","model":"sonnet","out":"/m/memory/briefs/e-3k9xq2ma.json","owner_name":"Dana","session_out":"/m/sessions/halden-weekly","sessions":["halden-pilot-review","halden-kickoff"],"type":"brief_start","upcoming":{"attendees":["Marta Velin","Joe Arkwright"],"start":"2026-10-28T10:00:00+01:00","title":"Halden weekly"}}"#)
    }

    func testRequestLineWithoutUpcomingSessionOutOrCompany() {
        let r = BriefRequest(entity: .init(id: "e-1", kind: "company", name: "Halden Works", company: nil), sessions: [], upcoming: nil, lang: "it", sessionOut: nil, model: "haiku")
        let o = MemoryFixtures.object(r.startLine(db: URL(fileURLWithPath: "/m/index.sqlite"), out: URL(fileURLWithPath: "/m/b.json"), ownerName: "Dana"))
        XCTAssertTrue(o["upcoming"] is NSNull)
        XCTAssertTrue(o["session_out"] is NSNull)
        XCTAssertTrue((o["entity"] as? [String: Any])?["company"] is NSNull)
        XCTAssertEqual(o["model"] as? String, "haiku")
        XCTAssertEqual(o["lang"] as? String, "it")
    }

    func testBriefEventParsing() {
        XCTAssertEqual(BriefEvent.parse(#"{"type":"brief_done","path":"/m/b.json","cost_usd":0.048,"points":9,"dropped_uncited":1,"ms_total":4200}"#),
                       .done(path: "/m/b.json", costUSD: 0.048, points: 9, droppedUncited: 1, ms: 4200))
        XCTAssertEqual(BriefEvent.parse(#"{"type":"brief_error","kind":"no_sessions","message":"x"}"#),
                       .error(ChatFailure(kind: "no_sessions", message: "x", retryAfter: nil), costUSD: nil))
        XCTAssertEqual(BriefEvent.parse(#"{"type":"brief_error","kind":"rate_limited","message":"","retry_after":20,"cost_usd":0.01}"#),
                       .error(ChatFailure(kind: "rate_limited", message: "", retryAfter: 20), costUSD: 0.01))
        XCTAssertEqual(BriefEvent.parse(#"{"type":"status","state":"warming"}"#), .status(state: "warming", message: ""))
        XCTAssertNil(BriefEvent.parse(#"{"type":"ask_done"}"#))
    }
}
