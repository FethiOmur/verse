import Foundation
@testable import VerseUI
import XCTest

/// The month's spend includes the briefs that belong to no session (`memory/spend.json`) and the `brief` kind (memory spec 2.4).
final class SpendLedgerMemoryTests: XCTestCase {
    private var top: URL!

    override func setUpWithError() throws {
        top = FileManager.default.temporaryDirectory.appendingPathComponent("verse-spend-mem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: top) }

    private func dir(_ name: String) throws -> URL {
        let u = top.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func testARunInTheMemoryFolderCountsThisMonthAndLastMonthsDoesNot() throws {
        let sessions = try dir("sessions"), memory = try dir("memory"), s1 = try dir("sessions/halden-kickoff")
        let now = Date()
        let cal = Calendar.current
        SpendLedger.record(sessionDir: s1, startedAt: now.addingTimeInterval(-100), costUSD: 0.20)
        SpendLedger.record(sessionDir: memory, startedAt: now.addingTimeInterval(-50), costUSD: 0.05, kind: "brief")
        SpendLedger.record(sessionDir: memory, startedAt: cal.date(byAdding: .month, value: -2, to: now)!, costUSD: 7, kind: "brief")

        XCTAssertEqual(SpendLedger.thisMonth(root: sessions, now: now, calendar: cal, extraDirs: [memory]), 0.25, accuracy: 1e-9)
        XCTAssertEqual(SpendLedger.thisMonth(root: sessions, now: now, calendar: cal, extraDirs: []), 0.20, accuracy: 1e-9, "without the folder it is the sessions only")
    }

    func testAScratchRootNeverReadsTheRealMemoryFolder() throws {
        let sessions = try dir("sessions")
        XCTAssertEqual(SpendLedger.thisMonth(root: sessions, now: Date()), 0, accuracy: 1e-9)
    }

    func testBriefRunsKeepTheirKindAndStayApartFromCallRuns() throws {
        let s = try dir("sessions/halden-weekly-prep")
        let start = Date(timeIntervalSince1970: 1_792_400_000)
        SpendLedger.record(sessionDir: s, startedAt: start, costUSD: 0.30)
        SpendLedger.record(sessionDir: s, startedAt: start, costUSD: 0.048, kind: "brief")
        let runs = SpendLedger.runs(sessionDir: s)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.first { $0.kind == "brief" }?.costUSD ?? 0, 0.048, accuracy: 1e-9)
        XCTAssertEqual(HomeSession.load(name: "halden-weekly-prep", root: s.deletingLastPathComponent()).spend, 0.348, accuracy: 1e-9,
                       "the session row's spend includes the brief")
    }
}
