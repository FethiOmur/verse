import AppKit
import Foundation
import SwiftUI
import VerseTurns
@testable import VerseUI
import VerseVoice
import XCTest

private var brainDir: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("brain")
}

private func tempRoot() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("verse-sim-ui-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

final class SimSessionFolderTests: XCTestCase {
    func testSlugAndName() {
        XCTAssertEqual(SimSessionFolder.slug("Northwind Labs"), "northwind-labs")
        XCTAssertEqual(SimSessionFolder.slug("  Café Ünïcode & Co. "), "cafe-unicode-co")
        XCTAssertEqual(SimSessionFolder.slug("!!!"), "company")
        XCTAssertEqual(SimSessionFolder.slug(""), "company")
        let long = SimSessionFolder.slug("The Extremely Long Company Name Incorporated Holdings International")
        XCTAssertLessThanOrEqual(long.count, 40)
        XCTAssertFalse(long.hasSuffix("-"))
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 10, 15, 9, 30)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let d = cal.date(from: c)!
        XCTAssertEqual(SimSessionFolder.name(company: "Brightwave", date: d, timeZone: TimeZone(identifier: "UTC")!), "sim-20261015-0930-brightwave")
    }

    /// The app's slug must be prep's: the same names through `verse_brain.prep.sim.slugify`.
    func testSlugMatchesPrep() throws {
        let python = brainDir.appendingPathComponent(".venv/bin/python")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path), "brain/.venv missing")
        let names = ["Northwind Labs", "  Café Ünïcode & Co. ", "!!!", "Harbor Tech S.p.A.", "Brightwave", "a—b–c", "日本語 Corp",
                     "The Extremely Long Company Name Incorporated Holdings International"]
        let p = Process()
        p.executableURL = python
        p.currentDirectoryURL = brainDir
        p.arguments = ["-c", "import json,sys; from verse_brain.prep.sim import slugify; print(json.dumps([slugify(n) for n in json.load(sys.stdin)]))"]
        let inp = Pipe(), out = Pipe()
        p.standardInput = inp
        p.standardOutput = out
        try p.run()
        inp.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: names))
        try inp.fileHandleForWriting.close()
        p.waitUntilExit()
        let py = try JSONSerialization.jsonObject(with: out.fileHandleForReading.readDataToEndOfFile()) as? [String]
        XCTAssertEqual(names.map(SimSessionFolder.slug), py)
    }

    func testValidatedOnlyAcceptsSimFoldersUnderRoot() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ok = root.appendingPathComponent("sim-20261015-0930-acme")
        try FileManager.default.createDirectory(at: ok, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: ok.appendingPathComponent("sim.json"))
        XCTAssertEqual(SimSessionFolder.validated(ok.path + "\n", root: root)?.lastPathComponent, ok.lastPathComponent)
        let noPack = root.appendingPathComponent("sim-20261015-0931-acme")
        try FileManager.default.createDirectory(at: noPack, withIntermediateDirectories: true)
        XCTAssertNil(SimSessionFolder.validated(noPack.path, root: root), "no sim.json")
        XCTAssertNil(SimSessionFolder.validated("/etc", root: root))
        XCTAssertNil(SimSessionFolder.validated("", root: root))
    }

    func testPrepArguments() {
        var s = SimSetup(postingText: "x", postingURL: URL(string: "https://jobs.ashbyhq.com/acme/1"))
        s.cv = URL(fileURLWithPath: "/tmp/cv.pdf")
        s.repos = ["/tmp/repo"]
        s.company = "Acme"
        s.type = .technical
        s.difficulty = .tough
        s.lengthMin = 15
        s.fake = true
        let a = s.prepArguments(postingFile: URL(fileURLWithPath: "/tmp/p/posting.txt"), noteFile: nil, out: URL(fileURLWithPath: "/tmp/root"))
        XCTAssertEqual(Array(a.prefix(4)), ["-u", "-m", "verse_brain.prep", "--sim"])
        func value(_ flag: String) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }
        XCTAssertEqual(value("--posting-file"), "/tmp/p/posting.txt")
        XCTAssertEqual(value("--out"), "/tmp/root")
        XCTAssertEqual(value("--type"), "technical")
        XCTAssertEqual(value("--difficulty"), "tough")
        XCTAssertEqual(value("--length"), "15")
        XCTAssertEqual(value("--posting-url"), "https://jobs.ashbyhq.com/acme/1")
        XCTAssertEqual(value("--cv"), "/tmp/cv.pdf")
        XCTAssertEqual(value("--repo"), "/tmp/repo")
        XCTAssertEqual(value("--company"), "Acme")
        XCTAssertTrue(a.contains("--no-vault"))
        XCTAssertTrue(a.contains("--fake"))
        XCTAssertNil(value("--note"))
    }

    /// S1 prep through the app's runner, offline (`--fake`): the session folder appears under the root with the
    /// confirmed posting, and the private temp copy is gone.
    func testFakePrepCreatesSessionFolder() async throws {
        let python = brainDir.appendingPathComponent(".venv/bin/python")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path), "brain/.venv missing")
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let posting = try String(contentsOf: brainDir.appendingPathComponent("tests/fixtures/sim_runtime/session/posting.txt"), encoding: .utf8)
        var s = SimSetup(postingText: posting)
        s.fake = true
        s.note = "I led Lantern."
        s.lengthMin = 15
        let lines = LineSink()
        let outcome = await SimPrep().run(s, brainDir: brainDir, root: root, onLine: { lines.add($0) })
        guard case .done(let dir) = outcome else { return XCTFail("prep: \(outcome) \(lines.all)") }
        XCTAssertEqual(dir.deletingLastPathComponent().resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path)
        XCTAssertTrue(dir.lastPathComponent.hasPrefix("sim-"))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("posting.txt"), encoding: .utf8), posting)
        let summary = try XCTUnwrap(SimPackSummary.load(sessionDir: dir))
        XCTAssertEqual(summary.questions, 5)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("verse-sim-prep-") }
        XCTAssertEqual(leftovers, [], "the temp posting copy is removed")
    }
}

