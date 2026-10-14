import CoreAudio
import Foundation
import os
import VerseAudio
import XCTest

/// Live Core Audio checks without Alex: a child `verse-listen --emit-test-tone` (bundle ID dev.verse.listen)
/// plays a quiet tone generated in memory, and the tap is created with `muteBehavior = .muted`, so nothing is
/// heard on the speakers or AirPods. Both routes are started BEFORE the child exists, which is the case the
/// bundle-ID route (process restore) and the PID route's process-list refresh exist for.
final class ProcessTapTests: XCTestCase {

    final class Meter: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        private var ss = 0.0
        private var n = 0
        private var chunks = 0
        func add(_ c: AudioChunk) {
            var s = 0.0
            for v in c.samples { s += Double(v * v) }
            lock.withLockUnchecked { ss += s; n += c.samples.count; chunks += 1 }
        }
        /// RMS dBFS since the last call, and the chunk count.
        func take() -> (db: Double?, chunks: Int) {
            lock.withLockUnchecked {
                defer { ss = 0; n = 0; chunks = 0 }
                return (n > 0 && ss > 0 ? 20 * log10((ss / Double(n)).squareRoot()) : nil, chunks)
            }
        }
    }

    static func listenBinary() throws -> URL {
        let products = Bundle(for: ProcessTapTests.self).bundleURL.deletingLastPathComponent()
        let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [products.appendingPathComponent("verse-listen"),
                          packageDir.appendingPathComponent(".build/debug/verse-listen")]
        guard let u = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw XCTSkip("verse-listen binary not found next to the test bundle")
        }
        return u
    }

    func runLateProcess(route: TapRoutePreference) async throws -> (silentBefore: Double?, during: Double?, chunks: Int, routeDescription: String) {
        let tap = ProcessTapSource(bundleIDs: ["dev.verse.listen"], preference: route, muteBehavior: .muted)
        let meter = Meter()
        try tap.start(clock: SessionClock(), onChunk: { meter.add($0) }, onEnd: {})
        defer { tap.stop() }
        try await Task.sleep(for: .milliseconds(800))
        let before = meter.take()

        let child = Process()
        child.executableURL = try Self.listenBinary()
        child.arguments = ["--emit-test-tone", "3"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            // Never block on a stuck child: SIGTERM, then SIGKILL after 2 s.
            if child.isRunning { child.terminate() }
            let deadline = Date().addingTimeInterval(2)
            while child.isRunning && Date() < deadline { usleep(20_000) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
        }
        try await Task.sleep(for: .milliseconds(1200))   // tone engine start + process-list refresh
        _ = meter.take()
        try await Task.sleep(for: .milliseconds(1000))
        let during = meter.take()
        print("[tap \(route.rawValue)] before child: \(before.chunks) chunks; refresh log: \(tap.refreshLog)")
        return (before.db, during.db, during.chunks, tap.routeDescription)
    }

    func testBundleIDTapFollowsLateProcess() async throws {
        let r = try await runLateProcess(route: .bundleID)
        print("[testBundleIDTapFollowsLateProcess] route: \(r.routeDescription); before child: \(r.silentBefore.map { String(format: "%.1f dBFS", $0) } ?? "exact silence"); during tone: \(r.during.map { String(format: "%.1f dBFS", $0) } ?? "exact silence") over \(r.chunks) chunks")
        XCTAssertGreaterThan(r.chunks, 50, "tap delivered almost no callbacks")
        XCTAssertNil(r.silentBefore, "tap was not silent before the child started")
        let db = try XCTUnwrap(r.during, "bundle-ID tap did not pick up a process that started after the tap")
        XCTAssertGreaterThan(db, -65)
    }

    func testPIDListTapFollowsLateProcess() async throws {
        let r = try await runLateProcess(route: .pidList)
        print("[testPIDListTapFollowsLateProcess] route: \(r.routeDescription); during tone: \(r.during.map { String(format: "%.1f dBFS", $0) } ?? "exact silence") over \(r.chunks) chunks")
        XCTAssertGreaterThan(r.chunks, 50, "tap delivered almost no callbacks")
        let db = try XCTUnwrap(r.during, "PID-list tap did not pick up the new process after the process-list refresh")
        XCTAssertGreaterThan(db, -65)
    }

    func testBundleMatching() {
        let t = defaultRemoteBundleIDs
        XCTAssertTrue(AudioProcesses.matches("com.brave.Browser.helper", targets: t))
        XCTAssertTrue(AudioProcesses.matches("com.brave.Browser.helper.renderer", targets: t))
        XCTAssertTrue(AudioProcesses.matches("us.zoom.xos", targets: t))
        XCTAssertFalse(AudioProcesses.matches("com.brave.BrowserX", targets: t))
        XCTAssertFalse(AudioProcesses.matches(nil, targets: t))
        XCTAssertFalse(AudioProcesses.matches("com.apple.Music", targets: t))
    }
}
