import AppKit
import Foundation
import SwiftUI
import VerseTurns
@testable import VerseUI
import XCTest

// The Practise button on a session's detail (Sessions page): who gets it, where it sends the user, and what the Practice page does
// with the request while something else is running. Fixtures are fictional (Northwind Labs, Harbor Pine); nothing here reads the
// user's sessions, settings or Keychain.

private func scratch() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("verse-practicebtn-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// A session folder. `pack` nil: no pack.md. `summary`: a past meeting (it has a summary). `report`: a practice run.
@discardableResult
private func makeSession(_ name: String, in root: URL, pack: String? = "## FACTS\n[f001] name | A fact. | x | prep:L1\n",
                         summary: Bool = false, bank: Int = 0) throws -> URL {
    let d = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    if let pack { try Data(pack.utf8).write(to: d.appendingPathComponent("pack.md")) }
    if summary { try Data("## Summary\nA fictional call.\n".utf8).write(to: d.appendingPathComponent("summary.md")) }
    if bank > 0 {
        let lines = (1...bank).map { #"{"id":"b\#(String(format: "%03d", $0))","question":"Question \#($0)?"}"# }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: d.appendingPathComponent("bank.jsonl"))
    }
    return d
}

@MainActor
private func makeSim(root: URL) -> (SimController, VerseController, AppSettings) {
    let defaults = UserDefaults(suiteName: "dev.fethiverse.verse.test-\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults)
    settings.useMeProfile = false
    let controller = VerseController(settings: settings, launch: LaunchOptions(arguments: []))
    controller.sessionsRoot = root
    let sim = SimController(settings: settings, simSettings: SimSettings(defaults: defaults), meeting: controller,
                            meProfile: root.appendingPathComponent("no-profile"))
    return (sim, controller, settings)
}

// MARK: - who gets the button

final class SessionPracticeButtonTestsVisibility: XCTestCase {
    private func style(_ name: String, in root: URL, recording: String? = nil) -> PracticeFromSession.Style? {
        PracticeFromSession.style(for: HomeSession.load(name: name, root: root), recordingSession: recording)
    }

    func testAPreparedSessionThatWasNeverUsedGetsTheProminentButton() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("Northwind Labs case review", in: root)
        XCTAssertEqual(HomeSession.load(name: "Northwind Labs case review", root: root).kind, .prepared)
        XCTAssertEqual(style("Northwind Labs case review", in: root), .prominent)
    }

    func testAPastMeetingWithAPackGetsTheSecondaryButton() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("Harbor Pine intro call", in: root, summary: true)
        XCTAssertEqual(HomeSession.load(name: "Harbor Pine intro call", root: root).kind, .meeting)
        XCTAssertEqual(style("Harbor Pine intro call", in: root), .secondary)
    }

    func testPracticeRunsGetNoButton() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("sim-20261013-1000-Northwind", in: root)
        let report = root.appendingPathComponent("sim-20261013-1000-Northwind/report.html")
        try Data("<html></html>".utf8).write(to: report)
        XCTAssertEqual(HomeSession.load(name: "sim-20261013-1000-Northwind", root: root).kind, .practice)
        XCTAssertNil(style("sim-20261013-1000-Northwind", in: root), "with a pack and a report, and still no button")
        try makeSession("sim-20261014-0900-Harbor", in: root, summary: true)
        XCTAssertNil(style("sim-20261014-0900-Harbor", in: root))
    }

    func testTheGeneralPrepGetsNoButtonEvenWithAPack() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession(GeneralPrep.name, in: root)
        XCTAssertNil(style(GeneralPrep.name, in: root))
        try makeSession("general-core-copy", in: root)
        XCTAssertNotNil(style("general-core-copy", in: root), "only the standing prep itself is excluded, not a name that starts like it")
    }

    func testAnUnpreparedCallGetsNoButton() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("adhoc-20261016-1432-room", in: root, pack: "## FACTS\n[f001] name | A fact. | x | prep:L1\n", summary: true)
        XCTAssertEqual(HomeSession.load(name: "adhoc-20261016-1432-room", root: root).kind, .call)
        XCTAssertNil(style("adhoc-20261016-1432-room", in: root))
    }

    func testASessionWithoutAPackOrWithAnEmptyOneGetsNoButton() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("No pack call", in: root, pack: nil, summary: true)
        try makeSession("Empty pack call", in: root, pack: "", summary: true)
        XCTAssertNil(style("No pack call", in: root))
        XCTAssertNil(style("Empty pack call", in: root), "PracticeMeetings calls only a non-empty pack.md prepared")
    }

    func testTheSessionBeingRecordedGetsNoButtonButAnotherOneDoes() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("Northwind Labs case review", in: root)
        try makeSession("Harbor Pine intro call", in: root, summary: true)
        XCTAssertNil(style("Northwind Labs case review", in: root, recording: "Northwind Labs case review"))
        XCTAssertEqual(style("Harbor Pine intro call", in: root, recording: "Northwind Labs case review"), .secondary)
        XCTAssertEqual(style("Northwind Labs case review", in: root, recording: nil), .prominent)
    }

    @MainActor
    func testTheControllerReportsTheRecordingSessionTheRuleReads() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try makeSession("Northwind Labs case review", in: root)
        try makeSession("Harbor Pine intro call", in: root, summary: true)
        let (_, controller, _) = makeSim(root: root)
        controller.setRunningForPreview(true, session: dir)
        defer { controller.setRunningForPreview(false) }
        let recording = controller.recordingSessionName
        XCTAssertEqual(recording, "Northwind Labs case review")
        XCTAssertNil(PracticeFromSession.style(for: HomeSession.load(name: "Northwind Labs case review", root: root), recordingSession: recording))
        XCTAssertEqual(PracticeFromSession.style(for: HomeSession.load(name: "Harbor Pine intro call", root: root), recordingSession: recording), .secondary)
    }

    func testTheButtonUsesTheSidebarsPracticeSymbol() {
        XCTAssertEqual(PracticeFromSession.symbol, "person.wave.2")
        XCTAssertEqual(PracticeFromSession.symbol, HomePage.practice.symbol)
    }
}

