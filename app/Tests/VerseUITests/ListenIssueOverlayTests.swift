import Foundation
import VerseAudio
import VerseTurns
@testable import VerseUI
import XCTest

/// Review H5/H8: a channel whose capture or recognizer died mid-call shows on the overlay; a recovery that works shows a brief
/// "reconnected" notice (there was a gap in the transcript) that goes by itself and gives way to a card.
final class ListenIssueOverlayTests: XCTestCase {
    private func running() -> OverlayReducer {
        var r = OverlayReducer()
        r.apply(.metric(["type": .string("metric"), "stage": .string("session_t0"), "turn_id": .string("")]), now: 0)
        return r
    }

    func testCaptureFailureShowsAndItsRecoveryClearsIt() {
        var r = running()
        r.apply(.issue(code: "capture_failed", message: "audio capture on your microphone channel stopped"), now: 1)
        XCTAssertEqual(r.state.status, .error("audio capture on your microphone channel stopped"))
        r.apply(.issue(code: "capture_recovered", message: "restarted"), now: 2)
        XCTAssertEqual(r.state.status, .reconnected([.audio]), "the failure panel goes; the notice says it came back")
        r.tick(now: 2 + r.config.noticeDuration)
        XCTAssertNil(r.state.status)
    }

    func testSpeechFailureStaysAndRecoveredIssuesOnlyNotify() {
        var r = running()
        r.apply(.issue(code: "speech_recovered", message: "Nemotron failed; Apple took over"), now: 1)
        r.apply(.issue(code: "capture_recovered", message: "restarted"), now: 1)
        XCTAssertEqual(r.state.status, .reconnected([.transcription, .audio]), "two recoveries at once: one notice")
        r.tick(now: 1 + r.config.noticeDuration)
        XCTAssertNil(r.state.status, "a channel that works again needs nothing on screen once the notice went")
        r.apply(.issue(code: "speech_failed", message: "speech recognition on the meeting audio channel failed"), now: 2)
        XCTAssertEqual(r.state.status, .error("speech recognition on the meeting audio channel failed"))
        r.apply(.issue(code: "capture_recovered", message: "restarted"), now: 3)
        XCTAssertEqual(r.state.status, .error("speech recognition on the meeting audio channel failed"),
                       "a capture recovery does not hide a recognizer that is still dead")
    }

    // MARK: per channel (the issue text names the channel: `ListenError.description`)

    private func issue(_ e: ListenError) -> RunnerEvent { .issue(code: e.code, message: e.description) }

    /// The issue's own `channel` field decides the channel; the text is read only when the field is absent. Here the second
    /// failure's text names no channel and the recovery's text names none either: only the field tells them apart.
    func testTheIssuesChannelFieldIsUsedBeforeTheText() {
        var r = running()
        r.apply(.issue(code: "capture_failed", message: "meeting audio stopped", channel: .remote), now: 1)
        r.apply(.issue(code: "capture_failed", message: "input device gone", channel: .me), now: 2)
        r.apply(.issue(code: "capture_recovered", message: "default input device changed", channel: .me), now: 3)
        XCTAssertEqual(shown(r), "meeting audio stopped", "the microphone came back; the meeting audio is still down")
        r.apply(.issue(code: "capture_recovered", message: "restarted", channel: .remote), now: 4)
        XCTAssertEqual(r.state.status, .reconnected([.meetingAudio]))
    }

    /// A field that disagrees with the text wins (the text may quote a reason that names the other channel).
    func testTheFieldWinsOverAChannelNamedInTheText() {
        var r = running()
        r.apply(.issue(code: "capture_failed", message: "stopped after the meeting audio channel changed device", channel: .me), now: 1)
        r.apply(.issue(code: "capture_failed", message: ListenError.captureFailed(.remote, "x").description), now: 2)
        r.apply(.issue(code: "capture_recovered", message: "back", channel: .me), now: 3)
        XCTAssertEqual(shown(r), ListenError.captureFailed(.remote, "x").description, "no field: the text's channel (remote) is used")
    }

