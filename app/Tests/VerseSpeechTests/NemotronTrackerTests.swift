import Foundation
import XCTest
@testable import VerseSpeech

/// The token -> result logic of the Nemotron engine, without the model.
final class NemotronTrackerTests: XCTestCase {
    private func tok(_ s: String, _ t: Double) -> NemotronToken { NemotronToken(text: s, start: t, end: t + 0.08) }

    /// "What is the main risk?" as SentencePiece pieces.
    private var question: [NemotronToken] {
        [tok("\u{2581}What", 0.1), tok("\u{2581}is", 0.4), tok("\u{2581}the", 0.6), tok("\u{2581}main", 0.8),
         tok("\u{2581}ri", 1.1), tok("sk", 1.2)]
    }

    func testVolatileGrowsWordByWord() {
        var t = NemotronUtteranceTracker()
        let q = question
        XCTAssertEqual(t.ingest(Array(q[0..<2])).map(\.text), ["What is"])
        let more = t.ingest(Array(q[0..<5]))
        XCTAssertEqual(more.map(\.text), ["What is the main ri"], "partial last word is shown, as in a live display")
        XCTAssertTrue(more.allSatisfy { !$0.isFinal })
        XCTAssertEqual(t.ingest(q).map(\.text), ["What is the main risk"])
    }

    func testFinalWaitsForSilenceAndDecodedAudio_notForPunctuation() {
        var t = NemotronUtteranceTracker()
        _ = t.ingest(question)
        // Silence too short.
        XCTAssertNil(t.finalIfDue(silenceRun: 0.3, lastVoicedEnd: 1.3, decodedEnd: 2.0))
        // Silence long enough but the decoder has not yet passed the end of speech + margin.
        XCTAssertNil(t.finalIfDue(silenceRun: 0.6, lastVoicedEnd: 1.3, decodedEnd: 1.4))
        let f = t.finalIfDue(silenceRun: 0.6, lastVoicedEnd: 1.3, decodedEnd: 1.68)
        XCTAssertEqual(f?.text, "What is the main risk")
        XCTAssertEqual(f?.isFinal, true)
        XCTAssertNil(t.finalIfDue(silenceRun: 5, lastVoicedEnd: 1.3, decodedEnd: 9), "one final per utterance")
    }

    func testLatePunctuationAfterFinalIsDroppedAndNextUtteranceStartsClean() {
        var t = NemotronUtteranceTracker()
        var all = question
        _ = t.ingest(all)
        XCTAssertNotNil(t.finalIfDue(silenceRun: 1, lastVoicedEnd: 1.3, decodedEnd: 2))
        // The model emits "?" only when the next speech starts, then the next word.
        all.append(tok("?", 5.0))
        XCTAssertTrue(t.ingest(all).isEmpty, "late '?' must not open an utterance")
        XCTAssertFalse(t.isOpen)
        all.append(tok("\u{2581}Thanks", 5.2))
        XCTAssertEqual(t.ingest(all).map(\.text), ["Thanks"])
    }

    func testPunctuationInsideAnOpenUtteranceAttachesToTheWord() {
        var t = NemotronUtteranceTracker()
        let r = t.ingest(question + [tok("?", 1.5)])
        XCTAssertEqual(r.last?.text, "What is the main risk?")
    }

    func testResumeBeforeFinalSettlesTheOldUtteranceOnly() {
        var t = NemotronUtteranceTracker()
        _ = t.ingest(question)
        let f = t.finalizeOpen()
        XCTAssertEqual(f?.text, "What is the main risk")
        let next = t.ingest(question + [tok("\u{2581}Yes", 3.0)])
        XCTAssertEqual(next.map(\.text), ["Yes"])
    }

    func testLongUtteranceIsSplitKeepingTheLastWord() {
        var t = NemotronUtteranceTracker()
        t.maxUtteranceSeconds = 2
        var toks: [NemotronToken] = []
        var outs: [EngineResult] = []
        for i in 0..<10 {
            toks.append(tok("\u{2581}w\(i)", Double(i) * 0.5))
            outs += t.ingest(toks)
        }
        let finals = outs.filter(\.isFinal)
        XCTAssertFalse(finals.isEmpty)
        let tail = t.finalizeOpen()?.text ?? ""
        let joined = (finals.map(\.text) + [tail]).joined(separator: " ")
        XCTAssertEqual(joined, (0..<10).map { "w\($0)" }.joined(separator: " "), "no word lost or repeated across splits")
    }

    func testSilenceTrackerAndUtteranceCounters() {
        var s = SilenceTracker()
        XCTAssertTrue(s.add(rms: 0.1, duration: 0.01))
        XCTAssertFalse(s.add(rms: 0.0, duration: 0.5))
        XCTAssertEqual(s.run, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.lastVoicedEnd, 0.01, accuracy: 1e-9)
        s.add(rms: 0.1, duration: 0.01)
        XCTAssertEqual(s.run, 0)
    }

    func testSessionDefaultKind() {
        XCTAssertEqual(EngineFactory.sessionDefaultKind(for: "en"), .auto)
        XCTAssertEqual(EngineFactory.sessionDefaultKind(for: "it"), .speechTranscriber)
        XCTAssertEqual(EngineFactory.sessionDefaultKind(for: "tr"), .dictationTranscriber)
        XCTAssertNil(ListenConfig(lang: "en").engineKind, "nil means: use the session default (.auto for en)")
        XCTAssertThrowsError(try EngineFactory.make(lang: "it", kind: .nemotron), "Nemotron is English only")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-model-\(UUID().uuidString)")
        XCTAssertThrowsError(try EngineFactory.make(lang: "en", kind: .nemotron, nemotronModelDir: missing))
    }
}
