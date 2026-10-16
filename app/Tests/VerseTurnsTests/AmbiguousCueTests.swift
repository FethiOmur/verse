import Foundation
import VerseSpeech
import VerseTurns
import XCTest

/// Live Italian call, 16 Oct (personal, so the sentences here are invented in the same shape): a fragment of the card Alex was
/// reading aloud ended in "... come questo". "come" (as, like) was a single-word Italian question cue, the fragment became a
/// question and the room route replaced the card he was reading. Question words that are also ordinary words now ask only where
/// a clause opens, and every cue says what set it and whether it is unambiguous.
final class AmbiguousCueTests: XCTestCase {

    func testComeInTheMiddleOfAClauseIsNotACue() {
        let reading = ["Ho lavorato su app di sviluppo mobile come questo", "un progetto come questo nel prodotto", "e il feedback frequente come questo",
                       "sono una persona come tante", "ha ridotto i tempi come previsto", "lavoro bene come membro di un team"]
        for s in reading { XCTAssertFalse(Cues.hasCue(s, lang: "it"), s) }
    }

    func testComeOpeningAClauseOrBeforeAVerbIsACue() {
        let asks: [(String, String, Bool)] = [
            ("Come si descriverebbe come membro di un team", "come si", true),
            ("Ottimo, come si descriverebbe come membro di un team", "come si", true),
            ("E come mai ha scelto questa azienda", "come mai", true),
            ("Lei come ha affrontato il problema", "come ha", true),
            ("Come funziona il vostro sistema", "come funziona", true),
            ("Come sta andando il progetto", "come sta", true),
            ("Come gestisce i conflitti", "come", false),         // opens the sentence: a question, but not a distinctive one
            ("Perché ha scelto questa azienda", "perché", false),
            ("E quando ha iniziato a programmare", "quando", false),
            ("Con quale linguaggio ha lavorato di più", "quale", false),
            ("A chi riportava nel team", "chi", false),
        ]
        for (text, why, strong) in asks {
            let m = Cues.cueMatch(text, lang: "it")
            XCTAssertEqual(m?.why, why, text)
            XCTAssertEqual(m?.strong, strong, text)
        }
    }

    func testOrdinaryUsesOfTheOtherQuestionWordsAreNotCues() {
        let plain = ["Lavoro qui perché mi piace il prodotto", "Una cosa che ho imparato è il feedback", "Ho scelto Harbor Ledger quando ero a Milan",
                     "Il team dove lavoravo era piccolo", "Il linguaggio quale preferisco è Swift", "Ho guidato tre colleghi quanto basta",
                     "Ho incontrato chi sapeva di prodotto", "ho trovato che la chiave sia la chiarezza degli obiettivi"]
        for s in plain { XCTAssertFalse(Cues.hasCue(s, lang: "it"), s) }
    }

    func testDistinctiveItalianCuesAreStrongAnywhere() {
        for (s, why) in [("Mi racconti del progetto Harbor Ledger", "mi racconti"), ("Secondo te cosa è andato storto", "secondo te"),
                         ("Dimmi del tuo ultimo progetto", "dimmi"), ("Vorrei sapere come lavora in un team", "vorrei sapere"),
                         ("Allora parlami del tuo ruolo", "parlami")] {
            XCTAssertEqual(Cues.cueMatch(s, lang: "it"), CueMatch(why: why, strong: true), s)
        }
    }

    func testTurkishParticlesAreStrongAndBareQuestionWordsAreWeak() {
        XCTAssertEqual(Cues.cueMatch("Takım yönetme deneyiminiz oldu mu", lang: "tr"), CueMatch(why: "mu", strong: true))
        XCTAssertEqual(Cues.cueMatch("Bu projeyi tek başınıza yaptınız mısınız", lang: "tr")?.strong, true)
        XCTAssertEqual(Cues.cueMatch("Bu projeyi nasıl yaptınız", lang: "tr"), CueMatch(why: "nasıl", strong: false))
        XCTAssertEqual(Cues.cueMatch("Ne zaman başladınız", lang: "tr"), CueMatch(why: "ne zaman", strong: true))
        XCTAssertNil(Cues.cueMatch("Ekip için çalıştım ve ürünle ilgilendim", lang: "tr"))
    }

    func testEnglishCuesAreStrongAndNameTheirWord() {
        XCTAssertEqual(Cues.cueMatch("Could you walk me through the routing service", lang: "en"), CueMatch(why: "could", strong: true))
        XCTAssertNil(Cues.cueMatch("We shipped the routing service last quarter", lang: "en"))
        XCTAssertEqual(Cues.hasCue("Why did you choose accounting", lang: "en"), true)
    }

    // MARK: through the engine (room route)

    private func room() -> TurnEngine {
        var c = TurnConfig()
        c.roomMode = true
        c.lang = "it"
        return TurnEngine(config: c, bank: .empty, facts: .empty)
    }

    private func hear(_ text: String, _ e: TurnEngine) async -> [TurnEngine.Timed] {
        var out = await e.ingestTimed(ev(text, at: 10.0))
        out += await e.advance(to: 20)
        return out
    }

    func testAReadingFragmentWithComeQuestoIsAStatementAndCarriesNoCue() async {
        let out = await hear("e il feedback frequente come questo", room())
        XCTAssertEqual(out.turnKinds, [.statement])
        for t in out { XCTAssertNil(t.cue, "no cue to send") }
        let partial = out.compactMap { t -> Bool? in if case .partial(_, _, _, let cue, _) = t.event { return cue } else { return nil } }
        XCTAssertEqual(partial.last, false)
    }

    func testARealItalianQuestionCarriesWhatSetItsCue() async {
        let out = await hear("Ottimo, come si descriverebbe come membro di un team", room())
        XCTAssertEqual(out.turnKinds, [.question])
        let turn = out.last { if case .turn = $0.event { return true } else { return false } }
        XCTAssertEqual(turn?.cue, CueMatch(why: "come si", strong: true))
        // ... and the wire line says so; a line without a cue is exactly what it was
        let line = turn!.event.jsonLine(lang: turn?.lang, cue: turn?.cue)
        let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        XCTAssertEqual(o?["cue_why"] as? String, "come si")
        XCTAssertEqual(o?["cue_strong"] as? Bool, true)
        let bare = turn!.event.jsonLine(lang: "it", cue: nil)
        XCTAssertFalse(bare.contains("cue_why") || bare.contains("cue_strong"))
        XCTAssertEqual(bare, turn!.event.jsonLine(lang: "it"))
        XCTAssertEqual(turn!.event.jsonLine(lang: nil, cue: nil), turn!.event.jsonLine())
        XCTAssertEqual(OutboundEvent.decodeLenient(line), turn!.event, "an older reader ignores the extra keys")
    }
}