final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ l: String) { lock.withLock { lines.append(l) } }
    var all: [String] { lock.withLock { lines } }
}

@MainActor
final class SimOverlayTests: XCTestCase {
    private func model(voice: String = "apple", caption: Bool = true) -> OverlayModel {
        let m = OverlayModel()
        m.simStarting(voice: voice, showCaption: caption)
        return m
    }

    func testCapsuleShowsProgress() {
        let m = model()
        XCTAssertEqual(m.state.capsuleTag, "practice")
        XCTAssertTrue(m.state.running)
        m.simApply(.progress(index: 3, total: 8))
        XCTAssertEqual(m.state.capsuleTag, "practice · Q3/8")
    }

    func testLineAssembledByIDAndCaptionToggle() {
        let m = model(voice: "openai", caption: false)
        m.simApply(.say(lineID: "s7", text: "Thanks.", final: false))
        m.simApply(.say(lineID: "s7", text: "Tell me about Lantern.", final: true))
        XCTAssertEqual(m.state.sim?.line, "Thanks. Tell me about Lantern.")
        XCTAssertEqual(m.state.sim?.showsLine, false, "voice mode without caption")
        m.simAction(.toggleCaption)
        XCTAssertEqual(m.state.sim?.showsLine, true)
        m.simApply(.say(lineID: "s11", text: "Why us?", final: true))
        XCTAssertEqual(m.state.sim?.line, "Why us?", "a new id replaces the line")
    }

    func testTextModeAlwaysShowsLine() {
        let m = model(voice: "text", caption: false)
        m.simApply(.say(lineID: "s1", text: "Hello.", final: true))
        XCTAssertEqual(m.state.sim?.showsLine, true)
    }

    func testAIDisclosureOnlyWhileACloudVoiceSpeaks() {
        for (voice, expected) in [("elevenlabs", true), ("openai", true), ("apple", false), ("text", false)] {
            let m = model(voice: voice)
            m.simApply(.say(lineID: "s1", text: "Hi.", final: true))
            XCTAssertEqual(m.state.sim?.showsAIDisclosure, false, "\(voice) before playback")
            m.simApply(.speaking(lineID: "s1"))
            XCTAssertEqual(m.state.sim?.showsAIDisclosure, expected, voice)
            m.simApply(.speaking(lineID: nil))
            XCTAssertEqual(m.state.sim?.showsAIDisclosure, false, "\(voice) after playback")
        }
    }

