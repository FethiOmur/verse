import XCTest
@testable import VerseUI

/// The in-app Stop controls (island and home sidebar): the same rule as the menu item.
@MainActor
final class SessionStopTests: XCTestCase {
    private func runningModel() -> OverlayModel {
        let m = OverlayModel()
        var s = OverlayState()
        s.running = true
        m.show(s)
        return m
    }

    func testStopCallsTheControllerStopExactlyOnceAndIsDisabledWhileStopping() {
        let m = runningModel()
        var calls = 0
        m.stopActions = { calls += 1 }
        XCTAssertTrue(m.canStop)
        m.stopSession()
        XCTAssertEqual(calls, 1)
        // The controller flips `stopping` as soon as stop() starts; a second click does nothing.
        m.setStopping(true)
        XCTAssertFalse(m.canStop)
        m.stopSession()
        m.stopSession()
        XCTAssertEqual(calls, 1)
        // The run ended: no session, no Stop.
        m.setStopping(false)
        m.show(OverlayState())
        XCTAssertFalse(m.canStop)
        m.stopSession()
        XCTAssertEqual(calls, 1)
    }

    func testControllerMirrorsStoppingIntoTheOverlayAndWiresStop() {
        let suite = "dev.example.verse.test-stop-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let c = VerseController(settings: AppSettings(defaults: defaults))
        XCTAssertNotNil(c.overlay.stopActions, "the island's Stop is wired to the controller")
        XCTAssertFalse(c.overlay.stopping)
        // Not running: the wired action is a no-op, and the island offers no Stop.
        XCTAssertFalse(c.overlay.canStop)
    }

    func testRulesAndLabels() {
        XCTAssertTrue(SessionStop.canStop(running: true, stopping: false))
        XCTAssertFalse(SessionStop.canStop(running: true, stopping: true))
        XCTAssertFalse(SessionStop.canStop(running: false, stopping: false))
        XCTAssertEqual(SessionStop.title(stopping: false), "Stop")
        XCTAssertEqual(SessionStop.title(stopping: true), "Stopping…")
        XCTAssertEqual(SessionStop.accessibilityLabel(stopping: false), "Stop session")
    }
}
