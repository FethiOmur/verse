import AppKit
import Foundation
import SwiftUI
import VerseMeet
import VerseTurns
@testable import VerseUI
import XCTest

// F4c: Practice from a meeting. Fixtures are fictional (Harbor & Pine Analytics, Mira Castellan); nothing here reads the
// user's sessions, settings or Keychain.

private var brainDir: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("brain")
}

private var fixtureSession: URL { brainDir.appendingPathComponent("tests/fixtures/sim_session", isDirectory: true) }

private func scratch() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("verse-f4c-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// A session folder under `root`. `pack` nil: no pack.md at all. `created`: `meta.json` `created_at`.
@discardableResult
private func makeSession(_ name: String, in root: URL, pack: String? = "## FACTS\n[f001] name | A fact. | x | prep:L1\n",
                         bank: Int = 0, created: String? = nil, summaryAt: Date? = nil) throws -> URL {
    let fm = FileManager.default
    let d = root.appendingPathComponent(name, isDirectory: true)
    try fm.createDirectory(at: d, withIntermediateDirectories: true)
    if let pack { try Data(pack.utf8).write(to: d.appendingPathComponent("pack.md")) }
    if bank > 0 {
        let lines = (1...bank).map { #"{"id":"b\#(String(format: "%03d", $0))","question":"Question \#($0)?"}"# }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: d.appendingPathComponent("bank.jsonl"))
    }
    if let created {
        try Data(#"{"created_at":"\#(created)","languages":["en"]}"#.utf8).write(to: d.appendingPathComponent("meta.json"))
        // A real prep writes the pack when it records `created_at`.
        if pack != nil, let when = ISO8601DateFormatter().date(from: created) {
            try fm.setAttributes([.modificationDate: when], ofItemAtPath: d.appendingPathComponent("pack.md").path)
        }
    }
    if let summaryAt {
        let s = d.appendingPathComponent("summary.md")
        try Data("# Summary".utf8).write(to: s)
        try fm.setAttributes([.modificationDate: summaryAt], ofItemAtPath: s.path)
    }
    return d
}

@MainActor
private func makeSim(root: URL, useMe: Bool = true, meProfile: URL? = nil) -> (SimController, VerseController, AppSettings) {
    let defaults = UserDefaults(suiteName: "dev.example.verse.test-\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults)
    settings.useMeProfile = useMe
    let controller = VerseController(settings: settings, launch: LaunchOptions(arguments: []))
    controller.sessionsRoot = root
    let sim = SimController(settings: settings, simSettings: SimSettings(defaults: defaults), meeting: controller,
                            meProfile: meProfile ?? root.appendingPathComponent("no-profile"))
    return (sim, controller, settings)
}

// MARK: - the prep arguments

final class PracticeFromSessionTestsPrepArguments: XCTestCase {
    func testGoldenWithProfile() {
        var s = SimSetup(postingText: "")
        s.source = .meeting
        s.type = .technical
        s.difficulty = .tough
        s.lengthMin = 15
        s.meFile = URL(fileURLWithPath: "/tmp/profile/me.md")
        let a = s.prepArguments(sessionDir: URL(fileURLWithPath: "/tmp/sessions/harbor-pine"), out: URL(fileURLWithPath: "/tmp/sessions"))
        XCTAssertEqual(a, ["-u", "-m", "verse_brain.prep", "--sim", "--from-session", "/tmp/sessions/harbor-pine", "--me", "/tmp/profile/me.md",
                           "--out", "/tmp/sessions", "--type", "technical", "--difficulty", "tough", "--length", "15"])
    }

    func testGoldenWithoutProfileAndFake() {
        var s = SimSetup(postingText: "")
        s.source = .meeting
        s.fake = true
        let a = s.prepArguments(sessionDir: URL(fileURLWithPath: "/tmp/sessions/harbor-pine"), out: URL(fileURLWithPath: "/tmp/sessions"))
        XCTAssertEqual(a, ["-u", "-m", "verse_brain.prep", "--sim", "--from-session", "/tmp/sessions/harbor-pine", "--out", "/tmp/sessions",
                           "--type", "mixed", "--difficulty", "standard", "--length", "30", "--fake"])
    }

    /// Only flags, enum words, numbers and paths: no key, no profile text, no pack text, and none of the posting-only
    /// flags that prep refuses together with `--from-session`.
    func testNothingButPathsAndChoicesIsOnTheLine() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = "SECRET-PROFILE-LINE-4711"
        let me = dir.appendingPathComponent("me.md")
        try Data("[m001] \(secret)\n".utf8).write(to: me)
        var s = SimSetup(postingText: "A posting body that must not travel", postingURL: URL(string: "https://jobs.example/1"))
        s.source = .meeting
        s.meFile = me
        s.company = "Typed Company"
        s.note = "a private note"
        s.cv = URL(fileURLWithPath: "/tmp/cv.pdf")
        s.repos = ["/tmp/repo"]
        let a = s.prepArguments(sessionDir: dir, out: dir)
        let line = a.joined(separator: " ")
        for banned in [secret, "must not travel", "Typed Company", "a private note", "--posting-file", "--posting-url", "--cv", "--note", "--repo",
                       "--company", "--lang", "sk-ant", "api-key", "--key"] {
            XCTAssertFalse(line.contains(banned), "\(banned) is on the line: \(line)")
        }
        for (i, x) in a.enumerated() where x.hasPrefix("--") && i + 1 < a.count && !a[i + 1].hasPrefix("--") {
            XCTAssertTrue(["--from-session", "--me", "--out", "--type", "--difficulty", "--length"].contains(x), "unexpected flag \(x)")
        }
    }

    func testPostingArgumentsAreUnchanged() {
        var s = SimSetup(postingText: "x")
        s.fake = true
        let a = s.prepArguments(postingFile: URL(fileURLWithPath: "/tmp/p/posting.txt"), noteFile: nil, out: URL(fileURLWithPath: "/tmp/root"))
        XCTAssertEqual(a, ["-u", "-m", "verse_brain.prep", "--sim", "--posting-file", "/tmp/p/posting.txt", "--out", "/tmp/root", "--type", "mixed",
                           "--difficulty", "standard", "--length", "30", "--lang", "en", "--no-vault", "--fake"])
    }
}

// MARK: - which sessions are offered, and the preview

final class PracticeFromSessionTestsMeetings: XCTestCase {
    func testPopupListsPreparedMeetingsOnly() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("ironwood-lena", in: root, created: "2026-10-18T09:00:00+00:00")
        try makeSession("mara-northwindlabs", in: root, created: "2026-10-19T09:00:00+00:00")
        try makeSession("general-core", in: root)
        try makeSession("adhoc-20261016-1432-room", in: root)
        try makeSession("sim-20261013-1000-brightwave", in: root)
        try makeSession("empty-pack", in: root, pack: "")
        try makeSession("no-pack", in: root, pack: nil)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("stray-folder"), withIntermediateDirectories: true)
        let list = PracticeMeetings.list(root: root)
        XCTAssertEqual(list.map(\.name), ["mara-northwindlabs", "ironwood-lena"], "prepared only, newest first")
        XCTAssertEqual(list.map(\.title), ["Mara Northwindlabs", "Ironwood Lena"])
    }

    func testNewestFirstUsesTheLatestSignalOfEachSession() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        // Prepared long ago but held (and summarized) yesterday, against one prepared an hour ago.
        try makeSession("old-prep-recent-call", in: root, created: "2026-01-01T09:00:00+00:00", summaryAt: now.addingTimeInterval(-86_400))
        try makeSession("fresh-prep", in: root, summaryAt: now.addingTimeInterval(-3_600))
        XCTAssertEqual(PracticeMeetings.list(root: root).map(\.name), ["fresh-prep", "old-prep-recent-call"])
    }

    func testDefaultIsTheNearestUpNextItemThatHasASession() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("ironwood-lena", in: root, created: "2026-10-18T09:00:00+00:00")
        try makeSession("mara-northwindlabs", in: root, created: "2026-10-19T09:00:00+00:00")
        try makeSession("north-wind-intro", in: root, created: "2026-10-17T09:00:00+00:00")
        let list = PracticeMeetings.list(root: root)
        // Calendar order: an unprepared meeting first, then a session that is not a meeting any more, then two prepared ones.
        XCTAssertEqual(PracticeMeetings.defaultPick(upNext: [nil, "deleted-session", "north-wind-intro", "ironwood-lena"], among: list),
                       "north-wind-intro")
        XCTAssertEqual(PracticeMeetings.defaultPick(upNext: [nil, nil], among: list), "mara-northwindlabs", "no Up next session: the newest")
        XCTAssertEqual(PracticeMeetings.defaultPick(upNext: [], among: list), "mara-northwindlabs")
        XCTAssertNil(PracticeMeetings.defaultPick(upNext: ["north-wind-intro"], among: []))
    }

    func testPreviewCountsComeFromTheFixtureBankAndFacts() {
        let p = PracticeMeetings.preview(sessionDir: fixtureSession)
        XCTAssertEqual(p, PracticeMeetings.Preview(questions: 7, facts: 7), "brain/tests/fixtures/sim_session: 7 bank lines, 7 [f…] lines")
    }

    func testPreviewIgnoresBlankLinesAndOtherSections() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = """
        ## FACTS
        [f001] name | One. | x | prep:L1
        [f002] number | Two. | 2 | prep:L2

        ## GLOSSARY
        [g001] Term: a thing. | prep:L3
        ## ANSWER BANK
        [b001] Q (en): Why?
        [f099] not a fact, it sits in another section
        """
        let dir = try makeSession("s", in: root, pack: pack)
        try Data("{\"id\":\"b001\"}\n\n   \n{\"id\":\"b002\"}\n".utf8).write(to: dir.appendingPathComponent("bank.jsonl"))
        XCTAssertEqual(PracticeMeetings.preview(sessionDir: dir), .init(questions: 2, facts: 2))
        XCTAssertEqual(PracticeMeetings.preview(sessionDir: root.appendingPathComponent("missing")), .init(questions: 0, facts: 0))
    }
}

