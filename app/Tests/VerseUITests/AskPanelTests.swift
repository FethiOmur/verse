import AppKit
import SwiftUI
@testable import VerseUI
import XCTest

@MainActor
final class AskPanelTests: XCTestCase {
    private func fixtureDocument() -> TranscriptDocument {
        let fx = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/transcript-forward", isDirectory: true)
        return TranscriptDocument.load(sessionDir: fx, ownerName: "Dana")
    }

    // MARK: ChatLog

    func testChatLogHidesPairsBeforeTheLastResetAndKeepsNumbering() {
        let text = """
        {"type":"q","id":"q1","t":"x","text":"Before","model":"claude-sonnet-5-5"}
        {"type":"a","id":"a1","q":"q1","t":"x","text":"Old","model":"claude-sonnet-5-5","usage":{"input":1,"output":2,"cache_read":3,"cache_write":4},"cost_usd":0.5,"cost_estimated":false,"ms_first_token":1,"ms_total":2,"citations":[],"stop_reason":"end_turn","context":"full"}
        {"type":"reset","t":"x"}
        {"type":"q","id":"q2","t":"x","text":"After","model":"claude-sonnet-5-5"}
        {"type":"a","id":"a2","q":"q2","t":"x","text":"New [0:05]","model":"claude-sonnet-5-5","usage":{"input":10,"output":20,"cache_read":30,"cache_write":40},"cost_usd":0.0123,"cost_estimated":false,"ms_first_token":900,"ms_total":2400,"citations":["0:05"],"stop_reason":"end_turn","context":"full"}
        """
        let loaded = ChatLog.parse(text)
        XCTAssertEqual(loaded.turns.map(\.question), ["After"])
        XCTAssertEqual(loaded.turns[0].answer?.text, "New [0:05]")
        XCTAssertEqual(loaded.turns[0].answer?.usage, ChatUsage(input: 10, output: 20, cacheRead: 30, cacheWrite: 40))
        XCTAssertEqual(loaded.turns[0].answer?.citations, ["0:05"])
        XCTAssertEqual(loaded.turns[0].cost, 0.0123, accuracy: 1e-9)
        XCTAssertEqual(loaded.nextIndex, 3, "numbering continues past hidden pairs")
    }

    func testChatLogErrorsInterruptedQuestionsAndRetries() {
        let text = """
        {"type":"q","id":"q1","t":"x","text":"Why?","model":"m"}
        {"type":"a_error","id":"a1","q":"q1","t":"x","kind":"offline","message":"no network"}
        {"type":"q","id":"q2","t":"x","text":"Why?","model":"m"}
        {"type":"a","id":"a2","q":"q2","t":"x","text":"Because.","model":"m","usage":{},"cost_usd":0.001,"stop_reason":"end_turn"}
        {"type":"q","id":"q3","t":"x","text":"Dropped","model":"m"}
        {"type":"a_error","id":"a3","q":"q3","t":"x","kind":"credit_exhausted","message":"credit"}
        {"type":"q","id":"q4","t":"x","text":"Never finished","model":"m"}
        not json
        {"type":"future","x":1}
        """
        let turns = ChatLog.parse(text).turns
        XCTAssertEqual(turns.map(\.id), ["q2", "q3", "q4"], "q1 was retried by q2 and is shown once")
        XCTAssertEqual(turns[1].failure?.kind, "credit_exhausted")
        XCTAssertEqual(turns[2].failure?.kind, "interrupted")
        XCTAssertEqual(ChatLog.load(sessionDir: URL(fileURLWithPath: "/nonexistent-verse-dir")).turns, [])
    }

    // MARK: the answer as text

