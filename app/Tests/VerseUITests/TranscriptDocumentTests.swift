import Foundation
@testable import VerseUI
import XCTest

/// The transcript model (F1, spec 2.1): runs, timestamps, speakers, room relabelling, cards, search and export. The fixtures under
/// `Fixtures/transcript-*` have the shapes of real files with fictional text.
final class TranscriptDocumentTests: XCTestCase {
    private func fixtureDir(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)", isDirectory: true)
    }

    private func load(_ name: String, owner: String = "Dana") -> TranscriptDocument {
        TranscriptDocument.load(sessionDir: fixtureDir(name), ownerName: owner)
    }

    private func line(_ id: String, _ speaker: String = "remote", _ text: String = "x", _ end: Double) -> TranscriptLine {
        TranscriptLine(turnID: id, speaker: speaker, text: text, tAudioEnd: end, runStart: nil, tWall: nil)
    }

    private func fwd(_ rs: Double, _ id: String, _ speaker: String = "remote", _ text: String = "x", _ end: Double) -> TranscriptLine {
        TranscriptLine(turnID: id, speaker: speaker, text: text, tAudioEnd: end, runStart: rs, tWall: rs + end)
    }

    // MARK: stamps

    func testStamps() {
        XCTAssertEqual(TranscriptDocument.stamp(59.4), "0:59")
        XCTAssertEqual(TranscriptDocument.stamp(3725), "1:02:05")
        XCTAssertEqual(TranscriptDocument.stamp(0), "0:00")
        XCTAssertEqual(TranscriptDocument.stamp(3599.9), "59:59")
        XCTAssertEqual(TranscriptDocument.stamp(3600), "1:00:00")
        XCTAssertEqual(TranscriptDocument.stamp(-5), "0:00")
    }

    // MARK: legacy segmentation and alignment

    func testLegacyFileHasFourRunsFromFiveStartsAlignedToTheLastFour() {
        let d = load("transcript-legacy-5starts")
        XCTAssertEqual(d.runCount, 4)
        XCTAssertEqual(d.rows.count, 18)
        XCTAssertEqual(Dictionary(grouping: d.rows, by: \.run).mapValues(\.count), [0: 6, 1: 5, 2: 4, 3: 3])
        // The first start (no speech) is skipped: elapsed counts from the second start. Starts are 300 s, 1800 s and 120 s apart.
        let stamps = d.rows.map(\.stamp)
        XCTAssertEqual(Array(stamps[0 ..< 6]), ["0:06", "0:31", "0:58", "0:59", "1:14", "1:36"])
        XCTAssertEqual(Array(stamps[6 ..< 11]), ["5:12", "5:31", "5:52", "6:24", "7:20"])
        XCTAssertEqual(Array(stamps[11 ..< 15]), ["35:08", "35:27", "35:41", "36:02"])
        XCTAssertEqual(Array(stamps[15...]), ["38:00", "38:24", "38:41"])
        XCTAssertTrue(d.rows.allSatisfy { $0.wall != nil })
    }

    func testStampsNeverGoBackwardsBetweenRuns() {
        for name in ["transcript-legacy-5starts", "transcript-forward", "transcript-room"] {
            let d = load(name)
            XCTAssertEqual(d.rows.map(\.elapsed), d.rows.map(\.elapsed).sorted(), name)
        }
    }

    func testARepeatedIdAloneStartsARunAndSoDoesATimeDropAlone() {
        // Repeat only: the second r1 is 5 s later than the first, no time drop.
        let a = TranscriptDocument(lines: [line("r1", "remote", "a", 10), line("m1", "me", "b", 20), line("r1", "remote", "c", 25)], events: [], ownerName: "Dana")
        XCTAssertEqual(a.runCount, 2)
        XCTAssertEqual(a.rows.map(\.text), ["a", "b", "c"], "a repeated id in a legacy file is a new run, not a replacement")
        // Time drop only: new ids, but 31 s below the run's maximum.
        let b = TranscriptDocument(lines: [line("r1", "remote", "a", 100), line("r2", "remote", "b", 69)], events: [], ownerName: "Dana")
        XCTAssertEqual(b.runCount, 2)
        // A drop of exactly 30 s stays in the run.
        let c = TranscriptDocument(lines: [line("r1", "remote", "a", 100), line("r2", "remote", "b", 70)], events: [], ownerName: "Dana")
        XCTAssertEqual(c.runCount, 1)
    }

    func testWithinARunTheLaterTextOfARepeatedIdReplacesTheEarlierInItsPosition() {
        let rs = 1_792_100_000.0
        let d = TranscriptDocument(lines: [fwd(rs, "r1", "remote", "How did", 10), fwd(rs, "m1", "me", "Fine.", 12), fwd(rs, "r1", "remote", "How did you measure it?", 15)],
                                   events: [], ownerName: "Dana")
        XCTAssertEqual(d.runCount, 1)
        XCTAssertEqual(d.rows.map(\.text), ["How did you measure it?", "Fine."])
    }

    func testWithoutEventsRunsFollowOneAnotherCumulatively() {
        let lines = (try? String(contentsOf: fixtureDir("transcript-legacy-5starts").appendingPathComponent("transcript.jsonl"), encoding: .utf8)) ?? ""
        XCTAssertFalse(lines.isEmpty)
        let d = TranscriptDocument(lines: TranscriptDocument.readTranscript(fixtureDir("transcript-legacy-5starts").appendingPathComponent("transcript.jsonl")),
                                   events: [], ownerName: "Dana")
        XCTAssertEqual(d.runCount, 4)
        // Run k begins where run k-1's last line ended: 96.5, then +140, then +62.
        XCTAssertEqual(d.rows[6].elapsed, 96.5 + 12.0, accuracy: 0.001)
        XCTAssertEqual(d.rows[11].elapsed, 96.5 + 140 + 8.0, accuracy: 0.001)
        XCTAssertEqual(d.rows[15].elapsed, 96.5 + 140 + 62 + 60.5, accuracy: 0.001)
        XCTAssertTrue(d.rows.allSatisfy { $0.wall == nil })
        XCTAssertFalse(d.hasEvents)
    }

    func testFewerStartsThanRunsFallBackToCumulativeAndShowNoCards() {
        let dir = fixtureDir("transcript-legacy-5starts")
        let starts = TranscriptDocument.readEvents(dir.appendingPathComponent("events.jsonl")).filter { $0.ev == "start" }.prefix(2)
        let cards = TranscriptDocument.readEvents(dir.appendingPathComponent("events.jsonl")).filter { $0.ev == "card" }
        let d = TranscriptDocument(lines: TranscriptDocument.readTranscript(dir.appendingPathComponent("transcript.jsonl")),
                                   events: Array(starts) + cards, ownerName: "Dana")
        XCTAssertEqual(d.runCount, 4)
        XCTAssertTrue(d.hasEvents)
        XCTAssertEqual(d.rows[6].elapsed, 96.5 + 12.0, accuracy: 0.001, "cumulative")
        XCTAssertFalse(d.hasCards, "no wall times, no cards")
    }

    func testSortWithinARunIsByAudioEndAndStable() {
        let rs = 1_792_100_000.0
        let d = TranscriptDocument(lines: [fwd(rs, "m2", "me", "second", 25), fwd(rs, "r1", "remote", "first", 20),
                                           fwd(rs, "m3", "me", "third-a", 30), fwd(rs, "r2", "remote", "third-b", 30)], events: [], ownerName: "Dana")
        XCTAssertEqual(d.rows.map(\.text), ["first", "second", "third-a", "third-b"])
    }

    func testForwardFileUsesWallTimeAndAMixedFileKeepsLegacyRunsFirst() {
        let d = load("transcript-forward")
        XCTAssertEqual(d.runCount, 2)
        XCTAssertEqual(d.rows.map(\.stamp), ["0:05", "0:22", "0:38", "0:40", "1:10", "1:01:20", "1:02:05"])
        XCTAssertEqual(d.rows[6].wall ?? 0, 1_792_100_000.123 + 3600 + 125, accuracy: 0.001)

        // A legacy run, then a forward run: the legacy run is aligned to the start that came before the forward file's.
        let legacyStart = 1_792_000_000.0, rs = 1_792_000_500.0
        let events = [SessionEvent(t: legacyStart, ev: "start"), SessionEvent(t: rs - 1, ev: "start")]
        let m = TranscriptDocument(lines: [line("r1", "remote", "old", 10), fwd(rs, "r1", "remote", "new", 4)], events: events, ownerName: "Dana")
        XCTAssertEqual(m.runCount, 2)
        XCTAssertEqual(m.rows[0].elapsed, 10, accuracy: 0.001)
        XCTAssertEqual(m.rows[1].elapsed, 500 + 4, accuracy: 0.001)
    }

    func testMalformedLinesAreSkipped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verse-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        {"turn_id":"r1","speaker":"remote","text":"Hello there","t_audio_end":2.5}
        not json
        {"turn_id":"r2","speaker":"me","text":"  ","t_audio_end":3.0}
        {"speaker":"me","text":"no id","t_audio_end":4.0}
        {"turn_id":"m1","speaker":"me","text":"Hi","t_audio_end":5.0}
        """.write(to: dir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)
        let d = TranscriptDocument.load(sessionDir: dir, ownerName: "Dana")
        XCTAssertEqual(d.rows.map(\.text), ["Hello there", "Hi"])
        XCTAssertTrue(TranscriptDocument.load(sessionDir: dir.appendingPathComponent("missing"), ownerName: "Dana").isEmpty)
    }

    // MARK: speakers

    func testSpeakers() {
        let d = load("transcript-legacy-5starts", owner: "Dana")
        XCTAssertEqual(d.name(of: d.rows[0].speaker), "Dana")
        XCTAssertEqual(d.name(of: d.rows[1].speaker), "Other")
        XCTAssertEqual(d.rows[0].speaker, .me)
        XCTAssertEqual(d.rows[1].speaker, .other)
        XCTAssertEqual(d.name(of: .room), "Room")
        XCTAssertEqual(load("transcript-legacy-5starts", owner: "Alex").name(of: .me), "Alex")
    }

    func testRoomRowsAreRelabelledFromTheFinalRoomTextEvents() {
        let d = load("transcript-room")
        XCTAssertEqual(d.rows.count, 7)
        XCTAssertEqual(d.rows.map(\.speaker), [.room, .room, .me, .me, .room, .room, .room])
        // w3 was his reading (label me).
        XCTAssertEqual(d.rows[2].text, "Sure, I am a backend engineer with a strong focus on product and on keeping systems simple.")
        // w4 is split with me_words 10: two rows, his first ten words and the rest.
        XCTAssertEqual(d.rows[3].text, "I reduced the monthly close from six days to two.")
        XCTAssertEqual(d.rows[4].text, "Great, and how would you describe yourself as a team member?")
        XCTAssertEqual(d.rows[3].elapsed, d.rows[4].elapsed)
        XCTAssertEqual(d.rows[3].turnID, "w4")
        XCTAssertEqual(Set(d.rows.map(\.id)).count, 7, "ids are unique")
        // w5 is a split from a build without me_words: it stays one Room row.
        XCTAssertEqual(d.rows[5].speaker, .room)
        XCTAssertEqual(d.rows[5].text, "Okay that works for me, now the next topic. Do you have experience presenting results")
        // Blocks: consecutive rows of one speaker less than 60 s apart.
        XCTAssertEqual(d.blocks.map(\.count), [2, 2, 3])
    }

    func testRelabellingWithoutWallTimesMatchesByOrdinal() {
        // Two runs with the same turn ids and no wall times (a legacy file with too few starts): the k-th room row takes the k-th final.
        let lines = [line("w1", "room", "I am reading the card aloud now", 5), line("w1", "room", "Please tell me about the team", 8)]
        let events = [SessionEvent(t: 1, ev: "start"),
                      SessionEvent(t: 10, ev: "room_text", turn: "w1", final: true, label: "me"),
                      SessionEvent(t: 20, ev: "room_text", turn: "w1", final: true, label: "room")]
        let d = TranscriptDocument(lines: lines, events: events, ownerName: "Dana")
        XCTAssertEqual(d.runCount, 2)
        XCTAssertEqual(d.rows.map(\.speaker), [.me, .room])
        // If the counts differ the match is not trusted and the rows stay Room.
        let one = TranscriptDocument(lines: lines, events: Array(events.prefix(2)), ownerName: "Dana")
        XCTAssertEqual(one.rows.map(\.speaker), [.room, .room])
    }

    func testBlocksSplitOnSpeakerOrAGapOfSixtySeconds() {
        let near = TranscriptDocument(lines: [line("m1", "me", "a", 10), line("m2", "me", "b", 69.9), line("m3", "me", "c", 129.8)], events: [], ownerName: "Dana")
        XCTAssertEqual(near.blocks.map(\.count), [3])
        let far = TranscriptDocument(lines: [line("m1", "me", "a", 10), line("m2", "me", "b", 70), line("r1", "remote", "c", 71)], events: [], ownerName: "Dana")
        XCTAssertEqual(far.blocks.map(\.count), [1, 1, 1])
    }

    // MARK: cards

    func testLegacyCardsComeFromTheFirstLinesAndKeepTheirEllipsis() throws {
        let d = load("transcript-legacy-5starts")
        let c = try XCTUnwrap(d.rows[1].card, "run A, r1")
        XCTAssertEqual(c.tiers, ["S", "F", "D"])
        XCTAssertEqual(c.tierLabel, "S · F · D")
        XCTAssertEqual(c.say, "It began as a month-end tool for small finance teams, and it…")
        XCTAssertEqual(c.points, ["Harbor Ledger: built for teams of two to ten people in finan…"])
        XCTAssertTrue(try XCTUnwrap(c.say).hasSuffix("…") && c.points[0].hasSuffix("…"))
    }

    func testCardsAttachToTheRunWhoseWallTimeIsNearest() throws {
        let d = load("transcript-legacy-5starts")
        // r2 exists in run A and run B; the card at S2 + 54 s belongs to run B's r2, and run A's r2 has none.
        let a = try XCTUnwrap(d.rows.first { $0.run == 0 && $0.turnID == "r2" })
        let b = try XCTUnwrap(d.rows.first { $0.run == 1 && $0.turnID == "r2" })
        XCTAssertNil(a.card)
        XCTAssertEqual(b.card?.tiers, ["F", "D"])
        XCTAssertEqual(d.rows.compactMap(\.card).count, 4)
        // A turn with a card in a run whose ids are new.
        XCTAssertEqual(try XCTUnwrap(d.rows.first { $0.turnID == "r9" }).card?.tiers, ["S"])
    }

    func testANowCardGoesUnderTheLastRowBeforeIt() throws {
        let d = load("transcript-legacy-5starts")
        let host = try XCTUnwrap(d.rows.first { $0.turnID == "m11" })
        XCTAssertEqual(host.card?.tiers, ["F"])
        XCTAssertTrue(host.card?.say?.hasPrefix("A sandbox account") ?? false)
        // And it never lands before the first row.
        let early = SessionEvent(t: 100, ev: "card", turn: "now-1", tier: "F", id: "f1", kind: "say", text: "early")
        let e = TranscriptDocument(lines: [fwd(1_792_100_000, "r1", "remote", "x", 30)], events: [SessionEvent(t: 1_792_100_000, ev: "start"), early], ownerName: "Dana")
        XCTAssertFalse(e.hasCards)
    }

    func testCardDoneCarriesTheWholeCardAndSupersedesTheCardEventOfTheSameCall() throws {
        let d = load("transcript-forward")
        let r1 = try XCTUnwrap(d.rows.first { $0.run == 0 && $0.turnID == "r1" }?.card)
        XCTAssertEqual(r1.tiers, ["F", "D"])
        XCTAssertEqual(r1.say, "The planner builds delivery routes for a small courier fleet and re-plans when an order changes.")
        XCTAssertEqual(r1.points, ["Fleet of eight vans, one depot", "Re-plans in under two seconds", "Written in Python with OR-Tools"],
                       "every point of the turn in order, without repeats")
        let r2 = try XCTUnwrap(d.rows.first { $0.turnID == "r2" }?.card)
        XCTAssertTrue(r2.say?.count ?? 0 > 100 && !(r2.say?.hasSuffix("…") ?? true), "the full say, not the 60-character first line")
        XCTAssertEqual(r2.tiers, ["F"])
        // Run 2's r1 gets its own card, run 1's r1 keeps its.
        let again = try XCTUnwrap(d.rows.first { $0.run == 1 && $0.turnID == "r1" }?.card)
        XCTAssertEqual(again.say, "Costs are small: the infrastructure is about forty dollars a month.")
        XCTAssertEqual(d.rows.last?.card?.say, "If asked about scaling: the same design handles a few hundred vans.")
        XCTAssertTrue(d.hasCards && d.hasEvents)
    }

    func testRoomSplitCardGoesUnderTheRoomHalf() throws {
        let d = load("transcript-room")
        XCTAssertNil(d.rows[3].card)
        XCTAssertEqual(d.rows[4].card?.say, "I listen first, decide with the team, then commit fully.")
        XCTAssertEqual(d.rows[1].card?.points, ["Harbor Ledger: month-end close", "Trailhead: a hiking app"])
    }

    // MARK: search

    private func searchDoc() -> TranscriptDocument {
        TranscriptDocument(lines: [
            line("r1", "remote", "Yarın İstanbul'a gidiyoruz, istanbul çok güzel.", 5),
            line("m1", "me", "Perché no? Il caffè è buono, perché lo dici?", 12),
            line("r2", "remote", "Kırmızı bir araba ve KIRMIZI bir ev.", 20),
            line("m2", "me", "Nothing to see here.", 30),
        ], events: [], ownerName: "Dana")
    }

    func testSearchFoldsCaseAccentsAndTheTurkishI() {
        let d = searchDoc()
        // "istanbul" finds "İstanbul" and "istanbul", in order, both in row 0.
        let ist = TranscriptSearch.matches(in: d, query: "istanbul")
        XCTAssertEqual(ist.map(\.row), [0, 0])
        XCTAssertEqual(ist.map(\.range), [6 ..< 14, 28 ..< 36])
        // Accents: "perche" finds "Perché" and "perché".
        let perche = TranscriptSearch.matches(in: d, query: "perche")
        XCTAssertEqual(perche.map(\.row), [1, 1])
        XCTAssertEqual(perche.map(\.range), [0 ..< 6, 29 ..< 35])
        XCTAssertEqual(TranscriptSearch.matches(in: d, query: "CAFFE").count, 1)
        // The dotless ı and capital I fold to i.
        XCTAssertEqual(TranscriptSearch.matches(in: d, query: "kirmizi").map(\.row), [2, 2])
        XCTAssertEqual(TranscriptSearch.matches(in: d, query: "KIRMIZI").map(\.row), [2, 2])
        XCTAssertEqual(TranscriptSearch.matches(in: d, query: "İSTANBUL").count, 2)
    }

    func testSearchAlsoMatchesSpeakerNamesAndEmptyQueriesMatchNothing() {
        let d = searchDoc()
        let dana = TranscriptSearch.matches(in: d, query: "dana")
        XCTAssertEqual(dana.map(\.row), [1, 3])
        XCTAssertTrue(dana.allSatisfy { $0.range == nil }, "a name hit has no text range")
        XCTAssertEqual(TranscriptSearch.matches(in: d, query: "Other").map(\.row), [0, 2])
        XCTAssertTrue(TranscriptSearch.matches(in: d, query: "").isEmpty)
        XCTAssertTrue(TranscriptSearch.matches(in: d, query: "   ").isEmpty)
        XCTAssertTrue(TranscriptSearch.matches(in: d, query: "zzzz").isEmpty)
    }

    func testFindOrderCounterAndWrapAround() {
        let d = searchDoc()
        var find = TranscriptFind(matches: TranscriptSearch.matches(in: d, query: "i"))
        XCTAssertGreaterThan(find.count, 3)
        XCTAssertEqual(find.position, 1)
        XCTAssertEqual(find.matches.map(\.row), find.matches.map(\.row).sorted(), "hits are in row order")
        let n = find.count
        for _ in 0 ..< n - 1 { find.next() }
        XCTAssertEqual(find.position, n)
        find.next()
        XCTAssertEqual(find.position, 1, "next wraps to the first")
        find.previous()
        XCTAssertEqual(find.position, n, "previous wraps to the last")
        // Two hits of one word: "1 of 2", the current one is the filled one.
        var three = TranscriptFind(matches: TranscriptSearch.matches(in: d, query: "kirmizi"))
        XCTAssertEqual([three.position, three.count], [1, 2])
        XCTAssertEqual(three.ranges(inRow: 2).map(\.isCurrent), [true, false])
        three.next()
        XCTAssertEqual(three.ranges(inRow: 2).map(\.isCurrent), [false, true])
        XCTAssertNil(TranscriptFind().position)
        var none = TranscriptFind()
        none.next()
        none.previous()
        XCTAssertNil(none.current)
    }

    // MARK: export

    private func golden(_ name: String) throws -> String {
        try String(contentsOf: fixtureDir("transcript-forward").appendingPathComponent(name), encoding: .utf8)
    }

    func testPlainTextMatchesTheGoldenFile() throws {
        XCTAssertEqual(load("transcript-forward").plainText(), try golden("expected.txt"))
    }

    func testMarkdownWithAndWithoutCardsMatchesTheGoldenFiles() throws {
        let d = load("transcript-forward")
        let meta = "15 Oct 2026 · Meeting · 7 turns"
        XCTAssertEqual(d.markdown(title: "Courier planner review", meta: meta, includeCards: true), try golden("expected.md"))
        XCTAssertEqual(d.markdown(title: "Courier planner review", meta: meta, includeCards: false), try golden("expected-nocards.md"))
    }

    @MainActor
    func testMetaLineAndAskRows() {
        // The meta line follows the interface language; pin English so the result does not depend on the Mac's.
        L10nState.shared.apply(.en, preferred: ["en"])
        let d = load("transcript-forward")
        let date = Date(timeIntervalSince1970: 1_792_100_000)
        XCTAssertEqual(TranscriptDocument.metaLine(date: date, kind: "Phone", turns: 12, timeZone: TimeZone(identifier: "UTC")!), "15 Oct 2026 · Phone · 12 turns")
        XCTAssertEqual(d.askRows.count, 7)
        XCTAssertEqual(d.askRows[1].stamp, "0:22")
        XCTAssertEqual(d.askRows[1].speaker, "Other")
        XCTAssertEqual(d.row(forStamp: "1:02:05")?.speaker, .me)
        XCTAssertNil(d.row(forStamp: "9:99"))
    }
}
