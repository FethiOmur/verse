import Foundation
@testable import VerseUI
import XCTest

/// Follow-ups of 2026-11-11: dot folders are not sessions; SimPrep honours a cancel that came before the start.
/// Nothing here touches the real Keychain, the network or `/Applications/Verse.app`.
final class FollowUpFixTests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("verse-followup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSessionListSkipsDotFoldersEvenWithAPack() throws {
        let root = try tempDir()
        for name in ["normal-session", ".x.tmp"] {
            let d = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try "# pack\n".write(to: d.appendingPathComponent("pack.md"), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(SessionCatalog.list(root: root), ["normal-session"])
    }

    func testSimPrepCancelBeforeRunStartsNothing() async throws {
        let dir = try tempDir()
        let marker = dir.appendingPathComponent("started")
        let bin = dir.appendingPathComponent(".venv/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let py = bin.appendingPathComponent("python")
        try "#!/bin/sh\ntouch '\(marker.path)'\necho x\n".write(to: py, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: py.path)
        let prep = SimPrep()
        prep.cancel()
        let outcome = await prep.run(SimSetup(postingText: "a job posting"), brainDir: dir, root: dir.appendingPathComponent("sessions"), onLine: { _ in })
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "a cancel that came first must stop the process from starting")
    }
}
