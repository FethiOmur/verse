import Foundation
@testable import VerseSpeech
import XCTest

/// Interim AUTO language (spec 2.5): text language identification and the detector's hysteresis. Fictional sentences; no audio.
final class AutoLanguageTests: XCTestCase {

    // MARK: sentences

    static let en1 = "We shipped the new routing service last week and it works well"
    static let en2 = "The migration finished on Tuesday and nobody noticed any downtime"
    static let en3 = "So the routing service has a queue and a worker and a small cache"
    static let it1 = "Abbiamo spostato il servizio di instradamento la settimana scorsa e funziona bene"
    static let it2 = "La migrazione è finita martedì e nessuno ha notato interruzioni"
    static let it3 = "Ciao come stai oggi vorrei sapere di più sul tuo ultimo progetto"
    static let tr1 = "Bana en gurur duyduğun projeyi anlatır mısın"
    /// Italian with English loanwords: still an Italian sentence.
    static let itLoan = "Poi usiamo React e machine learning per TrailHead"
    /// Fictional example of the half-Italian text an Italian recognizer makes of English speech.
    static let garbledIt = "la sera very easy in English, Englishable"
    static let cleanEn = "so tell me a little bit about how you spend the weekend"

    func fin(_ text: String, _ start: Double, _ end: Double, lang: String = "it", channel: Channel = .remote,
             confidence: Double? = nil, shadow: Bool = false) -> LangFinal {
        LangFinal(channel: channel, lang: lang, text: text, start: start, end: end, confidence: confidence, shadow: shadow)
    }

    /// Feeds finals (each at its own end time) and returns the first decision.
    func feed(_ d: inout AutoLanguageDetector, _ finals: [LangFinal]) -> AutoLangDecision? {
        for f in finals {
            d.note(f)
            if let x = d.advance(to: f.end + 0.1) { return x }
        }
        return nil
    }

    // MARK: text identification

    func testTheThreeLanguagesAreIdentifiedConfidently() {
        for (text, lang) in [(Self.en1, "en"), (Self.it1, "it"), (Self.tr1, "tr"), (Self.itLoan, "it")] {
            let g = LanguageID.guess(text)
            XCTAssertEqual(g?.lang, lang, text)
            XCTAssertGreaterThanOrEqual(g?.confidence ?? 0, 0.8, text)
        }
    }

    func testShortTextIsNotJudgedAndTheEngineLanguageStands() {
        XCTAssertNil(LanguageID.guess("Okay thanks"))
        XCTAssertNil(LanguageID.guess("Perché no"))
        XCTAssertEqual(LanguageID.turnLang("Okay thanks", engineLang: "it"), "it", "two words: the engine's language")
        XCTAssertEqual(LanguageID.turnLang(Self.en1, engineLang: "it"), "en", "an English question in an Italian session")
        XCTAssertEqual(LanguageID.turnLang(Self.it1, engineLang: "en"), "it")
        XCTAssertEqual(LanguageID.turnLang(Self.tr1, engineLang: "en"), "tr")
    }

    func testTurnLangNeedsEightyPercent() {
        // The recognizer gives the garbled text 0.64 for Italian: not enough to name the turn's language.
        let g = LanguageID.guess(Self.garbledIt)
        XCTAssertEqual(g?.lang, "it")
        XCTAssertLessThan(g?.confidence ?? 1, 0.8)
        XCTAssertEqual(LanguageID.turnLang(Self.garbledIt, engineLang: "en"), "en", "unsure: the engine's language")
    }

    // MARK: hysteresis (no shadow: finals are judged at once)

    func testAnItalianSentenceWithLoanwordsIsNotAVoteForEnglish() {
        var d = AutoLanguageDetector(current: "it", auto: true)
        XCTAssertNil(feed(&d, [fin(Self.it1, 0, 4), fin(Self.itLoan, 5, 8), fin(Self.it2, 9, 12)]))
        XCTAssertNil(d.openRun)
    }

