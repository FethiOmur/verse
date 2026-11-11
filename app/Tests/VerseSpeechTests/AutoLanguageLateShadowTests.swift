import Foundation
@testable import VerseSpeech
import XCTest

/// S3: a shadow final that arrives after the main final of the same speech was judged (later than `pairGrace`) is weighed
/// against that main text, as the pair would have been. It used to vote alone, unopposed.
final class AutoLanguageLateShadowTests: XCTestCase {
    typealias T = AutoLanguageTests

    func fin(_ text: String, _ start: Double, _ end: Double, lang: String = "it", shadow: Bool = false) -> LangFinal {
        LangFinal(channel: .remote, lang: lang, text: text, start: start, end: end, shadow: shadow)
    }

    func testOneLongLateShadowDoesNotFlipAConfidentCall() {
        // 7 s of clear Italian; the English shadow's text of the same speech comes in 1.8 s after its end.
        var d = AutoLanguageDetector(current: "it", auto: true)
        d.shadowActive = true
        d.note(fin(T.it1, 0, 7))
        XCTAssertNil(d.advance(to: 8.6), "judged: the shadow's final is not in yet")
        d.note(fin(T.en1, 0, 7, lang: "en", shadow: true))
        XCTAssertNil(d.advance(to: 8.8), "a late shadow does not switch a clean Italian call on its own (it had 7 s >= 6 s)")
        XCTAssertEqual(d.current, "it")
        XCTAssertNil(d.openRun)
    }

    func testTwoLateShadowsInARowDoNotFlipAConfidentCall() {
        var d = AutoLanguageDetector(current: "it", auto: true)
        d.shadowActive = true
        d.note(fin(T.it1, 0, 3))
        d.note(fin(T.it2, 4, 7))
        XCTAssertNil(d.advance(to: 8.6), "both main finals judged")
        d.note(fin(T.en1, 0, 3, lang: "en", shadow: true))
        d.note(fin(T.en2, 4, 7, lang: "en", shadow: true))
        XCTAssertNil(d.advance(to: 8.8), "two late shadows would make a run of 2 alone")
        XCTAssertEqual(d.current, "it")
        XCTAssertNil(d.openRun)
    }

    func testALateCleanShadowStillBeatsAGarbledMainText() {
        // The pair rule holds when the shadow is late: clean English beats the garbled Italian text by the margin.
        var d = AutoLanguageDetector(current: "it", auto: true)
        d.shadowActive = true
        d.note(fin(T.garbledIt, 10, 13))
        XCTAssertNil(d.advance(to: 14.6))
        d.note(fin(T.cleanEn, 10, 13, lang: "en", shadow: true))
        XCTAssertNil(d.advance(to: 14.8))
        XCTAssertEqual(d.openRun?.lang, "en")
        // Known limit (as before the fix): the next garbled main text, judged alone, votes Italian and ends the run, so
        // late pairs alone never reach two in a row; the late shadow starts a new run of one.
        d.note(fin(T.garbledIt, 17, 20))
        XCTAssertNil(d.advance(to: 21.6))
        d.note(fin(T.cleanEn, 17, 20, lang: "en", shadow: true))
        XCTAssertNil(d.advance(to: 21.8))
        XCTAssertEqual(d.openRun?.lang, "en")
    }

    func testAShadowWithNoMainFinalStillVotesAlone() {
        var d = AutoLanguageDetector(current: "it", auto: true)
        d.shadowActive = true
        d.note(fin(T.en1, 0, 3, lang: "en", shadow: true))
        XCTAssertNil(d.advance(to: 5.6))
        d.note(fin(T.en2, 6, 9, lang: "en", shadow: true))
        XCTAssertEqual(d.advance(to: 11.6)?.to, "en")
    }
}
