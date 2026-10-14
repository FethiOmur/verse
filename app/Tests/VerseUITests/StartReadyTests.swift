import Foundation
import VerseTurns
@testable import VerseUI
import XCTest

/// Start reliability and the start-up panel (2026-10-14 fix).
@MainActor
final class StartReadyTests: XCTestCase {
    private func settings() -> AppSettings {
        let suite = "verse.tests.\(UUID().uuidString)"
        return AppSettings(defaults: UserDefaults(suiteName: suite)!)
    }

    /// Root cause: the app left `RunOptions.seconds` nil, so a live run fell back to the runner's 60 s CLI default
    /// and ended itself one minute after listening started.
    func testLiveRunHasNoOneMinuteLimit() {
        let dir = URL(fileURLWithPath: "/tmp/verse-session")
        let live = VerseController.runOptions(sessionDir: dir, settings: settings(), fakeBrain: true, testFile: nil)
        XCTAssertNil(live.file)
        XCTAssertNotNil(live.seconds, "a live run must not fall back to RunOptions.defaultLiveSeconds")
        XCTAssertGreaterThanOrEqual(live.seconds ?? 0, 4 * 3600)

        let file = VerseController.runOptions(sessionDir: dir, settings: settings(), fakeBrain: true, testFile: "/tmp/q.wav")
        XCTAssertNil(file.seconds, "a test file plays to its end")
        XCTAssertEqual(file.file?.path, "/tmp/q.wav")
    }

    func testStartupPanelStartingReadyListening() {
        let m = OverlayModel()
        m.sessionStarting(lang: "en", session: "mara-northwindlabs", app: "Comet")
        guard case .starting? = m.state.startup?.phase else { return XCTFail("starting expected") }
        XCTAssertEqual(m.state.startup?.title, "Starting…")
        m.apply(status("ready"))
        guard case .starting(let step)? = m.state.startup?.phase else { return XCTFail("still starting until listening") }
        XCTAssertTrue(step.contains("speech"))
        m.apply(.metric(obj(["type": "metric", "stage": "session_t0", "turn_id": ""])))
        XCTAssertEqual(m.state.startup?.phase, .ready)
        XCTAssertEqual(m.state.startup?.title, "Ready · mara-northwindlabs")
        XCTAssertEqual(m.state.startup?.subtitle, "listening to Comet")
        // My own speech does not count as the meeting's audio.
        m.apply(.outbound(obj(["type": "partial", "turn_id": "m1", "speaker": "me", "text": "hi", "cue": false, "t_audio_end": 1.0, "dir": "to_brain"])))
        XCTAssertEqual(m.state.startup?.phase, .ready)
        m.apply(.outbound(obj(["type": "partial", "turn_id": "r1", "speaker": "remote", "text": "hello", "cue": false, "t_audio_end": 1.0, "dir": "to_brain"])))
        XCTAssertEqual(m.state.startup?.phase, .listening)
        XCTAssertEqual(m.state.startup?.title, "Listening · mara-northwindlabs")
        // It stays with time passing.
        m.tick()
        XCTAssertNotNil(m.state.startup)
        // The first card replaces it.
        m.apply(turn("r1", "Can you tell me about yourself?"))
        XCTAssertNotNil(m.state.card)
        XCTAssertNil(m.state.startup)
    }

    func testCapsuleClickCollapsesPanelThenCard() {
        let m = OverlayModel()
        m.sessionStarting(lang: "en", session: "s", app: nil)
        m.collapse()
        XCTAssertNil(m.state.startup)
        m.apply(turn("r1", "Can you tell me about yourself?"))
        XCTAssertNotNil(m.state.card)
        m.collapse()
        XCTAssertNil(m.state.card)
    }

    func testCardStaysOpenByDefault() {
        let c = Clock()
        let m = OverlayModel(config: OverlayConfig(), clock: { c.t })
        m.sessionStarting(lang: "en")
        m.apply(turn("r1", "Can you tell me about yourself?"))
        c.t += 3600
        m.tick()
        XCTAssertNotNil(m.state.card, "default: the card never times out")
        m.apply(turn("r2", "And what about pricing?"))
        XCTAssertEqual(m.state.card?.turnID, "r2", "the next card replaces it")
    }

    func testSettingsDefaultNeverAndOptionalTimeout() {
        let s = settings()
        XCTAssertEqual(s.cardTimeout, 0)
        XCTAssertEqual(s.overlayConfig.cardTimeout, .infinity)
        s.cardTimeout = 60
        XCTAssertEqual(s.overlayConfig.cardTimeout, 60)
    }

    func testFailedRunShowsErrorAndClearsStartup() {
        let m = OverlayModel()
        m.sessionStarting(lang: "en", session: "s", app: nil)
        m.apply(.ended(exitCode: 1))
        XCTAssertNil(m.state.startup)
        XCTAssertEqual(m.state.status?.needsPanel, true)
    }

    func testFileLogRotatesAndScrubsKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verse-log-\(UUID().uuidString)")
        let log = FileLog(url: dir.appendingPathComponent("verse.log"), maxBytes: 200)
        log.write("key sk-ant-api03-ABCdef_123 should not appear")
        let text = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertFalse(text.contains("ABCdef_123"))
        for i in 0..<20 { log.write("line \(i) ................................") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.url.appendingPathExtension("1").path))
        let size = try FileManager.default.attributesOfItem(atPath: log.url.path)[.size] as? UInt64 ?? 0
        XCTAssertLessThan(size, 400)
    }
}