    func testOneEnglishFinalInAnItalianCallDoesNotSwitch() {
        var d = AutoLanguageDetector(current: "it", auto: true)
        XCTAssertNil(feed(&d, [fin(Self.it1, 0, 4), fin(Self.en1, 5, 8)]))
        XCTAssertEqual(d.openRun?.lang, "en")
        XCTAssertEqual(d.openRun?.finals, 1)
        // Italian again: the run of English is over.
        XCTAssertNil(feed(&d, [fin(Self.it2, 9, 12)]))
        XCTAssertNil(d.openRun)
        // A second English final alone starts a new run: still no switch.
        XCTAssertNil(feed(&d, [fin(Self.en2, 13, 16)]))
        XCTAssertEqual(d.current, "it")
    }

    func testTwoEnglishFinalsInARowSwitch() {
        var d = AutoLanguageDetector(current: "it", auto: true)
        let x = feed(&d, [fin(Self.it1, 0, 4), fin(Self.en1, 5, 8), fin(Self.en2, 9, 12)])
        XCTAssertEqual(x?.from, "it")
        XCTAssertEqual(x?.to, "en")
        XCTAssertEqual(x?.finals, 2)
        XCTAssertEqual(d.current, "en")
    }

    func testOneLongStretchOfSpeechSwitches() {
        var d = AutoLanguageDetector(current: "it", auto: true)
        let x = feed(&d, [fin(Self.en3, 0, 6.5)])
        XCTAssertEqual(x?.to, "en", "6 s of English in one final")
        XCTAssertEqual(x?.finals, 1)
        var short = AutoLanguageDetector(current: "it", auto: true)
        XCTAssertNil(feed(&short, [fin(Self.en3, 0, 5.5)]), "5.5 s is not enough on its own")
    }

    func testTurkishIsRecognizedAsAThirdLanguage() {
        var d = AutoLanguageDetector(current: "en", auto: true)
        let x = feed(&d, [fin(Self.tr1, 0, 3), fin(Self.tr1, 4, 7)])
        XCTAssertEqual(x?.to, "tr")
    }

    func testNoSecondSwitchWithinTenSecondsOfTheLast() {
        var d = AutoLanguageDetector(current: "it", auto: true)
        XCTAssertEqual(feed(&d, [fin(Self.en1, 0, 3), fin(Self.en2, 3.5, 6)])?.to, "en")   // switched at 6.1
        // Two Italian finals right after: the run is complete at 12 s but the dwell runs to 16.1 s.
        d.note(fin(Self.it1, 7, 9, lang: "en"))
        d.note(fin(Self.it2, 9.5, 12, lang: "en"))
        XCTAssertNil(d.advance(to: 12.1))
        XCTAssertNil(d.advance(to: 16.0))
        XCTAssertEqual(d.current, "en")
        XCTAssertEqual(d.advance(to: 16.2)?.to, "it", "as soon as the dwell is over, the evidence still stands")
    }

    func testAPinnedLanguageNeverSwitches() {
        var d = AutoLanguageDetector(current: "it", auto: false)
        XCTAssertNil(feed(&d, [fin(Self.en1, 0, 8), fin(Self.en2, 9, 12), fin(Self.en3, 13, 20), fin(Self.en1, 21, 30)]))
        XCTAssertEqual(d.current, "it")
        // Turning AUTO on later does not use what was said while pinned.
        d.setAuto(true)
        XCTAssertNil(feed(&d, [fin(Self.en2, 31, 34)]))
        XCTAssertEqual(d.current, "it")
    }

    func testAChipPinChangesTheCurrentLanguageAndStartsADwell() {
        var d = AutoLanguageDetector(current: "en", auto: true)
        d.setCurrent("tr", at: 100)
        XCTAssertEqual(d.current, "tr")
        d.note(fin(Self.en1, 101, 104, lang: "tr"))
        d.note(fin(Self.en2, 104, 107, lang: "tr"))
        XCTAssertNil(d.advance(to: 107.1), "inside the dwell of the pin")
        XCTAssertEqual(d.advance(to: 110.1)?.to, "en")
    }

    func testARevertedSwitchGoesBackWithoutADwell() {
        var d = AutoLanguageDetector(current: "it", auto: true)
        XCTAssertNotNil(feed(&d, [fin(Self.en1, 0, 3), fin(Self.en2, 3.5, 6)]))
        d.revert(to: "it", lastSwitchAt: nil)
        XCTAssertEqual(d.current, "it")
        XCTAssertNil(d.lastSwitchAt)
    }

