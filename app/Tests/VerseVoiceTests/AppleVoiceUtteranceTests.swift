import AVFoundation
import Foundation
import XCTest
@testable import VerseVoice

/// U2: each `speak` waits for its own utterance. A late `didCancel` for the line that was cut off (Skip, Repeat) must
/// not end the wait for the next line.
@MainActor
final class AppleVoiceUtteranceTests: XCTestCase {
    /// Behaves like `AVSpeechSynthesizer` for the runner: `stopSpeaking` reports `didCancel` for the cut-off utterance a
    /// moment later, on the main actor; a finish is reported only when the test says so.
    final class FakeSynth: SpeechSynth {
        weak var runner: SpeechRunner?
        var spoken: [SerialUtterance] = []
        var speaking: SerialUtterance?
        var isSpeaking: Bool { speaking != nil }
        var isPaused: Bool { false }

        func speak(_ utterance: AVSpeechUtterance) {
            let u = utterance as! SerialUtterance
            spoken.append(u)
            speaking = u
        }

        @discardableResult func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
            guard let u = speaking else { return false }
            speaking = nil
            let serial = u.serial
            Task { @MainActor [weak runner] in runner?.utteranceEnded(serial) }   // didCancel, delivered late
            return true
        }

        func finishCurrent() {
            guard let u = speaking else { return }
            speaking = nil
            runner?.utteranceEnded(u.serial)
        }
    }

    final class Flag: @unchecked Sendable { var done = false }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
    }

    func testALateCancelOfTheCutOffLineDoesNotEndTheNextOne() async throws {
        let synth = FakeSynth()
        let runner = SpeechRunner(synth: synth)
        synth.runner = runner

        let first = Flag(), second = Flag()
        let t1 = Task { @MainActor in try await runner.speak("First question", voice: nil); first.done = true }
        await settle()
        XCTAssertEqual(synth.spoken.count, 1)

        // Skip: the next line starts while the first still talks.
        let t2 = Task { @MainActor in try await runner.speak("Second question", voice: nil); second.done = true }
        await settle()
        XCTAssertEqual(synth.spoken.count, 2)
        XCTAssertTrue(first.done, "the cut-off line returns")
        XCTAssertFalse(second.done, "the stale didCancel of the first line must not end the second")

        synth.finishCurrent()
        try await t2.value
        try await t1.value
        XCTAssertTrue(second.done)
    }

    func testAFinishOfTheCurrentLineEndsItsWait() async throws {
        let synth = FakeSynth()
        let runner = SpeechRunner(synth: synth)
        synth.runner = runner
        let done = Flag()
        let t = Task { @MainActor in try await runner.speak("Only line", voice: nil); done.done = true }
        await settle()
        XCTAssertFalse(done.done)
        runner.utteranceEnded(nil)          // a callback for an utterance the runner did not make
        runner.utteranceEnded(12345)        // or for another serial
        await settle()
        XCTAssertFalse(done.done)
        synth.finishCurrent()
        try await t.value
        XCTAssertTrue(done.done)
    }
}
