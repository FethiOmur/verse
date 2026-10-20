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

    // MARK: chips

    func testAnAnswerBecomesWordsAndChipsOnlyForStampsThatExist() {
        let stamps: Set<String> = ["0:22", "1:02:05"]
        let lines = AskAnswerParser.lines("Dana said yes [0:22], then costs [1:02:05].\n- Nothing at [9:59] though.\n\n- Next [0:22][0:22]", validStamps: stamps)
        XCTAssertEqual(lines.count, 3)
        XCTAssertFalse(lines[0].bullet)
        XCTAssertTrue(lines[1].bullet && lines[2].bullet)
        let chips0 = lines[0].pieces.compactMap { if case .chip(let s, _) = $0 { s } else { nil } }
        XCTAssertEqual(chips0, ["0:22", "1:02:05"])
        // The chip hugs the comma after it and keeps a space before it.
        XCTAssertEqual(lines[0].pieces[3], .chip("0:22", spaceBefore: true))
        XCTAssertEqual(lines[0].pieces[4], .word(",", spaceBefore: false))
        // An unknown stamp stays plain text.
        XCTAssertEqual(lines[1].pieces.compactMap { if case .chip = $0 { 1 } else { nil } }.count, 0)
        XCTAssertTrue(lines[1].pieces.contains(.word("[9:59]", spaceBefore: true)))
        // Chips side by side.
        XCTAssertEqual(lines[2].pieces.suffix(2), [.chip("0:22", spaceBefore: true), .chip("0:22", spaceBefore: false)])
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
                let view = AskPanel(session: session, settings: AppSettings(defaults: UserDefaults(suiteName: "dev.fethiverse.verse.test-panel")), stamps: Set(doc.rows.map(\.stamp)),
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
