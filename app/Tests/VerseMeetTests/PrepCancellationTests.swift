import Foundation
import XCTest
@testable import VerseMeet

/// S2: cancelling the task that runs the prep stops the child process. Stand-ins only (`/bin/sleep`, `/bin/sh`): the
/// real Python prep never runs here.
final class PrepCancellationTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("verse-prepcancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    /// Cancels `task` after `delay` and returns how long it took to finish, and its error.
    private func cancelAndTime(_ task: Task<CommandResult, any Error>, after delay: Double) async -> (Double, (any Error)?) {
        try? await Task.sleep(for: .seconds(delay))
        let t = Date()
        task.cancel()
        do { _ = try await task.value; return (Date().timeIntervalSince(t), nil) } catch { return (Date().timeIntervalSince(t), error) }
    }

    func testCancellingStopsTheChildAtOnce() async throws {
        let runner = ProcessCommandRunner()
        let task = Task {
            try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                                 workingDirectory: URL(fileURLWithPath: "/"))
        }
        let (took, error) = await cancelAndTime(task, after: 0.5)
        XCTAssertLessThan(took, 3, "SIGINT ends a plain child right away (it used to run its full 30 s)")
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
    }

    func testAChildThatIgnoresSIGINTIsTerminatedAfterTheGrace() async throws {
        let dir = try tempDir()
        let pidFile = dir.appendingPathComponent("pid")
        let runner = ProcessCommandRunner(graceSeconds: 0.5)
        // The shell ignores SIGINT and execs into sleep, which keeps the ignored disposition.
        let task = Task {
            try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                 arguments: ["-c", "trap '' INT; echo $$ > '\(pidFile.path)'; exec /bin/sleep 30"],
                                 workingDirectory: dir)
        }
        let (took, error) = await cancelAndTime(task, after: 0.7)
        XCTAssertLessThan(took, 5, "SIGTERM after the grace")
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
        let pid = pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertGreaterThan(pid, 0)
        XCTAssertFalse(isAlive(pid), "the child is gone")
    }

    func testCancelledBeforeTheChildStartsNothingRuns() async throws {
        let dir = try tempDir()
        let marker = dir.appendingPathComponent("ran")
        let runner = ProcessCommandRunner()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path],
                                        workingDirectory: dir)
        }
        do { _ = try await task.value; XCTFail("expected a cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// The whole path the app uses: `CalendarPrep.makeSession` with a stand-in "python" that would run for 30 s.
    func testCancellingMakeSessionStopsThePrepProcess() async throws {
        let brain = try tempDir()
        try FileManager.default.createDirectory(at: brain.appendingPathComponent("verse_brain"), withIntermediateDirectories: true)
        let pidFile = brain.appendingPathComponent("pid")
        let python = brain.appendingPathComponent("fake-python")
        try "#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec /bin/sleep 30\n".write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        let prep = CalendarPrep.live(brainDir: brain, python: python, outRoot: brain.appendingPathComponent("out"))
        let event = MeetingEvent(id: "e1", title: "Quarterly review", start: Date(), end: Date().addingTimeInterval(1800))

        let task = Task { try await prep.makeSession(for: event) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) { try await Task.sleep(for: .milliseconds(20)) }
        let pid = pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertTrue(isAlive(pid))
        let t = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("expected a cancellation") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(t), 3)
        XCTAssertFalse(isAlive(pid), "the prep process was stopped")
    }

    func testANormalRunStillReturnsItsOutput() async throws {
        let r = try await ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["session: /x"],
                                                     workingDirectory: URL(fileURLWithPath: "/"))
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.stdout, "session: /x\n")
    }
}
