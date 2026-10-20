import Foundation
@testable import VerseUI
import XCTest

/// Renders show fixtures, never the user's own data. `HomeRender.Fixtures` builds every model over a temporary folder; this pins
/// that nothing it exposes comes from `~/Library/Application Support/Verse/sessions`, the spend ledger, the event map, the
/// reports folder or the real profile.
@MainActor
final class HomeRenderPrivacyTests: XCTestCase {
    func testEveryFixtureModelReadsOnlyTheTemporaryFolder() throws {
        let fixtures = try HomeRender.Fixtures()
        defer { fixtures.cleanUp() }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        func inTemp(_ url: URL?, _ what: String) {
            let path = url?.resolvingSymlinksInPath().path ?? ""
            XCTAssertTrue(path.hasPrefix(temp), "\(what) must be under the temporary folder, got \(path)")
            XCTAssertFalse(path.contains("Application Support/Verse"), "\(what) reads the user's own folder")
        }
        inTemp(fixtures.controller.sessionsRoot, "the controller's sessions root")
        inTemp(fixtures.sim.sessionsRoot, "Practice's sessions root")
        inTemp(fixtures.controller.eventSessions.url, "the event map")
        inTemp(fixtures.sim.lastReport, "the last practice report")
        inTemp(fixtures.profileDir, "the Me profile")
        XCTAssertEqual(fixtures.controller.monthSpend, 12.30, "Settings → Spend shows a fixture figure, not the ledger")
        XCTAssertEqual(fixtures.controller.sessionSpend, 0.84)
    }

    func testNoRealSessionNameReachesAnyPage() throws {
        let fixtures = try HomeRender.Fixtures()
        defer { fixtures.cleanUp() }
        let real = Set(SessionCatalog.list(root: SessionCatalog.root))
        let shown = Set(fixtures.sessions.sessions.map(\.name))
            .union(fixtures.controller.sessions)
            .union(fixtures.sim.meetings.map(\.name))
        XCTAssertEqual(real.intersection(shown), [], "a session of the user's own is on a rendered page")
        XCTAssertTrue(shown.contains(fixtures.selectedSession) || shown.contains("mara-northwindlabs"), "the fixture sessions are there")
    }
}
