import Foundation
import XCTest
@testable import VerseMeet

final class RecordingRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(exe: URL, args: [String], cwd: URL)] = []
    private(set) var eventJSON: [String: Any]?
    private(set) var eventFileMode: Int?
    private(set) var eventFile: URL?
    let result: CommandResult

    init(result: CommandResult) { self.result = result }

    func run(executable: URL, arguments: [String], workingDirectory: URL) async throws -> CommandResult {
        lock.withLock {
            calls.append((executable, arguments, workingDirectory))
            if let i = arguments.firstIndex(of: "--from-event") {
                let f = URL(fileURLWithPath: arguments[i + 1])
                eventFile = f
                eventJSON = (try? Data(contentsOf: f)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                eventFileMode = (try? FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? Int) ?? nil
            }
        }
        return result
    }
}

final class CalendarPrepTests: XCTestCase {
    func fixtureBrain() throws -> (brain: URL, python: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verse-f5-\(UUID().uuidString)", isDirectory: true)
        let brain = root.appendingPathComponent("brain", isDirectory: true)
        try FileManager.default.createDirectory(at: brain.appendingPathComponent("verse_brain"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (brain, URL(fileURLWithPath: "/usr/bin/true"))
    }

    let event = MeetingEvent(id: "e1", title: "Halden interview", start: Date(timeIntervalSince1970: 1_800_000_000),
                             end: Date(timeIntervalSince1970: 1_800_002_700),
                             attendees: [Attendee(name: "Ingrid S", email: "ingrid@example.invalid")], notes: "Walk through Lantern",
                             url: URL(string: "https://meet.google.com/abc-defg-hij"), provider: .meet)

    func testMakeSessionRunsPrepFromEventAndReturnsFolder() async throws {
        let (brain, python) = try fixtureBrain()
        let runner = RecordingRunner(result: CommandResult(status: 0, stdout: "session: /tmp/sessions/20261014-abc\nbank entries: 2\n", stderr: ""))
        let prep = CalendarPrep(brainDir: brain, python: python, outRoot: URL(fileURLWithPath: "/tmp/sessions"), runner: runner)
        let session = try await prep.makeSession(for: event, repos: [URL(fileURLWithPath: "/tmp/repo")], lang: "en,it")
        XCTAssertEqual(session.path, "/tmp/sessions/20261014-abc")
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.exe, python)
        XCTAssertEqual(call.cwd, brain)
        XCTAssertEqual(Array(call.args.prefix(3)), ["-m", "verse_brain.prep", "--from-event"])
        XCTAssertTrue(call.args.contains("--fake"), "default is the offline prep")
        XCTAssertFalse(call.args.contains("--budget-usd"))
        XCTAssertEqual(call.args[call.args.firstIndex(of: "--lang")! + 1], "en,it")
        XCTAssertEqual(call.args[call.args.firstIndex(of: "--repo")! + 1], "/tmp/repo")
        XCTAssertEqual(call.args[call.args.firstIndex(of: "--out")! + 1], "/tmp/sessions")
        // The event JSON the brain read: title, provider, attendees; private file, removed afterwards.
        XCTAssertEqual(runner.eventJSON?["title"] as? String, "Halden interview")
        XCTAssertEqual(runner.eventJSON?["provider"] as? String, "meet")
        XCTAssertEqual(runner.eventFileMode, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(runner.eventFile).path))
    }

    func testLiveRunCarriesTheSpendCap() async throws {
        let (brain, python) = try fixtureBrain()
        let runner = RecordingRunner(result: CommandResult(status: 0, stdout: "session: /tmp/s\n", stderr: ""))
        let prep = CalendarPrep(brainDir: brain, python: python, fake: false, runner: runner)
        _ = try await prep.makeSession(for: event)
        let args = try XCTUnwrap(runner.calls.first?.args)
        XCTAssertFalse(args.contains("--fake"))
        XCTAssertEqual(args[args.firstIndex(of: "--budget-usd")! + 1], "0.45")
    }

    func testPrepFailuresAreTyped() async throws {
        let (brain, python) = try fixtureBrain()
        let failing = RecordingRunner(result: CommandResult(status: 1, stdout: "", stderr: "error: no key"))
        do {
            _ = try await CalendarPrep(brainDir: brain, python: python, runner: failing).makeSession(for: event)
            XCTFail("expected prepFailed")
        } catch {
            XCTAssertEqual(error as? CalendarPrepError, .prepFailed(status: 1, stderrTail: "error: no key"))
        }
        let silent = RecordingRunner(result: CommandResult(status: 0, stdout: "hello\n", stderr: ""))
        do {
            _ = try await CalendarPrep(brainDir: brain, python: python, runner: silent).makeSession(for: event)
            XCTFail("expected noSessionInOutput")
        } catch {
            XCTAssertEqual(error as? CalendarPrepError, .noSessionInOutput)
        }
        do {
            _ = try await CalendarPrep(brainDir: brain, python: URL(fileURLWithPath: "/nonexistent/python"), runner: silent).makeSession(for: event)
            XCTFail("expected pythonMissing")
        } catch {
            XCTAssertEqual(error as? CalendarPrepError, .pythonMissing("/nonexistent/python"))
        }
        do {
            _ = try await CalendarPrep(brainDir: URL(fileURLWithPath: "/nonexistent/brain"), python: python, runner: silent).makeSession(for: event)
            XCTFail("expected brainDirNotFound")
        } catch {
            XCTAssertEqual(error as? CalendarPrepError, .brainDirNotFound("/nonexistent/brain"))
        }
    }

    /// Real process, real brain code, offline `--fake`. Runs only when VERSE_BRAIN_PYTHON points at an interpreter
    /// that has the brain's dependencies (a worktree has no .venv of its own).
    func testRealOfflinePrepBuildsSessionFolder() async throws {
        guard let py = ProcessInfo.processInfo.environment["VERSE_BRAIN_PYTHON"], !py.isEmpty else {
            throw XCTSkip("set VERSE_BRAIN_PYTHON to run the real offline prep")
        }
        let brain = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("brain")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("verse-f5-sessions-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        let prep = CalendarPrep(brainDir: brain, python: URL(fileURLWithPath: py), outRoot: out)
        let session = try await prep.makeSession(for: event)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.appendingPathComponent("pack.md").path))
        let pack = try String(contentsOf: session.appendingPathComponent("pack.md"), encoding: .utf8)
        XCTAssertTrue(pack.contains("Walk through Lantern"))
        print("real offline prep: session folder has pack.md (\(pack.count) chars)")
    }
}
