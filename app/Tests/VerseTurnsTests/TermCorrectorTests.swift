import Foundation
import VerseSpeech
import VerseTurns
import XCTest

/// Post-correction of the session's own names (`TermCorrector`). The misspellings are what SpeechTranscriber wrote for the
/// Italian replay of 2026-11-12 and for a `say -v Alice` probe of the same questions.
final class TermCorrectorTests: XCTestCase {

    let it = TermCorrector(bank: SampleSession.bankIT, facts: SampleSession.facts)
    let en = TermCorrector(bank: SampleSession.bankEN, facts: SampleSession.facts)

    func testTargetsAreTheSessionsNamesOnly() {
        XCTAssertTrue(it.targetNames.contains("Lantern"))
        XCTAssertTrue(it.targetNames.contains("Halden"))
        XCTAssertTrue(it.targetNames.contains("Compass"))
        // Acronyms and words the session writes in lower case ("LLM systems") are no targets.
        XCTAssertFalse(it.targetNames.contains("LLM"))
        XCTAssertFalse(it.targetNames.contains("Systems"))
    }

    func testItalianMisspellingsOfTheNamesAreCorrected() {
        XCTAssertEqual(it.correct("Qual è stata la parte più difficile nel costruire l'anterm", lang: "it"),
                       "Qual è stata la parte più difficile nel costruire Lantern")
        XCTAssertEqual(it.correct("L'anterna davvero fatto la differenza facci vedere i numeri", lang: "it"),
                       "Lantern davvero fatto la differenza facci vedere i numeri")
        XCTAssertEqual(it.correct("Puoi parlarmi del progetto Lanter.", lang: "it"), "Puoi parlarmi del progetto Lantern.")
        XCTAssertEqual(it.correct("Cosa ti ha portato a guardare proprio al Den?", lang: "it"), "Cosa ti ha portato a guardare proprio Halden?")
        // Replay it03 (after build): the name glued to the article, and Halden without its silent h.
        XCTAssertEqual(it.correct("Ok, l'antern può gestire molte fatture al giorno", lang: "it"), "Ok, Lantern può gestire molte fatture al giorno")
        XCTAssertEqual(it.correct("perché vuoi entrare in Alden Fid systems", lang: "it"), "perché vuoi entrare in Halden Fid systems")
    }

    func testOrdinaryWordsAreNeverRewritten() {
        let unchanged = [
            "Ho comprato una lanterna per il campeggio",          // the Italian word, not the name
            "Cosa ti ha portato a guardare proprio al",           // "al" alone stays "al" (the replay heard just that)
            "La lanterna e l'antenna sono sul tetto",
            "Lantern ha davvero fatto la differenza",             // already right
            "Puoi parlarmi del progetto Lantern",
        ]
        for s in unchanged { XCTAssertEqual(it.correct(s, lang: "it"), s, s) }
        // English: a sentence-initial capital says nothing, and a word the session writes in lower case is not a name.
        XCTAssertEqual(en.correct("Holden said the System works", lang: "en"), "Holden said the System works")
        // The elision rule is Italian only.
        XCTAssertEqual(en.correct("we built l'anterna", lang: "en"), "we built l'anterna")
    }

    func testEnglishCapitalizedNearMiss() {
        XCTAssertEqual(en.correct("Why do you want to join Holden freight systems?", lang: "en"),
                       "Why do you want to join Halden freight systems?")
    }

    func testTheTurnEngineSendsTheCorrectedText() async {
        let heard = "Qual è stata la parte più difficile nel costruire l'anterm"
        func partialText(correct: Bool) async -> String? {
            var cfg = TurnConfig(lang: "it")
            cfg.correctTerms = correct
            let engine = TurnEngine(config: cfg, bank: SampleSession.bankIT, facts: SampleSession.facts)
            var e = ev(heard, at: 1.0)
            e.lang = "it"
            return await engine.ingestTimed(e).partials.last?.text
        }
        let fixed = await partialText(correct: true)
        XCTAssertEqual(fixed, "Qual è stata la parte più difficile nel costruire Lantern")
        let raw = await partialText(correct: false)
        XCTAssertEqual(raw, heard)
    }

    func testVocabularyForTheRecognizer() {
        let v = SessionTerms.vocabulary(bank: SampleSession.bankIT, facts: SampleSession.facts)
        for name in ["Lantern", "Halden Freight Systems", "ETA drift", "Compass", "LLM-assisted dispatcher", "Ingrid Solberg"] {
            XCTAssertTrue(v.contains(name), name)
        }
        XCTAssertEqual(Set(v.map { $0.lowercased() }).count, v.count, "each name once")
        XCTAssertTrue(SessionTerms.vocabulary(bank: .empty, facts: .empty).isEmpty)
    }
}