// MARK: - where it sends the user

@MainActor
final class SessionPracticeButtonTestsRouting: XCTestCase {
    func testTheButtonRoutesThroughTheRoutersPracticeRequest() {
        let router = HomeRouter()
        router.page = .sessions
        router.selectedSession = "Northwind Labs case review"
        router.showPractice(session: "Northwind Labs case review")
        XCTAssertEqual(router.page, .practice)
        XCTAssertEqual(router.practiceSession, "Northwind Labs case review")
        XCTAssertEqual(router.selectedSession, "Northwind Labs case review", "Sessions keeps its selection for the way back")
    }

    /// Preselect, not start: the meeting, the source and the defaults are chosen, nothing is built or started.
    func testPractiseSelectsTheMeetingWithDefaultSettingsAndBuildsNothing() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("Northwind Labs case review", in: root, bank: 4)
        try makeSession("Harbor Pine intro call", in: root, summary: true, bank: 2)
        let (sim, _, _) = makeSim(root: root)
        let defaults = SimSetup(postingText: "")
        let voice = sim.setup.voice
        XCTAssertTrue(sim.practise(session: "Harbor Pine intro call"), "a past meeting with a pack is a prepared meeting too")
        XCTAssertEqual(sim.setup.source, .meeting)
        XCTAssertEqual(sim.meetingName, "Harbor Pine intro call")
        XCTAssertEqual(sim.meetingPreview?.questions, 2)
        XCTAssertEqual(sim.setup.type, defaults.type)
        XCTAssertEqual(sim.setup.difficulty, defaults.difficulty)
        XCTAssertEqual(sim.setup.lengthMin, defaults.lengthMin)
        XCTAssertEqual(sim.setup.mode, defaults.mode)
        XCTAssertEqual(sim.setup.voice, voice, "the voice stays what Settings chose")
        XCTAssertEqual(sim.phase, .setup, "no build and no start: Build interview is the user's next step")
        XCTAssertNil(sim.sessionDir)
        XCTAssertTrue(sim.canPrepare, "so the page can focus Build interview")
        XCTAssertFalse(sim.canStart)
        XCTAssertEqual(sim.expectedFolderName.map { $0.hasPrefix("sim-") }, true)
    }

    func testPractiseOnAPreparedSessionAfterAnotherInterviewWasBuiltStartsOver() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("Northwind Labs case review", in: root)
        try makeSession("Harbor Pine intro call", in: root, summary: true)
        let (sim, _, _) = makeSim(root: root)
        sim.setPhaseForPreview(.finished)
        XCTAssertTrue(sim.practise(session: "Northwind Labs case review"))
        XCTAssertEqual(sim.phase, .setup, "a finished interview gives way to the one asked for")
        XCTAssertEqual(sim.meetingName, "Northwind Labs case review")
    }

    func testAMissingPackChangesNothing() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("Northwind Labs case review", in: root)
        try makeSession("No pack call", in: root, pack: nil, summary: true)
        let (sim, _, _) = makeSim(root: root)
        XCTAssertTrue(sim.practise(session: "Northwind Labs case review"))
        XCTAssertFalse(sim.practise(session: "No pack call"))
        XCTAssertFalse(sim.practise(session: GeneralPrep.name))
        XCTAssertFalse(sim.practise(session: "sim-20261013-1000-Northwind"))
        XCTAssertEqual(sim.meetingName, "Northwind Labs case review")
    }
}