    // MARK: channels

    func testTheMicrophoneVotesOnlyWhenTheRemoteIsQuiet() {
        var d = AutoLanguageDetector(current: "it", auto: true)
        // The remote speaks Italian up to 20 s; the owner answers in English meanwhile: the remote has priority.
        XCTAssertNil(feed(&d, [fin(Self.it1, 0, 4), fin(Self.en1, 5, 8, channel: .me), fin(Self.en2, 9, 12, channel: .me)]))
        XCTAssertEqual(d.current, "it")
        // Long after the remote's last word the microphone's English counts.
        var q = AutoLanguageDetector(current: "it", auto: true)
        let x = feed(&q, [fin(Self.it1, 0, 4), fin(Self.en1, 30, 33, channel: .me), fin(Self.en2, 34, 37, channel: .me)])
        XCTAssertEqual(x?.to, "en")
        XCTAssertEqual(x?.channel, .me)
    }

    // MARK: shadow

    func testACleanShadowTextOutvotesGarbledMainText() {
        var d = AutoLanguageDetector(current: "it", auto: true)
        d.shadowActive = true
        // The Italian recognizer's garbled text judges 0.74 Italian; the English shadow's text of the same speech is 1.0 English.
        d.note(fin(Self.garbledIt, 10, 13))
        d.note(fin(Self.cleanEn, 10, 13, lang: "en", shadow: true))
        XCTAssertNil(d.advance(to: 13.5), "main finals wait for their shadow")
        XCTAssertNil(d.advance(to: 15.6))
        XCTAssertEqual(d.openRun?.lang, "en")
        d.note(fin(Self.garbledIt, 17, 20))
        d.note(fin(Self.cleanEn, 17, 20, lang: "en", shadow: true))
        XCTAssertEqual(d.advance(to: 22.6)?.to, "en")
    }

    func testAShadowTextThatDoesNotBeatAConfidentMainTextCountsForNothing() {
        var d = AutoLanguageDetector(current: "it", auto: true)
        d.shadowActive = true
        for i in 0..<3 {
            let s = Double(i) * 5
            d.note(fin(Self.it1, s, s + 3))
            d.note(fin(Self.en1, s, s + 3, lang: "en", shadow: true))     // English-looking shadow text: a coincidence
            XCTAssertNil(d.advance(to: s + 6))
        }
        XCTAssertNil(d.openRun)
        XCTAssertEqual(d.current, "it")
    }

    func testALowEngineConfidenceWeakensTheShadow() {
        var d = AutoLanguageDetector(current: "it", auto: true)
        d.shadowActive = true
        d.note(fin(Self.garbledIt, 0, 3))
        d.note(fin(Self.cleanEn, 0, 3, lang: "en", confidence: 0.3, shadow: true))   // 1.0 x 0.3 < 0.6
        XCTAssertNil(d.advance(to: 6))
        XCTAssertNil(d.openRun, "an unsure shadow and an unsure main text: nobody votes")
    }

    func testAShadowFinalWithNoMainFinalIsJudgedAlone() {
        // The Italian recognizer heard nothing in English speech; the English shadow did.
        var d = AutoLanguageDetector(current: "it", auto: true)
        d.shadowActive = true
        d.note(fin(Self.en1, 0, 3, lang: "en", shadow: true))
        XCTAssertNil(d.advance(to: 2))
        XCTAssertNil(d.advance(to: 5.6))
        d.note(fin(Self.en2, 6, 9, lang: "en", shadow: true))
        XCTAssertEqual(d.advance(to: 11.6)?.to, "en")
    }

    func testTheMainTextHintsWhichCandidateTheShadowShouldTry() {
        var d = AutoLanguageDetector(current: "it", auto: true)
        XCTAssertEqual(d.note(fin(Self.en1, 0, 3)), "en")
        XCTAssertNil(d.note(fin(Self.it1, 4, 7)), "the current language is not a hint")
        XCTAssertEqual(d.shadowOrder().first, "en", "the open run's language first")
        XCTAssertEqual(AutoLanguageDetector(current: "it", auto: true).shadowOrder(), ["en", "tr"])
        XCTAssertEqual(AutoLanguageDetector(current: "en", auto: true).shadowOrder(), ["it", "tr"])
    }
}