// MARK: - the controller

@MainActor
final class PracticeFromSessionTestsController: XCTestCase {
    func testDefaultsToAMeetingWhenOneIsPreparedElseToAPosting() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (sim, _, _) = makeSim(root: root)
        sim.refreshMeetings()
        XCTAssertEqual(sim.setup.source, .posting, "nothing prepared: today's flow")
        XCTAssertNil(sim.meetingName)
        try makeSession("ironwood-lena", in: root, bank: 3)
        sim.refreshMeetings()
        XCTAssertEqual(sim.setup.source, .meeting)
        XCTAssertEqual(sim.meetingName, "ironwood-lena")
        XCTAssertEqual(sim.meetingPreview, .init(questions: 3, facts: 1))
        // The user's own choice survives a refresh.
        sim.chooseSource(.posting)
        sim.refreshMeetings()
        XCTAssertEqual(sim.setup.source, .posting)
    }

    func testRefreshPicksTheNearestUpNextItemAndKeepsALaterChoice() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("ironwood-lena", in: root, created: "2026-10-18T09:00:00+00:00")
        try makeSession("mara-northwindlabs", in: root, created: "2026-10-19T09:00:00+00:00")
        let (sim, _, settings) = makeSim(root: root)
        let defaults = UserDefaults(suiteName: "dev.example.verse.test-\(UUID().uuidString)")!
        let upNext = HomeUpNextModel(settings: settings, meeting: MeetingSettings(defaults: defaults), sessions: { [] })
        upNext.setItems([HomeUpNextItem(id: "a", title: "Intro", meta: "Today", session: nil),
                         HomeUpNextItem(id: "b", title: "Lena", meta: "Tomorrow", session: "ironwood-lena")])
        sim.refreshMeetings(upNext: upNext.items.map(\.session))
        XCTAssertEqual(sim.meetingName, "ironwood-lena")
        sim.selectMeeting("mara-northwindlabs")
        sim.refreshMeetings(upNext: upNext.items.map(\.session))
        XCTAssertEqual(sim.meetingName, "mara-northwindlabs", "a chosen meeting is kept")
    }

    func testMeetingModeNeedsNoPostingAndFolderNameFollowsTheSession() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("ironwood-lena", in: root)
        let (sim, _, _) = makeSim(root: root)
        XCTAssertFalse(sim.canPrepare, "posting mode, nothing confirmed")
        sim.refreshMeetings()
        XCTAssertEqual(sim.setup.source, .meeting)
        XCTAssertTrue(sim.canPrepare)
        let name = try XCTUnwrap(sim.expectedFolderName)
        XCTAssertTrue(name.hasPrefix("sim-") && name.hasSuffix("-ironwood-lena"), name)
        sim.chooseSource(.posting)
        XCTAssertFalse(sim.canPrepare, "the posting is not confirmed")
    }

    func testUpNextPractiseSelectsTheSessionAsAMeeting() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("ironwood-lena", in: root, bank: 2, created: "2026-10-18T09:00:00+00:00")
        try makeSession("mara-northwindlabs", in: root, bank: 5, created: "2026-10-19T09:00:00+00:00")
        let (sim, _, _) = makeSim(root: root)
        sim.chooseSource(.posting)
        XCTAssertTrue(sim.practise(session: "ironwood-lena"))
        XCTAssertEqual(sim.setup.source, .meeting)
        XCTAssertEqual(sim.meetingName, "ironwood-lena")
        XCTAssertEqual(sim.meetingPreview?.questions, 2)
        XCTAssertFalse(sim.practise(session: "general-core"), "not a prepared meeting")
        XCTAssertEqual(sim.meetingName, "ironwood-lena", "an unknown name changes nothing")
    }

    /// The button's route: the router carries the name, the Practice page takes it when it appears.
    func testPractiseButtonOpensPracticeWithTheSessionSelected() async throws {
        _ = NSApplication.shared
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("ironwood-lena", in: root, bank: 2, created: "2026-10-18T09:00:00+00:00")
        try makeSession("mara-northwindlabs", in: root, bank: 5, created: "2026-10-19T09:00:00+00:00")
        let (sim, controller, _) = makeSim(root: root)
        let router = HomeRouter()
        router.page = .prepare
        router.showPractice(session: "ironwood-lena")
        XCTAssertEqual(router.page, .practice)
        XCTAssertEqual(router.practiceSession, "ironwood-lena")

        let view = SimSetupView(sim: sim, meeting: controller, upNext: nil, router: router)
            .environment(\.colorScheme, .light).frame(width: 900, height: 700)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false   // ARC owns it; a closed titled window released twice crashed the runner
        window.contentView = NSHostingView(rootView: view)
        window.contentView?.layoutSubtreeIfNeeded()
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<100 where router.practiceSession != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(router.practiceSession, "taken once")
        XCTAssertEqual(sim.setup.source, .meeting)
        XCTAssertEqual(sim.meetingName, "ironwood-lena", "not the newest one the page would pick by itself")
        XCTAssertEqual(sim.meetingPreview?.questions, 2)
    }

    func testMeetingSourceFallsBackWhenNoMeetingRemains() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("ironwood-lena", in: root)
        let (sim, _, _) = makeSim(root: root)
        sim.refreshMeetings()
        XCTAssertEqual(sim.meetings.count, 1)
        // Selecting nothing valid after the folder is gone falls back to a valid one on the next refresh.
        try FileManager.default.removeItem(at: root.appendingPathComponent("ironwood-lena"))
        sim.refreshMeetings()
        XCTAssertTrue(sim.meetings.isEmpty)
        XCTAssertNil(sim.meetingName)
        XCTAssertEqual(sim.setup.source, .posting, "a meeting source with no meeting falls back to the posting")
    }
}