    func testAnAnswerBecomesBlocksAndCitationRunsOnlyForStampsThatExist() {
        let stamps: Set<String> = ["0:22", "1:02:05"]
        let blocks = AskAnswerParser.blocks("Dana said yes [0:22], then costs [1:02:05].\n- Nothing at [9:59] though.\n\n• Next [0:22][0:22]", validStamps: stamps)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertFalse(blocks[0].bullet)
        XCTAssertTrue(blocks[1].bullet && blocks[2].bullet)
        // A mark hugs its word: no run ends in a space before a mark, so a line never opens a gap before the comma after it.
        XCTAssertEqual(blocks[0].runs.map(\.text), ["Dana said yes", "0:22", ", then costs", "1:02:05", "."])
        XCTAssertEqual(blocks[0].runs.map(\.stamp), [nil, "0:22", nil, "1:02:05", nil])
        // Offsets count characters of the whole answer: chunks of a stream are measured the same way.
        XCTAssertEqual(blocks[0].runs.map(\.offset), [0, 14, 20, 33, 42])
        // An unknown stamp stays plain text.
        XCTAssertEqual(blocks[1].runs.map(\.text), ["Nothing at [9:59] though."])
        // Marks side by side.
        XCTAssertEqual(blocks[2].runs.map(\.text), ["Next", "0:22", "0:22"])
        XCTAssertEqual(AskAnswerParser.citedStamps(blocks), ["0:22", "1:02:05"])
    }

    func testAStampThatHasNotFinishedStreamingIsHeldBack() {
        let stamps: Set<String> = ["0:22"]
        XCTAssertEqual(AskAnswerParser.blocks("Yes [0:2", validStamps: stamps, streaming: true).first?.runs.map(\.text), ["Yes"])
        XCTAssertEqual(AskAnswerParser.blocks("Yes [", validStamps: stamps, streaming: true).first?.runs.map(\.text), ["Yes"])
        XCTAssertEqual(AskAnswerParser.blocks("Yes [0:22", validStamps: stamps, streaming: true).first?.runs.map(\.text), ["Yes"])
        XCTAssertEqual(AskAnswerParser.blocks("Yes [0:22]", validStamps: stamps, streaming: true).first?.runs.map(\.text), ["Yes", "0:22"])
        XCTAssertEqual(AskAnswerParser.blocks("Yes [0:2", validStamps: stamps, streaming: false).first?.runs.map(\.text), ["Yes [0:2"])
    }

    func testCitationsAreSuperscriptMarksThatLinkOnlyOnceTheAnswerIsComplete() throws {
        let ink = VT.Window(dark: false)
        let block = try XCTUnwrap(AskAnswerParser.blocks("Yes [0:22][1:20], then.", validStamps: ["0:22", "1:20"]).first)
        let done = AskAttributed.string(block, ink: ink, chunks: [], now: Date(), interactive: true)
        XCTAssertEqual(String(done.characters), "Yes\u{202F}0:22,\u{202F}1:20, then.")
        XCTAssertEqual(done.runs.compactMap(\.link).compactMap(AskAttributed.stamp(from:)), ["0:22", "1:20"])
        let live = AskAttributed.string(block, ink: ink, chunks: [], now: Date(), interactive: false)
        XCTAssertEqual(live.runs.compactMap(\.link).count, 0, "nothing under the pointer changes while text streams")
        XCTAssertEqual(AskAttributed.stamp(from: try XCTUnwrap(AskAttributed.url(for: "1:02:05"))), "1:02:05")
    }

