import Foundation
import VerseTurns
@testable import VerseUI
import XCTest

/// The start-up panel's "Listening" label follows the raw audio level of the meeting app (not the first transcribed
/// text), and "transcribing" is a separate signal.
@MainActor
final class ListeningLevelTests: XCTestCase {
    private func level(_ remote: Double?, me: Double? = nil) -> RunnerEvent { .level(remoteDbfs: remote, meDbfs: me) }

    private func ready(_ clock: Clock) -> OverlayModel {
        let m = OverlayModel(config: OverlayConfig(), clock: { clock.t })
        m.sessionStarting(lang: "en", session: "mara-northwindlabs", app: "Comet")
        m.apply(status("ready"))
        m.apply(.metric(obj(["type": "metric", "stage": "session_t0", "turn_id": ""])))
        return m
    }

    func testLabelSwitchesOnWithTheFirstLevelAboveSilenceAndBeforeAnyText() {
        let c = Clock()
        let m = ready(c)
        XCTAssertEqual(m.state.startup?.title, "Ready · mara-northwindlabs")
        m.apply(level(nil)); c.t += 0.1
        m.apply(level(-70)); c.t += 0.1
        XCTAssertEqual(m.state.startup?.phase, .ready, "digital silence and a quiet room do not count")
        m.apply(level(-32))
        XCTAssertEqual(m.state.startup?.phase, .listening)
        XCTAssertEqual(m.state.startup?.title, "Listening · mara-northwindlabs")
        XCTAssertEqual(m.state.startup?.transcribing, false, "no text yet")
        XCTAssertEqual(m.state.startup?.subtitle, "hearing Comet")
    }

    func testTranscribingIsItsOwnSignalThatFollowsTheText() {
        let c = Clock()
        let m = ready(c)
        m.apply(level(-30))
        m.apply(.outbound(obj(["type": "partial", "turn_id": "r1", "speaker": "remote", "text": "hello", "cue": false, "t_audio_end": 1.0, "dir": "to_brain"])))
        XCTAssertEqual(m.state.startup?.phase, .listening)
        XCTAssertEqual(m.state.startup?.transcribing, true)
        XCTAssertEqual(m.state.startup?.subtitle, "hearing Comet · transcribing")
    }

    func testMyOwnLevelNeverSwitchesTheLabel() {
        let c = Clock()
        let m = ready(c)
        m.apply(level(nil, me: -20))
        XCTAssertEqual(m.state.startup?.phase, .ready, "the microphone is me, not the meeting")
    }

    func testLabelGoesBackToReadyAfterTheHoldWithoutSound() {
        let c = Clock()
        let m = ready(c)
        m.apply(level(-30))
        for _ in 0..<20 { c.t += 0.1; m.apply(level(-80)) }   // 2.0 s of silence
        XCTAssertEqual(m.state.startup?.phase, .listening, "a pause between sentences keeps it on")
        c.t += 0.6; m.apply(level(-80))                        // 2.6 s
        XCTAssertEqual(m.state.startup?.phase, .ready)
        XCTAssertEqual(m.state.startup?.transcribing, false)
        c.t += 0.1; m.apply(level(-35))
        XCTAssertEqual(m.state.startup?.phase, .listening, "and it comes back with the next sound")
    }

    func testSoundBeforeTheSessionIsReadyDoesNotCount() {
        let c = Clock()
        let m = OverlayModel(config: OverlayConfig(), clock: { c.t })
        m.sessionStarting(lang: "en", session: "s", app: nil)
        m.apply(level(-20))
        guard case .starting? = m.state.startup?.phase else { return XCTFail("still starting") }
    }

    func testLevelsAfterTheFirstCardChangeNothing() {
        let c = Clock()
        let m = ready(c)
        m.apply(turn("r1", "Can you tell me about yourself?"))
        XCTAssertNil(m.state.startup)
        let before = m.state
        m.apply(level(-20))
        XCTAssertEqual(m.state, before)
    }

    func testThresholdIsConfigurable() {
        let c = Clock()
        var cfg = OverlayConfig()
        cfg.audibleDbfs = -40
        let m = OverlayModel(config: cfg, clock: { c.t })
        m.sessionStarting(lang: "en", session: "s", app: nil)
        m.apply(status("ready"))
        m.apply(.metric(obj(["type": "metric", "stage": "session_t0", "turn_id": ""])))
        m.apply(level(-45))
        XCTAssertEqual(m.state.startup?.phase, .ready)
        m.apply(level(-39))
        XCTAssertEqual(m.state.startup?.phase, .listening)
    }
}
