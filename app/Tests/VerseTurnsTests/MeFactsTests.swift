import Foundation
import VerseTurns
import XCTest

/// `me.facts.jsonl` (the NUMBERS of the permanent profile) next to a session's `facts.jsonl`: chips and grounding. Fictional
/// data: "Dana Reyes" of the brain's fixtures.
final class MeFactsTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("verse-mefacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private let meLines = """
    {"id": "m401", "kind": "number", "text": "Harbor Ledger processed about 41,000 payments a month.", "value": "41000", "sources": [{"kind": "file", "ref": "file:dana_profile.md#L13", "quote": "It processed about 41,000 payments a month"}]}
    {"id": "m403", "kind": "number", "text": "Trailhead reached 12,000 monthly users.", "value": "12000", "sources": [{"kind": "file", "ref": "file:dana_profile.md#L16", "quote": "It reached 12,000 monthly users"}]}
    {"id": "m410", "kind": "date", "text": "Available from January 2027.", "value": "2027-01-04", "sources": [{"kind": "file", "ref": "file:dana_profile.md#L28", "quote": "available from January 2027"}]}
    """

    func testTheProfilesNumbersJoinTheSessionsFacts() throws {
        let session = try folder()
        try #"{"id": "f001", "kind": "number", "text": "Budget is 38,000 a year.", "value": "38000", "sources": [{"kind": "prep", "ref": "prep:L13"}]}"#
            .write(to: session.appendingPathComponent("facts.jsonl"), atomically: true, encoding: .utf8)
        let me = try folder().appendingPathComponent("me.facts.jsonl")
        try meLines.write(to: me, atomically: true, encoding: .utf8)

        let index = try FactIndex.load(sessionDir: session, meFacts: me)
        let chips = index.chips(in: "we had 38,000 on one side and about 41,000 payments a month on the other")
        XCTAssertEqual(Set(chips.map(\.id)), ["f001", "m401"])
        XCTAssertEqual(chips.first { $0.id == "m401" }?.sourceRef, "me:m401", "labelled as the profile's")
        XCTAssertEqual(chips.first { $0.id == "f001" }?.sourceRef, "prep:L13")
        // A date of the profile is a chip too.
        XCTAssertEqual(index.chips(in: "from the 4th of January").map(\.id), ["m410"])
        // Grounding: a question with one of his numbers counts as being about the session.
        XCTAssertTrue(SessionTerms(bank: Bank(entries: []), facts: index).names("how did you get to 12,000 users"))
    }

    func testTheMeetingPackWinsWhenBothSayTheSame() throws {
        let session = try folder()
        try #"{"id": "f002", "kind": "number", "text": "About 41,000 payments a month, per the pack.", "value": "41000", "sources": [{"kind": "prep", "ref": "prep:L2"}]}"#
            .write(to: session.appendingPathComponent("facts.jsonl"), atomically: true, encoding: .utf8)
        let me = try folder().appendingPathComponent("me.facts.jsonl")
        try meLines.write(to: me, atomically: true, encoding: .utf8)
        let chips = try FactIndex.load(sessionDir: session, meFacts: me).chips(in: "41,000 payments")
        XCTAssertEqual(chips.map(\.id), ["f002"], "one chip, the pack's")
    }

    func testAMissingOrBrokenProfileFileAddsNothing() throws {
        let session = try folder()
        try #"{"id": "f001", "kind": "number", "text": "Budget is 38,000 a year.", "value": "38000", "sources": []}"#
            .write(to: session.appendingPathComponent("facts.jsonl"), atomically: true, encoding: .utf8)
        let missing = try FactIndex.load(sessionDir: session, meFacts: URL(fileURLWithPath: "/nonexistent/me.facts.jsonl"))
        XCTAssertEqual(missing.chips(in: "38,000").map(\.id), ["f001"])
        let broken = try folder().appendingPathComponent("me.facts.jsonl")
        try "not json at all\n".write(to: broken, atomically: true, encoding: .utf8)
        XCTAssertEqual(try FactIndex.load(sessionDir: session, meFacts: broken).chips(in: "38,000").map(\.id), ["f001"])
        XCTAssertEqual(try FactIndex.load(sessionDir: session, meFacts: nil).chips(in: "38,000").map(\.id), ["f001"])
    }

    func testAnUnpreparedSessionHasOnlyTheProfilesFacts() throws {
        let session = try folder()          // an adhoc folder: pack.md and nothing else
        let me = try folder().appendingPathComponent("me.facts.jsonl")
        try meLines.write(to: me, atomically: true, encoding: .utf8)
        let index = try FactIndex.load(sessionDir: session, meFacts: me)
        XCTAssertFalse(index.isEmpty)
        XCTAssertEqual(index.chips(in: "12,000 users").map(\.id), ["m403"])
        XCTAssertTrue(try FactIndex.load(sessionDir: session, meFacts: nil).isEmpty)
    }
}