    func testAChunkFadesInOverItsDurationAndEarlierTextIsUntouched() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let chunks = [AskChunk(start: 5, end: 10, at: t0)]
        XCTAssertEqual(AskFade.alpha(at: 3, chunks: chunks, now: t0), 1)
        XCTAssertEqual(AskFade.alpha(at: 7, chunks: chunks, now: t0), 0)
        let mid = AskFade.alpha(at: 7, chunks: chunks, now: t0.addingTimeInterval(AskFade.duration / 2))
        XCTAssertGreaterThan(mid, 0.5, "ease-out: more than half way at half the time")
        XCTAssertLessThan(mid, 1)
        XCTAssertEqual(AskFade.alpha(at: 7, chunks: chunks, now: t0.addingTimeInterval(AskFade.duration)), 1)
        XCTAssertEqual(AskFade.alpha(at: 10, chunks: chunks, now: t0), 1, "the next characters are not in this chunk")
        XCTAssertTrue(AskFade.isFading(chunks, now: t0.addingTimeInterval(0.1)))
        XCTAssertFalse(AskFade.isFading(chunks, now: t0.addingTimeInterval(1)))
    }

    func testCitationsAreReadAsTimes() {
        let en = Locale(identifier: "en")
        XCTAssertEqual(AskSpoken.time("1:20", locale: en), "1 minute, 20 seconds")
        XCTAssertEqual(AskSpoken.time("0:14", locale: en), "14 seconds")
        XCTAssertEqual(AskSpoken.time("1:02:05", locale: en), "1 hour, 2 minutes, 5 seconds")
        let blocks = AskAnswerParser.blocks("Costs came up [1:20].", validStamps: ["1:20"])
        XCTAssertEqual(AskSpoken.answer(blocks, locale: en), "Costs came up (at 1 minute, 20 seconds).")
    }

    func testThePanelFollowsTheStreamUntilTheReaderScrollsAwayAndPicksItUpAtTheBottom() {
        XCTAssertTrue(AskFollow.pins(restingDistance: 0))
        XCTAssertTrue(AskFollow.pins(restingDistance: 39))
        XCTAssertFalse(AskFollow.pins(restingDistance: 40), "scrolled up to read: stop following")
        XCTAssertFalse(AskFollow.showsJump(pinned: true, distance: 500, hasTurns: true), "following: no control")
        XCTAssertFalse(AskFollow.showsJump(pinned: false, distance: 60, hasTurns: true), "nearly at the bottom: no control")
        XCTAssertTrue(AskFollow.showsJump(pinned: false, distance: 400, hasTurns: true))
        XCTAssertFalse(AskFollow.showsJump(pinned: false, distance: 400, hasTurns: false), "the empty state has nothing to jump to")
    }

    func testShiftReturnInsertsTheLineBreakAtTheCaret() {
        XCTAssertEqual(AskComposerEdit.insertNewline(in: "héllo", selection: 2 ..< 2).text, "hé\nllo")
        XCTAssertEqual(AskComposerEdit.insertNewline(in: "héllo", selection: 2 ..< 2).caret, 3)
        let replaced = AskComposerEdit.insertNewline(in: "abcdef", selection: 1 ..< 4)
        XCTAssertEqual(replaced.text, "a\nef")
        XCTAssertEqual(replaced.caret, 2)
        let appended = AskComposerEdit.insertNewline(in: "abc", selection: nil)
        XCTAssertEqual(appended.text, "abc\n")
        XCTAssertEqual(appended.caret, 4)
        XCTAssertEqual(AskComposerEdit.insertNewline(in: "abc", selection: 9 ..< 12).text, "abc\n", "a stale selection is clamped")
    }

    func testACitationChipSetsTheTranscriptJumpToTheMatchingRow() throws {
        let doc = fixtureDocument()
        let jump = TranscriptJump()
        XCTAssertTrue(HomeSessionsPage.reveal("1:02:05", in: doc, jump: jump))
        XCTAssertEqual(jump.rowID, try XCTUnwrap(doc.row(forStamp: "1:02:05")).id)
        XCTAssertEqual(jump.serial, 1)
        XCTAssertFalse(HomeSessionsPage.reveal("9:59", in: doc, jump: jump))
        XCTAssertFalse(HomeSessionsPage.reveal("0:05", in: nil, jump: jump), "no transcript read yet")
        XCTAssertEqual(jump.serial, 1)
    }

    // MARK: text

    func testCostAndMetaLines() {
        XCTAssertEqual(AskFormat.cost(0.0104), "$0.010")
        XCTAssertEqual(AskFormat.cost(0.00091, estimated: true), "~$0.001")
        XCTAssertEqual(AskFormat.chatCost(0.0396), "$0.04")
        XCTAssertEqual(AskFormat.chatCost(0.004), "$0.004")
        XCTAssertEqual(AskFormat.chatCost(0), "$0.00")
        let a = ChatAnswer(id: "a1", text: "x", model: "claude-sonnet-5-5", usage: ChatUsage(), costUSD: 0.012, costEstimated: false, msFirstToken: 1, msTotal: 2400,
                           citations: [], stopReason: "end_turn")
        XCTAssertEqual(AskFormat.meta(a), "Sonnet · 2.4 s · $0.012")
    }

    func testEveryErrorKindHasAMessage() {
        for kind in ["credit_exhausted", "offline", "rate_limited", "overloaded", "auth", "key_missing", "refusal", "bad_request", "error", "interrupted", "start_failed"] {
            XCTAssertFalse(AskMessages.text(for: ChatFailure(kind: kind, message: "detail")).isEmpty, kind)
        }
    }

    // MARK: memory citations (memory spec 2.2, 5.2)

    private func source(_ key: String, _ kind: String, _ stamp: String? = nil, session: String = "s") -> AskSource {
        AskSource(key: key, session: session, title: "Title \(key)", kind: kind, stamp: stamp)
    }

    func testMemoryMarksAreOrdinalsByFirstCitationInThisAnswer() {
        let sources = [source("sk3f9qa", "turn", "12:34"), source("sp0m2vx", "summary")]
        let text = "Said by Marta [sk3f9qa 12:34] and again [sp0m2vx summary]. Then once more [sk3f9qa 12:34][sp0m2vx summary]."
        let r = AskAnswerParser.memoryBlocks(text, sources: sources)
        XCTAssertEqual(r.cited.map(\.key), ["sk3f9qa", "sp0m2vx"])
        let marks = r.blocks.flatMap(\.runs).compactMap(\.stamp)
        XCTAssertEqual(marks, ["1", "2", "1", "2"])
        // The mark hugs its word: no run ends in a space.
        XCTAssertEqual(r.blocks[0].runs.first?.text, "Said by Marta")
    }

    func testAnOrdinalFollowsTheOrderOfTheAnswerNotOfTheSourcesList() {
        let sources = [source("sk3f9qa", "turn", "12:34"), source("sp0m2vx", "summary")]
        let r = AskAnswerParser.memoryBlocks("First the summary [sp0m2vx summary], then the line [sk3f9qa 12:34].", sources: sources)
        XCTAssertEqual(r.cited.map(\.key), ["sp0m2vx", "sk3f9qa"])
        XCTAssertEqual(r.blocks[0].runs.compactMap(\.stamp), ["1", "2"])
    }

    func testACitationThatNamesNoKnownSourceStaysPlainText() {
        let r = AskAnswerParser.memoryBlocks("Unknown [sk3f9qa 9:99] and known [sk3f9qa 12:34].", sources: [source("sk3f9qa", "turn", "12:34")])
        XCTAssertEqual(r.cited.count, 1)
        XCTAssertEqual(r.blocks[0].runs.map(\.text).joined().contains("[sk3f9qa 9:99]"), true, "an invalid one is plain text")
        XCTAssertEqual(r.blocks[0].runs.compactMap(\.stamp), ["1"])
    }

    func testWhileStreamingNoBracketFlashesAndAnUnfinishedOneIsHeldBack() {
        let streaming = AskAnswerParser.memoryBlocks("The budget [sk3f9qa 12:34] by Friday [sk3f", sources: [], streaming: true)
        XCTAssertEqual(streaming.blocks[0].runs.map(\.text).joined(), "The budget by Friday")
        XCTAssertTrue(streaming.blocks[0].runs.allSatisfy { $0.stamp == nil })
        XCTAssertEqual(AskAnswerParser.memoryBlocks("Half a mark [", sources: [], streaming: true).blocks[0].runs.map(\.text).joined(), "Half a mark")
        // Offsets stay the raw positions, so the stream's fade still finds each word.
        let tail = AskAnswerParser.memoryBlocks("A [sk3f9qa 12:34] tail", sources: [], streaming: true).blocks[0].runs
        XCTAssertEqual(tail.last?.offset, 17)
    }

    func testTheSourceCaptionsAndTheSpokenForm() {
        let date = BriefLayout.date(from: "2026-10-19T17:00:00+02:00")
        var s = AskSource(key: "sk3f9qa", session: "s", title: "Halden Kickoff", date: date, kind: "turn", stamp: "12:34")
        XCTAssertTrue(AskMemoryFormat.caption(for: s).hasPrefix("Halden Kickoff · "))
        XCTAssertTrue(AskMemoryFormat.caption(for: s).hasSuffix(" · 12:34"))
        XCTAssertEqual(AskSpoken.source(1, s, locale: Locale(identifier: "en")), "Source 1: Halden Kickoff, 19 October, at 12 minutes, 34 seconds")
        s.kind = "summary"
        XCTAssertTrue(AskMemoryFormat.caption(for: s).hasSuffix(" · Summary"))
        XCTAssertTrue(AskSpoken.source(2, s, locale: Locale(identifier: "en")).hasSuffix(", Summary"))
        XCTAssertEqual(AskMemoryFormat.line(for: s).caption?.hasPrefix("Halden Kickoff"), true)
    }

    func testThePanelScopeNamesItselfAndItsStarters() {
        let all = AskPanelScope(current: .all, choices: [])
        XCTAssertEqual(all.title, "Ask all meetings")
        XCTAssertEqual(all.starters.count, 4)
        var entity = AskPanelScope(current: .entity("e-1"), choices: [])
        entity.entityName = "Marta Velin"
        entity.shortName = "Marta"
        XCTAssertEqual(entity.title, "Ask about Marta Velin")
        XCTAssertEqual(entity.starters, ["What did we agree last time?", "What did I promise Marta?", "What is still open with Marta?", "How does Marta like to work?"])
        XCTAssertEqual(AskPanelScope(current: .session("s"), choices: []).title, "Ask this meeting")
        var updating = all
        updating.updating = (3, 12)
        XCTAssertEqual(updating.updatingText, "Updating memory · 3 of 12")
    }

    // MARK: the view


    /// The panel lays out at 340 pt in both appearances, with answers, chips, an error and the empty state, and draws something.
    func testThePanelLaysOutAndDrawsInLightAndDark() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verse-askpanel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let chat = """
        {"type":"q","id":"q1","t":"x","text":"What did they ask me?","model":"m"}
        {"type":"a","id":"a1","q":"q1","t":"x","text":"About routes [0:22] and costs [1:02:05].\\n- A bullet [0:38].","model":"claude-sonnet-5-5","usage":{},"cost_usd":0.0214,"ms_total":4120,"citations":["0:22"],"stop_reason":"end_turn"}
        {"type":"q","id":"q2","t":"x","text":"And then?","model":"m"}
        {"type":"a_error","id":"a2","q":"q2","t":"x","kind":"offline","message":"offline"}
        """
        try Data(chat.utf8).write(to: ChatLog.url(sessionDir: dir))
        let doc = fixtureDocument()
        let ctx = AskContext(sessionDir: dir, ownerName: "Dana", title: "T", date: Date(), meCore: nil,
                             rows: doc.askRows.map { AskRow(stamp: $0.stamp, speaker: $0.speaker, text: $0.text) })
        for filled in [true, false] {
            for dark in [false, true] {
                let session = AskSession(makeBrain: { throw BrainStub.unavailable })
                session.launchesBrain = false
                if filled { session.open(ctx) }
                let view = AskPanel(session: session, settings: AppSettings(defaults: UserDefaults(suiteName: "dev.example.verse.test-panel")), stamps: Set(doc.rows.map(\.stamp)),
                                    onCitation: { _ in }, onClose: {})
                    .environment(\.homeInk, VT.Window(dark: dark))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .frame(width: 340, height: 600)
                    .background(dark ? Color.black : Color.white)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 340, height: 600)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, 340, accuracy: 1)
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                var colours = Set<UInt32>()
                for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                    for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                        if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                            colours.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
                        }
                    }
                }
                XCTAssertGreaterThan(colours.count, 6, "filled \(filled) dark \(dark)")
            }
        }
    }

    private enum BrainStub: Error { case unavailable }
}
