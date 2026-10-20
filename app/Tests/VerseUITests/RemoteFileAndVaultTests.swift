import Foundation
import VerseMeet
@testable import VerseUI
import VerseTurns
import XCTest

/// "Play test file as remote…": the session config.
@MainActor
final class RemoteFileConfigTests: XCTestCase {
    private func settings() -> AppSettings { AppSettings(defaults: UserDefaults(suiteName: "verse.tests.\(UUID().uuidString)")!) }

    func testRemoteFileRunKeepsTheMicrophoneOpenAsMe() {
        let dir = URL(fileURLWithPath: "/tmp/verse-session")
        let o = VerseController.runOptions(sessionDir: dir, settings: settings(), fakeBrain: false, testFile: "/tmp/interviewer.wav", micWithFile: true)
        XCTAssertEqual(o.file?.path, "/tmp/interviewer.wav", "the file is the remote channel")
        XCTAssertTrue(o.micWithFile, "and the microphone stays \"me\"")
        XCTAssertNil(o.source)
        XCTAssertNil(o.seconds, "a file plays to its end")
        XCTAssertTrue(o.micEnabled)
    }

    func testTheExistingFileOptionStaysRemoteOnly() {
        let dir = URL(fileURLWithPath: "/tmp/verse-session")
        let o = VerseController.runOptions(sessionDir: dir, settings: settings(), fakeBrain: false, testFile: "/tmp/q.wav")
        XCTAssertFalse(o.micWithFile, "--file and the Settings test file keep today's behaviour")
        XCTAssertFalse(RunOptions(sessionDir: dir).micWithFile)
        let live = VerseController.runOptions(sessionDir: dir, settings: settings(), fakeBrain: false, testFile: nil, micWithFile: true)
        XCTAssertNil(live.file)
        XCTAssertNotNil(live.seconds, "no file: a live meeting")
    }

    func testControllerUsesTheRemoteFileOnlyForThatRun() {
        let s = settings()
        let c = VerseController(settings: s)
        XCTAssertNil(c.testFile)
    }
}

/// The vault write: only after the click, to the right folder.
@MainActor
final class VaultSummaryTests: XCTestCase {
    let started = Date(timeIntervalSince1970: 1_800_000_000)

    private func vault(inbox: String? = "📥 000-Inbox") throws -> URL {
        let v = try tempDir().appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
        if let inbox { try FileManager.default.createDirectory(at: v.appendingPathComponent(inbox + "/Dump"), withIntermediateDirectories: true) }
        return v
    }

