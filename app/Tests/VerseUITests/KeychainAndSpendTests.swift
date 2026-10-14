import Foundation
import VerseUI
import XCTest

final class KeychainAndSpendTests: XCTestCase {
    /// Save under a TEST service, read it back exactly the way the brain does (`security find-generic-password -a $USER
    /// -s <service> -w`, no prompt: the call has a timeout), remove it. The value is a dummy and is never printed.
    func testKeychainRoundTrip() throws {
        let service = "verse-anthropic-TEST-\(UUID().uuidString.prefix(8))"
        let dummy = "sk-ant-TESTDUMMY-" + String(repeating: "x", count: 24) + "_9f3c"
        defer { try? KeychainStore.remove(service: service) }
        XCTAssertNotEqual(service, KeychainStore.service, "never touch the real item")
        XCTAssertFalse(KeychainStore.hasKey(service: service))

        try KeychainStore.save(dummy, service: service)
        XCTAssertTrue(KeychainStore.hasKey(service: service))
        XCTAssertEqual(KeychainStore.last4(service: service), "9f3c")

        let (status, out) = brainStyleRead(service: service)
        XCTAssertEqual(status, 0, "the brain's read failed or needed a prompt")
        XCTAssertTrue(out == dummy, "the brain's read returned a different value")   // compared, never printed

        // replace
        let dummy2 = "sk-ant-TESTDUMMY-" + String(repeating: "y", count: 24) + "_a1b2"
        try KeychainStore.save(dummy2, service: service)
        XCTAssertEqual(KeychainStore.last4(service: service), "a1b2")
        XCTAssertTrue(brainStyleRead(service: service).out == dummy2)

        try KeychainStore.remove(service: service)
        XCTAssertFalse(KeychainStore.hasKey(service: service))
        XCTAssertNotEqual(brainStyleRead(service: service).status, 0, "gone after remove")
    }

    func testKeychainRejectsOddKeys() {
        let service = "verse-anthropic-TEST-\(UUID().uuidString.prefix(8))"
        defer { try? KeychainStore.remove(service: service) }
        XCTAssertThrowsError(try KeychainStore.save("short", service: service))
        XCTAssertThrowsError(try KeychainStore.save("sk-ant-has spaces and \"quotes\" -w x", service: service))
        XCTAssertFalse(KeychainStore.hasKey(service: service))
    }

    /// `brain/verse_brain/prep/keychain.py`: security find-generic-password -a USER -s SERVICE -w (timeout 30 s; 10 s here).
    private func brainStyleRead(service: String) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-a", KeychainStore.account, "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try? p.run()
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return (-2, "") }   // a prompt would block here
        let d = out.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testSpendLedger() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verse-spend-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let now = Date()
        let start = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded() - 100)
        SpendLedger.record(sessionDir: a, startedAt: start, costUSD: 0.01)
        SpendLedger.record(sessionDir: a, startedAt: start, costUSD: 0.02)   // same run: updated, not added
        SpendLedger.record(sessionDir: b, startedAt: start.addingTimeInterval(10), costUSD: 0.005)
        SpendLedger.record(sessionDir: b, startedAt: Calendar.current.date(byAdding: .month, value: -2, to: now)!, costUSD: 5)
        XCTAssertEqual(SpendLedger.runs(sessionDir: a).count, 1)
        XCTAssertEqual(SpendLedger.thisMonth(root: root, now: now), 0.025, accuracy: 1e-9)
    }
}
