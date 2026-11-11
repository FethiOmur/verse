import Foundation
import VerseAudio
import VerseTurns
@testable import VerseUI
import XCTest

/// Review H5/H8: a channel whose capture or recognizer died mid-call shows on the overlay; a recovery that works shows nothing.
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
        XCTAssertNil(r.state.status)
    }

    func testSpeechFailureStaysAndRecoveredIssuesChangeNothing() {
        var r = running()
        r.apply(.issue(code: "speech_recovered", message: "Nemotron failed; Apple took over"), now: 1)
        r.apply(.issue(code: "capture_recovered", message: "restarted"), now: 1)
        XCTAssertNil(r.state.status, "a channel that works again needs nothing on screen")
        r.apply(.issue(code: "speech_failed", message: "speech recognition on the meeting audio channel failed"), now: 2)
        XCTAssertEqual(r.state.status, .error("speech recognition on the meeting audio channel failed"))
        r.apply(.issue(code: "capture_recovered", message: "restarted"), now: 3)
        XCTAssertEqual(r.state.status, .error("speech recognition on the meeting audio channel failed"),
                       "a capture recovery does not hide a recognizer that is still dead")
    }

    // MARK: per channel (the issue text names the channel: `ListenError.description`)

    private func issue(_ e: ListenError) -> RunnerEvent { .issue(code: e.code, message: e.description) }

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
        XCTAssertNil(r.state.status, "every failed channel recovered")
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
}