    private func shown(_ r: OverlayReducer) -> String? {
        if case .error(let m)? = r.state.status { return m }
        return nil
    }

    /// Both captures down: the meeting channel coming back leaves the microphone's panel up, and the panel names only the
    /// microphone from then on.
    func testOneChannelRecoveringKeepsTheOtherChannelsFailure() {
        var r = running()
        r.apply(issue(.captureFailed(.remote, "output device gone")), now: 1)
        r.apply(issue(.captureFailed(.me, "no input device")), now: 2)
        r.apply(issue(.captureRecovered(.remote, "default output device changed")), now: 3)
        let m = shown(r)
        XCTAssertNotNil(m, "the microphone is still down")
        XCTAssertTrue(m?.contains("your microphone channel") == true, m ?? "")
        XCTAssertFalse(m?.contains("the meeting audio channel") == true, m ?? "")
        r.apply(issue(.captureRecovered(.me, "default input device changed")), now: 4)
        XCTAssertEqual(r.state.status, .reconnected([.microphone]), "every failed channel recovered: only the notice is left")
        r.tick(now: 4 + r.config.noticeDuration)
        XCTAssertNil(r.state.status)
    }

    /// A second failure does not overwrite the first: the panel names both channels.
    func testSecondFailureKeepsTheFirst() {
        var r = running()
        r.apply(issue(.captureFailed(.me, "no input device")), now: 1)
        r.apply(issue(.captureFailed(.remote, "output device gone")), now: 2)
        let m = shown(r) ?? ""
        XCTAssertTrue(m.contains("your microphone channel"), m)
        XCTAssertTrue(m.contains("the meeting audio channel"), m)
        r.apply(issue(.captureRecovered(.me, "default input device changed")), now: 3)
        let after = shown(r) ?? ""
        XCTAssertTrue(after.contains("the meeting audio channel"), after)
        XCTAssertFalse(after.contains("your microphone channel"), after)
    }

    /// A dead recognizer on one channel survives the other channel's capture recovering, and the same channel's capture
    /// recovering too (capture and recognition are tracked apart).
    func testSpeechFailureIsTrackedPerChannelAndApartFromCapture() {
        var r = running()
        r.apply(issue(.speechFailed(.remote, "Nemotron and Apple failed")), now: 1)
        r.apply(issue(.captureFailed(.me, "no input device")), now: 2)
        r.apply(issue(.captureRecovered(.me, "default input device changed")), now: 3)
        XCTAssertEqual(shown(r), ListenError.speechFailed(.remote, "Nemotron and Apple failed").description)
        r.apply(issue(.captureFailed(.remote, "output device gone")), now: 4)
        r.apply(issue(.captureRecovered(.remote, "default output device changed")), now: 5)
        XCTAssertEqual(shown(r), ListenError.speechFailed(.remote, "Nemotron and Apple failed").description,
                       "the meeting channel's capture is back; its recognizer is still dead")
    }

    /// A recovery that names no channel is applied only when it is unambiguous (one capture down).
    func testRecoveryWithoutAChannelDoesNotGuessBetweenTwo() {
        var r = running()
        r.apply(issue(.captureFailed(.me, "no input device")), now: 1)
        r.apply(issue(.captureFailed(.remote, "output device gone")), now: 2)
        r.apply(.issue(code: "capture_recovered", message: "restarted"), now: 3)
        let m = shown(r) ?? ""
        XCTAssertTrue(m.contains("your microphone channel") && m.contains("the meeting audio channel"), m)
    }

    /// The channel is read from the text `ListenError` writes (VerseRunner forwards only code and message).
    func testChannelIsReadFromTheIssueText() {
        XCTAssertEqual(ListenError.channel(inIssueMessage: ListenError.captureFailed(.me, "x").description), .me)
        XCTAssertEqual(ListenError.channel(inIssueMessage: ListenError.speechRecovered(.remote, "x").description), .remote)
        XCTAssertEqual(ListenError.channel(inIssueMessage:
            ListenError.captureFailed(.remote, "mentions your microphone channel later").description), .remote,
            "the first channel named wins")
        XCTAssertNil(ListenError.channel(inIssueMessage: "restarted"))
        XCTAssertEqual(ListenError.captureFailed(.me, "x").channel, .me)
        XCTAssertNil(ListenError.tapFailed("x").channel)
    }

