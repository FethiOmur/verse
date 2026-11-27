import Foundation
import VerseTurns
import XCTest
@testable import VerseUI

/// "Rehearse a line…": the script entry point's URLs, and the guards that keep a rehearsal away from a real call.
@MainActor
final class RehearsalCommandTests: XCTestCase {
    private func parse(_ s: String) -> RehearsalCommand? { RehearsalCommand.parse(URL(string: s)!) }

    func testParsesStartSayEndAndOpen() {
        XCTAssertEqual(parse("verse-rehearse://start?session=interview-demo"), .start(session: "interview-demo"))
        XCTAssertEqual(parse("verse-rehearse://start?session=Team%20sync%202"), .start(session: "Team sync 2"))
        XCTAssertEqual(parse("verse-rehearse://say?speaker=them&text=Why%20do%20you%20want%20this%20role%3F"),
                       .say(speaker: .them, text: "Why do you want this role?", session: nil))
        XCTAssertEqual(parse("verse-rehearse://say?speaker=me&text=Because%20%26%20also&session=s1"),
                       .say(speaker: .me, text: "Because & also", session: "s1"))
        XCTAssertEqual(parse("VERSE-REHEARSE://SAY?speaker=Them&text=Hi%0A%20%20there"), .say(speaker: .them, text: "Hi there", session: nil),
                       "case-insensitive scheme, action and speaker; whitespace runs become one space")
        XCTAssertEqual(parse("verse-rehearse://say?speaker=remote&text=x"), .say(speaker: .them, text: "x", session: nil))
        XCTAssertEqual(parse("verse-rehearse:say?speaker=me&text=x"), .say(speaker: .me, text: "x", session: nil), "action in the path")
        XCTAssertEqual(parse("verse-rehearse://end"), .end)
        XCTAssertEqual(parse("verse-rehearse://stop"), .end)
        XCTAssertEqual(parse("verse-rehearse://open"), .open)
        XCTAssertEqual(parse("verse-rehearse://"), .open)
    }

    func testRejectsMalformedCommands() {
        XCTAssertNil(parse("verse-rehearse://start"), "start needs a session")
        XCTAssertNil(parse("verse-rehearse://start?session=%20%20"))
        XCTAssertNil(parse("verse-rehearse://say?speaker=them"), "say needs text")
        XCTAssertNil(parse("verse-rehearse://say?speaker=them&text=%20%0A"))
        XCTAssertNil(parse("verse-rehearse://say?speaker=boss&text=hi"), "unknown speaker")
        XCTAssertNil(parse("verse-rehearse://say?text=hi"), "speaker is required")
        XCTAssertNil(parse("verse-rehearse://delete?session=s1"), "unknown action")
        XCTAssertNil(parse("https://example.com/say?speaker=them&text=hi"), "another scheme")
    }

    // MARK: guards

    private func makeController() throws -> (VerseController, URL, () -> Void) {
        let suite = "dev.example.verse.test-rehearsal-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verse-rehearsal-test-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("s1", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "# pack\n".write(to: dir.appendingPathComponent("pack.md"), atomically: true, encoding: .utf8)
        let c = VerseController(settings: AppSettings(defaults: defaults))
        c.sessionsRoot = root
        c.refreshSessions()
        return (c, dir, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        })
    }

    func testARealCallRefusesRehearsalAndIsLeftAlone() async throws {
        let (c, dir, cleanup) = try makeController()
        defer { cleanup() }
        c.setRunningForPreview(true, session: dir)
        XCTAssertEqual(c.startRehearsal(session: "s1"), .callRunning)
        XCTAssertNil(c.rehearsal)
        XCTAssertEqual(c.rehearse(.them, "Hello there"), .callRunning, "a line never goes into a real call")
        await c.endRehearsal()
        XCTAssertTrue(c.running, "ending a rehearsal never stops a real call")
        XCTAssertEqual(c.recordingSessionName, "s1")

        // The script entry point shows the refusal (the panel's message line) instead of acting.
        let desk = RehearsalDesk(controller: c)
        desk.presentsPanel = false
        let refusal = await desk.perform(.say(speaker: .them, text: "Hello there", session: "s1"))
        XCTAssertEqual(refusal, .callRunning)
        XCTAssertEqual(desk.message, RehearsalRefusal.callRunning.message)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["pack.md"], "nothing written to the session")
    }

    func testPracticeAndUnknownSessionsAreRefused() throws {
        let (c, _, cleanup) = try makeController()
        defer { cleanup() }
        c.startBlocked = { true }
        XCTAssertEqual(c.startRehearsal(session: "s1"), .practiceRunning)
        c.startBlocked = { false }
        XCTAssertEqual(c.startRehearsal(session: "nope"), .noSuchSession("nope"))
        XCTAssertEqual(c.rehearse(.me, "Hi"), .notStarted)
        XCTAssertNil(c.rehearsal)
        XCTAssertFalse(c.running)
    }

    func testRefusalMessagesAreLocalizedText() {
        for r: RehearsalRefusal in [.callRunning, .practiceRunning, .otherRehearsal("s1"), .noSuchSession("s1"), .notStarted, .emptyLine,
                                    .copyFailed("disk full")] {
            XCTAssertFalse(r.message.isEmpty)
        }
        XCTAssertTrue(RehearsalRefusal.noSuchSession("s1").message.contains("s1"))
    }
}
