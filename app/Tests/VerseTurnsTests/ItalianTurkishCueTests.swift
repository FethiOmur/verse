import Foundation
import VerseTurns
import XCTest

/// Question detection in Italian and Turkish without a "?" (the recognizer rarely writes one). The first four Italian
/// texts are what the 2026-11-12 Italian replay heard and classed as statements (eval/out/it-fresh).
final class ItalianTurkishCueTests: XCTestCase {

    func testItalianQuestionsTheReplayMissed() {
        let heard = [
            "Qual è stata la parte più difficile nel costruire l'anterm",      // "qual", the elided "quale"
            "L'anterna davvero fatto la differenza facci vedere i numeri",     // "show us the numbers"
            "you Puoi parlarmi del progetto Lanter",                           // a stray word before "puoi" + infinitive
            "Che percentuale di campi aggeccava",                              // "che" opening the turn
        ]
        for t in heard {
            XCTAssertEqual(Cues.kind(of: t, lang: "it"), .question, t)
        }
    }

    func testItalianAsksWithoutAQuestionWord() {
        let asks = [
            "Mi può dire quanto è durato il progetto",
            "Ci può spiegare il dispatcher",
            "Può spiegarci come funziona la pipeline",
            "Potresti raccontarmi del pilota con i corrieri",
            "Mi racconti del suo ultimo lavoro",
            "Ci racconti del progetto Lantern",
            "Ci parli del suo ruolo attuale",
            "Raccontaci il tuo background",
            "Descrivi il tuo processo di valutazione",
            "Fammi capire come avete misurato l'accuratezza",
            "Hai mai lavorato con modelli piccoli",
            "Volevo chiederti del tuo preavviso",
            "Qual'è il tuo punto debole",
            "Cos'è per te l'ETA drift",
            "In che modo avete ridotto i costi",
            "E che tipo di errori faceva il modello",
        ]
        for a in asks {
            XCTAssertEqual(Cues.kind(of: a, lang: "it"), .question, a)
        }
    }

    func testItalianStatementsStayStatements() {
        let statements = [
            "Abbiamo un sistema, che gestisce le rotte ogni novanta secondi",   // relative "che" after a comma
            "Che bello sentirti di nuovo oggi",                                // exclamation
            "Lantern può gestire molte fatture al giorno",                     // third person "può" + infinitive: a fact
            "Non puoi immaginare quanto lavoro abbiamo fatto",                 // rhetorical
            "Fammi pensare un attimo a questo punto",                          // "let me think"
            "Il team ha sei persone e riporta a Ingrid",
            "Abbiamo in programma uno site aziendale a Lisbona la prossima primavera",
        ]
        for s in statements {
            XCTAssertNotEqual(Cues.kind(of: s, lang: "it"), .question, s)
        }
    }

    func testTurkishQuestionsWithoutParticleOrWithItGlued() {
        let asks = [
            "Biraz kendinizden bahsedin",                 // imperative ask
            "Lantern projesini anlatın",
            "Lantern nedir",
            "Projeden bahsedermisiniz",                   // particle written onto the verb
            "Pilot projede sonuçlar nasıldı",
        ]
        for a in asks {
            XCTAssertEqual(Cues.kind(of: a, lang: "tr"), .question, a)
        }
        for s in ["Bu projede çok çalıştık", "Ekibimiz altı kişiden oluşuyor"] {
            XCTAssertNotEqual(Cues.kind(of: s, lang: "tr"), .question, s)
        }
    }
}