    // MARK: the "reconnected" notice

    /// A recovered microphone or meeting audio says so by name, for `noticeDuration`, then goes by itself.
    func testRecoveredCaptureShowsANoticeThatGoesByItself() {
        var r = running()
        r.apply(issue(.captureRecovered(.me, "default input device changed")), now: 10)
        XCTAssertEqual(r.state.status, .reconnected([.microphone]))
        XCTAssertEqual(r.state.status?.title, "Microphone reconnected")
        XCTAssertEqual(r.state.status?.detail, "A few seconds may be missing from the transcript.")
        XCTAssertEqual(r.state.status?.needsPanel, true)
        r.tick(now: 10 + r.config.noticeDuration - 0.5)
        XCTAssertEqual(r.state.status, .reconnected([.microphone]), "still within its time")
        r.tick(now: 10 + r.config.noticeDuration)
        XCTAssertNil(r.state.status)

        r.apply(issue(.captureRecovered(.remote, "default output device changed")), now: 20)
        XCTAssertEqual(r.state.status?.title, "Meeting audio reconnected")
        r.apply(issue(.captureRecovered(.me, "default input device changed")), now: 21)
        XCTAssertEqual(r.state.status?.title, "Audio reconnected", "AirPods: both channels came back")
        r.tick(now: 20 + r.config.noticeDuration)
        XCTAssertNotNil(r.state.status, "the second recovery started the time again")
        r.tick(now: 21 + r.config.noticeDuration)
        XCTAssertNil(r.state.status)

        r.apply(issue(.speechRecovered(.remote, "Nemotron decode failed")), now: 30)
        XCTAssertEqual(r.state.status?.title, "Transcription restarted")
    }

    /// The notice never hides a real status, and gives way to an answer card like a per-call error (`yieldsToCard`).
    func testNoticeYieldsToCardsAndNeverReplacesARealStatus() {
        var r = running()
        r.apply(.status(state: "offline", message: ""), now: 1)
        r.apply(issue(.captureRecovered(.me, "x")), now: 2)
        XCTAssertEqual(r.state.status, .offline, "No connection stays")

        var c = running()
        c.apply(issue(.captureRecovered(.me, "x")), now: 1)
        c.apply(.outbound(["type": .string("turn"), "turn_id": .string("t1"), "speaker": .string("remote"),
                           "addressee": .string("me"), "kind": .string("question"), "text": .string("What is the budget?")]), now: 2)
        XCTAssertNotNil(c.state.card)
        guard case .card = IslandKind.resolve(c.state, prompterOpen: false) else {
            return XCTFail("the card shows over the notice: \(IslandKind.resolve(c.state, prompterOpen: false))")
        }
        var idle = c.state
        idle.card = nil
        guard case .statusPanel(.reconnected) = IslandKind.resolve(idle, prompterOpen: false) else { return XCTFail("no card: the notice shows") }
    }

    /// Nothing to say outside a call; a session that ends takes the notice with it.
    func testNoticeOnlyInARunningCall() {
        var r = OverlayReducer()
        r.apply(issue(.captureRecovered(.me, "x")), now: 1)
        XCTAssertNil(r.state.status)
        var s = running()
        s.apply(issue(.captureRecovered(.me, "x")), now: 1)
        s.apply(.ended(exitCode: 0), now: 2)
        XCTAssertNil(s.state.status)
    }

    /// The localized strings exist in Italian and Turkish.
    func testNoticeStringsAreLocalized() {
        for key in ["Microphone reconnected", "Meeting audio reconnected", "Audio reconnected", "Transcription restarted",
                    "Reconnected", "Restarted", "A few seconds may be missing from the transcript."] {
            for lang in ["it", "tr"] {
                XCTAssertNotEqual(L10n.tr(String.LocalizationValue(key), locale: Locale(identifier: lang)), key, "\(key) [\(lang)]")
            }
        }
    }
}