    private func session(summary: String? = "# Meeting summary\n\n## Decisions\n\n- Ship the pilot on Friday\n", age: TimeInterval = 5) throws -> URL {
        let s = try tempDir().appendingPathComponent("mara-northwindlabs", isDirectory: true)
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        if let summary {
            let f = s.appendingPathComponent("summary.md")
            try summary.write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: started.addingTimeInterval(age)], ofItemAtPath: f.path)
        }
        return s
    }

    private func coordinator(_ host: FakeHost, vault v: URL, on: Bool = true) throws -> MeetingCoordinator {
        MeetingCoordinator(host: host, settings: meetingSettings(vault: on, vaultPath: v.path), calendar: CalendarSource(backend: NoCalendar()),
                           detector: MeetingDetector(table: MicTable()), prepare: neverPrepare, upcoming: { _ in [] },
                           eventMap: EventSessionMap(url: try tempDir().appendingPathComponent("m.json")), now: { self.started })
    }

    private func run(_ dir: URL, code: Int32 = 0, test: Bool = false) -> FinishedRun {
        FinishedRun(code: code, sessionName: dir.lastPathComponent, sessionDir: dir, startedAt: started, isTest: test)
    }

    private func notes(in v: URL) -> [String] {
        let dir = v.appendingPathComponent("📥 000-Inbox/Verse")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    // MARK: only after the click

    func testNothingIsWrittenUntilSaveIsPressed() throws {
        let v = try vault(), host = FakeHost(), c = try coordinator(host, vault: v)
        c.runFinished(run(try session()))
        let p = try XCTUnwrap(host.overlay.state.meetingPrompt)
        XCTAssertEqual(p.title, "Save summary to vault?")
        XCTAssertEqual(p.kind, .saveSummary)
        XCTAssertTrue(p.subtitle.contains("📥 000-Inbox/Verse"), p.subtitle)
        XCTAssertTrue(notes(in: v).isEmpty, "the question alone writes nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: v.appendingPathComponent("📥 000-Inbox/Verse").path))

        host.overlay.promptAction(.accept)
        let names = notes(in: v)
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names[0].hasSuffix(" mara-northwindlabs.md"), names[0])
        let text = try String(contentsOf: v.appendingPathComponent("📥 000-Inbox/Verse/" + names[0]), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\ntitle: \"Meeting summary: mara-northwindlabs\"\ncreated: "), text)
        XCTAssertTrue(text.contains("type: note\nstatus: active\ntags: [verse, meeting-summary]\n---\n# Meeting summary"), text)
        XCTAssertTrue(text.contains("- Ship the pilot on Friday"))
        XCTAssertEqual(host.overlay.state.meetingPrompt?.kind, .saved)
    }

    func testNotNowWritesNothing() throws {
        let v = try vault(), host = FakeHost(), c = try coordinator(host, vault: v)
        c.runFinished(run(try session()))
        host.overlay.promptAction(.dismiss)
        XCTAssertNil(host.overlay.state.meetingPrompt)
        XCTAssertTrue(notes(in: v).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: v.appendingPathComponent("📥 000-Inbox/Verse").path))
    }

    func testOffByDefault() throws {
        let v = try vault(), host = FakeHost()
        let c = try coordinator(host, vault: v, on: false)
        c.runFinished(run(try session()))
        XCTAssertNil(host.overlay.state.meetingPrompt)
        XCTAssertTrue(notes(in: v).isEmpty)
        let fresh = MeetingSettings(defaults: UserDefaults(suiteName: "verse.tests.\(UUID().uuidString)")!)
        XCTAssertFalse(fresh.offerSummaryToVault, "the setting defaults to off")
        XCTAssertTrue(fresh.detectMeetings)
        XCTAssertFalse(fresh.useCalendar)
    }

    func testNoQuestionWithoutAFreshRealSummary() throws {
        let v = try vault()
        for (name, r): (String, FinishedRun) in [
            ("no summary.md", run(try session(summary: nil))),
            ("stale summary.md from an earlier run", run(try session(age: -3600))),
            ("failed run", run(try session(), code: 1)),
            ("canned brain or test file", run(try session(), test: true)),
            ("empty summary", run(try session(summary: ""))),
        ] {
            let host = FakeHost(), c = try coordinator(host, vault: v)
            c.runFinished(r)
            XCTAssertNil(host.overlay.state.meetingPrompt, name)
        }
        XCTAssertTrue(notes(in: v).isEmpty)
    }

    // MARK: where it goes

    func testFolderIsTheInboxVerseFolderEvenWithTheEmoji() throws {
        let emoji = try vault()
        XCTAssertEqual(VaultSummaryWriter(vaultRoot: emoji).destinationFolder().path, emoji.path + "/📥 000-Inbox/Verse")
        let plain = try vault(inbox: "000-Inbox")
        XCTAssertEqual(VaultSummaryWriter(vaultRoot: plain).destinationFolder().path, plain.path + "/000-Inbox/Verse")
        let none = try vault(inbox: nil)
        XCTAssertEqual(VaultSummaryWriter(vaultRoot: none).destinationFolder().path, none.path + "/000-Inbox/Verse")
    }

    func testWriterNeverOverwritesAndCleansTheTitle() throws {
        let v = try vault(), s = try session()
        let w = VaultSummaryWriter(vaultRoot: v)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let a = try w.write(summaryAt: s.appendingPathComponent("summary.md"), title: "Mara / Northwind: Labs [call]?", date: date)
        let b = try w.write(summaryAt: s.appendingPathComponent("summary.md"), title: "Mara / Northwind: Labs [call]?", date: date)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.lastPathComponent.hasSuffix(" Mara Northwind Labs call.md"), a.lastPathComponent)
        XCTAssertTrue(b.lastPathComponent.hasSuffix(" Mara Northwind Labs call (2).md"), b.lastPathComponent)
        XCTAssertEqual(a.deletingLastPathComponent().path, v.path + "/📥 000-Inbox/Verse")
    }

    func testMissingVaultIsAnErrorAndCreatesNothing() throws {
        let gone = try tempDir().appendingPathComponent("no-vault")
        let host = FakeHost(), c = try coordinator(host, vault: gone)
        c.runFinished(run(try session()))
        host.overlay.promptAction(.accept)
        XCTAssertEqual(host.overlay.state.meetingPrompt?.title, "Summary not saved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))
    }

    func testNoteTitleIsTheEventWhenTheMeetingStartedFromAnEvent() async throws {
        let v = try vault(), host = FakeHost(), c = try coordinator(host, vault: v)
        let ev = MeetingEvent(id: "e1", title: "Mara / Northwind Labs call", start: started, end: started.addingTimeInterval(1800), provider: .meet)
        c.handle(.started(MeetingInfo(bundleID: "ai.perplexity.comet", appName: "Comet", since: started, event: ev)))
        host.overlay.promptAction(.accept)
        XCTAssertEqual(host.startCount, 1)
        c.runFinished(run(try session()))
        host.overlay.promptAction(.accept)
        XCTAssertTrue(notes(in: v).first?.hasSuffix(" Mara Northwind Labs call.md") ?? false, "\(notes(in: v))")
    }
}