// MARK: - prep through the app's runner, offline

final class PracticeFromSessionTestsPrepRun: XCTestCase {
    func testFakePrepBuildsASimFolderAndLeavesTheSessionAlone() async throws {
        let python = brainDir.appendingPathComponent(".venv/bin/python")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path), "brain/.venv missing")
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("harbor-pine-intro", isDirectory: true)
        try FileManager.default.copyItem(at: fixtureSession, to: session)
        let before = try Data(contentsOf: session.appendingPathComponent("pack.md"))
        var s = SimSetup(postingText: "")
        s.source = .meeting
        s.meetingSession = session
        s.meFile = session.appendingPathComponent("me.md")
        s.lengthMin = 15
        s.fake = true
        let lines = LineSink()
        let outcome = await SimPrep().run(s, brainDir: brainDir, root: root, onLine: { lines.add($0) })
        guard case .done(let dir) = outcome else { return XCTFail("prep: \(outcome) \(lines.all)") }
        XCTAssertTrue(dir.lastPathComponent.hasSuffix("-harbor-pine-intro"), dir.lastPathComponent)
        XCTAssertTrue(dir.lastPathComponent.hasPrefix("sim-"))
        let summary = try XCTUnwrap(SimPackSummary.load(sessionDir: dir))
        XCTAssertEqual(summary.sourceSession, "harbor-pine-intro")
        XCTAssertEqual(summary.lang, "en", "meta.json languages[0]")
        XCTAssertEqual(SimPackSummary.lang(sessionDir: dir), "en")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("source_pack.md").path))
        XCTAssertEqual(try Data(contentsOf: session.appendingPathComponent("pack.md")), before, "the meeting's pack is not touched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("verse-sim-prep-") }, [], "a meeting source writes no temp posting")
    }

    func testMeetingSourceWithoutASessionFailsBeforeRunning() async {
        var s = SimSetup(postingText: "")
        s.source = .meeting
        let outcome = await SimPrep().run(s, brainDir: brainDir, root: FileManager.default.temporaryDirectory, onLine: { _ in })
        if case .failed = outcome { return }
        XCTFail("expected a failure, got \(outcome)")
    }

    func testPackSummaryLanguage() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        func sim(_ json: String) throws -> URL {
            let d = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: d.appendingPathComponent("sim.json"))
            return d
        }
        XCTAssertEqual(SimPackSummary.lang(sessionDir: try sim(#"{"lang":"it","questions":[]}"#)), "it")
        XCTAssertEqual(SimPackSummary.lang(sessionDir: try sim(#"{"lang":"tr-TR"}"#)), "tr")
        XCTAssertEqual(SimPackSummary.lang(sessionDir: try sim(#"{"lang":"de"}"#)), "en")
        XCTAssertEqual(SimPackSummary.lang(sessionDir: try sim(#"{"company":"x"}"#)), "en", "older packs have no lang")
        XCTAssertEqual(SimPackSummary.lang(sessionDir: root.appendingPathComponent("missing")), "en")
        XCTAssertNil(SimPackSummary.load(sessionDir: try sim(#"{"source":"posting"}"#))?.sourceSession)
    }
}