// MARK: - the running guards

@MainActor
final class SessionPracticeButtonTestsGuards: XCTestCase {
    func testAPracticeThatIsPreparingOrRunningKeepsItsOwnSelection() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("Northwind Labs case review", in: root)
        try makeSession("Harbor Pine intro call", in: root, summary: true)
        let (sim, _, _) = makeSim(root: root)
        XCTAssertTrue(sim.practise(session: "Harbor Pine intro call"))
        for phase in [SimController.Phase.preparing, .running] {
            sim.setPhaseForPreview(phase)
            XCTAssertFalse(sim.practise(session: "Northwind Labs case review"), "\(phase)")
            XCTAssertEqual(sim.meetingName, "Harbor Pine intro call", "\(phase): the running practice keeps its meeting")
            XCTAssertEqual(sim.phase, phase)
            XCTAssertFalse(sim.canPrepare, "\(phase): the page shows its running state and Build interview is off")
        }
    }

    func testARunningMeetingStillSelectsButBuildInterviewIsOff() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = try makeSession("Harbor Pine intro call", in: root, summary: true)
        try makeSession("Northwind Labs case review", in: root)
        let (sim, controller, _) = makeSim(root: root)
        controller.setRunningForPreview(true, session: recording)
        defer { controller.setRunningForPreview(false) }
        XCTAssertTrue(sim.practise(session: "Northwind Labs case review"), "the page opens on the meeting, with its own message")
        XCTAssertEqual(sim.meetingName, "Northwind Labs case review")
        XCTAssertFalse(sim.canPrepare, "the page says \"A meeting is running; stop it first.\" and Build interview is disabled")
        XCTAssertFalse(sim.canStart)
    }

    /// The Practice page takes the request once even when it cannot act on it.
    func testThePageConsumesTheRequestWhileAPracticeRuns() async throws {
        _ = NSApplication.shared
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("Northwind Labs case review", in: root)
        try makeSession("Harbor Pine intro call", in: root, summary: true)
        let (sim, controller, _) = makeSim(root: root)
        XCTAssertTrue(sim.practise(session: "Harbor Pine intro call"))
        sim.setPhaseForPreview(.running)
        let router = HomeRouter()
        router.page = .sessions
        router.showPractice(session: "Northwind Labs case review")

        let view = SimSetupView(sim: sim, meeting: controller, upNext: nil, router: router)
            .environment(\.colorScheme, .light).frame(width: 900, height: 700)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.contentView?.layoutSubtreeIfNeeded()
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<100 where router.practiceSession != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(router.practiceSession, "taken once, not left to fire when the practice ends")
        XCTAssertEqual(sim.meetingName, "Harbor Pine intro call")
        XCTAssertEqual(sim.phase, .running)
    }

    /// A spoken voice without its key: the request still lands, and the page's own rules hold Start back.
    func testAVoiceWithoutItsKeyDoesNotBlockPreselecting() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("Northwind Labs case review", in: root)
        let (sim, _, _) = makeSim(root: root)
        sim.setup.voice = .elevenlabs
        XCTAssertTrue(sim.practise(session: "Northwind Labs case review"))
        XCTAssertEqual(sim.setup.voice, .elevenlabs, "the choice is the user's; the page labels it \"add a key in Settings\"")
        XCTAssertEqual(sim.phase, .setup)
        XCTAssertEqual(sim.canStart, false)
        // Start needs a built interview and an available voice; the same rule the Practice page applies to every entry.
        XCTAssertEqual(SimSettings.isAvailable(.elevenlabs), SimSettings.isAvailable(sim.setup.voice))
    }
}