    func testListenAnswerCoachAndEnd() {
        let m = model()
        m.simApply(.listening(qID: "q1"))
        XCTAssertEqual(m.state.sim?.listening, true)
        XCTAssertEqual(m.state.activity, .listening)
        m.simApply(.answerText("I led Lantern"))
        XCTAssertEqual(m.state.sim?.answer, "I led Lantern")
        m.simApply(.answerSent(qID: "q1", text: "I led Lantern"))
        XCTAssertEqual(m.state.sim?.listening, false)
        m.simApply(.coach(qID: "q1", lines: ["- Lead with the number."]))
        XCTAssertEqual(m.state.sim?.coach, ["- Lead with the number."])
        XCTAssertEqual(SimPanelView.unbullet("- Lead with the number."), "Lead with the number.")
        m.simApply(.progress(index: 2, total: 8))
        XCTAssertEqual(m.state.sim?.coach, [], "the note goes with its question")
        m.simApply(.ended(code: 0))
        XCTAssertNil(m.state.sim)
        XCTAssertFalse(m.state.running)
        XCTAssertNil(m.state.status)
        XCTAssertEqual(m.state.capsuleTag, "en")
    }

    func testErrorEndHasNoMeetingRetry() {
        let m = model()
        m.simApply(.ended(code: 1))
        XCTAssertEqual(m.state.status, .error("The practice interview ended with an error."))
        XCTAssertTrue(m.state.practiceEnded)
        m.sessionStarting(lang: "en")
        XCTAssertFalse(m.state.practiceEnded, "a meeting start clears it")
    }

    func testMicPermissionDenied() {
        let m = model()
        m.simApply(.status(state: "permission_denied", message: "microphone"))
        XCTAssertEqual(m.state.status, .permission("microphone"))
    }

    func testVoiceAvailability() {
        XCTAssertTrue(SimSettings.isAvailable(.apple, hasKey: { _ in false }))
        XCTAssertTrue(SimSettings.isAvailable(.text, hasKey: { _ in false }))
        XCTAssertFalse(SimSettings.isAvailable(.openai, hasKey: { _ in false }))
        XCTAssertTrue(SimSettings.isAvailable(.elevenlabs, hasKey: { $0 == .elevenlabs }))
    }

    /// Opt-in render of the sim panel for review: `VERSE_RENDER_SIM=<dir> swift test --filter testRenderSimPanel`.
    func testRenderSimPanel() async throws {
        guard let dir = ProcessInfo.processInfo.environment["VERSE_RENDER_SIM"], !dir.isEmpty else {
            throw XCTSkip("set VERSE_RENDER_SIM to render")
        }
        var base = OverlayState()
        base.running = true
        base.activity = .listening
        var voice = SimOverlay(startedAt: Date().addingTimeInterval(-372), voice: "openai", showCaption: true)
        voice.qIndex = 3
        voice.qTotal = 8
        voice.lineID = "s9"
        voice.line = "Tell me about an LLM feature you shipped to real users. How did you know it worked?"
        voice.speaking = true
        var listening = voice
        listening.speaking = false
        listening.listening = true
        listening.answer = "I led Lantern, an invoice extraction pipeline, and we measured it on a 300-invoice golden set"
        var coach = SimOverlay(startedAt: Date().addingTimeInterval(-640), voice: "text", showCaption: false)
        coach.qIndex = 4
        coach.qTotal = 8
        coach.lineID = "s14"
        coach.line = "Why Northwind Labs, and why now?"
        coach.coach = ["- You named the product and the team; good.", "- Say what you would build in the first three months."]
        // ScreenCaptureKit does not capture from the test runner, so this draws the panel and the capsule with
        // ImageRenderer on a dark stand-in for the glass (layout and type, not the glass itself).
        for (name, s) in [("sim-speaking-cloud", voice), ("sim-listening", listening), ("sim-text-coach", coach)] {
            var st = base
            st.sim = s
            let view = VStack(spacing: 0) {
                CapsuleView(state: st, metrics: .macBookPro)
                SimPanelView(sim: s, scale: 1, onAction: { _ in })
            }
            .frame(width: 560)
            .background(Color(red: 0.06, green: 0.06, blue: 0.07))
            .environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: view)
            r.scale = 2
            let image = try XCTUnwrap(r.nsImage)
            let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
            print("[render] \(url.path)")
        }
    }
}
