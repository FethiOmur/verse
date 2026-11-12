import Foundation
import VerseSpeech
@testable import VerseTurns
import XCTest

/// Question cues behind leading fillers and discourse markers (`Cues.afterLeadingFillers`).
final class LeadingFillerCueTests: XCTestCase {

    /// The partials of replay live-en-after, d06 r5, as the recognizer delivered them (no full stop after "the", unlike
    /// the fake-brain replays of the same audio): the turn went to the brain as a statement.
    static let d06 = ["U", "UM", "UM,", "UM, So", "UM, So and", "UM, So and the", "UM, So and the How", "UM, So and the How long",
                      "UM, So and the How long until", "UM, So and the How long until you", "UM, So and the How long until you could",
                      "UM, So and the How long until you could be", "UM, So and the How long until you could begin",
                      "UM, So and the How long until you could begin if", "UM, So and the How long until you could begin if you",
                      "UM, So and the How long until you could begin if you accept",
                      "UM, So and the How long until you could begin if you accepted"]

    func testQuestionBehindFillersIsAQuestionTurn() async {
        let engine = TurnEngine(config: TurnConfig(lang: "en"), bank: .empty, facts: .empty)
        var out: [TurnEngine.Timed] = []
        for (i, p) in Self.d06.enumerated() { out += await engine.ingestTimed(ev(p, at: 1.0 + Double(i) * 0.1)) }
        out += await engine.flush(at: 4)
        XCTAssertEqual(out.turnKinds, [.question])
        XCTAssertEqual(out.partials.last?.cue, true)
        XCTAssertEqual(Cues.cueMatch(Self.d06.last!, lang: "en")?.why, "how")
    }

    /// Without commas, so the cue comes from setting the fillers aside (after a comma a question word already opened a clause).
    func testFillersInFrontOfQuestions() {
        let en = ["Um you know what drove the choice of model size",
                  "Uh so and the what did the courier pilot teach you",
                  "And the how long until you could begin"]
        for t in en { XCTAssertEqual(Cues.kind(of: t, lang: "en"), .question, t) }
        let it = ["Cioè come hai gestito i casi incerti",
                  "Beh quanto sei flessibile sulla retribuzione",
                  "Senti quando hai iniziato a lavorare con gli LLM",
                  "Allora il come valuti un sistema LLM"]
        for t in it { XCTAssertEqual(Cues.kind(of: t, lang: "it"), .question, t) }
        // Turkish cues do not depend on where the clause starts: these were questions before and stay questions.
        let tr = ["Şey yani projeyi nasıl yaptınız", "Peki tamam ne zaman başlayabilirsiniz"]
        for t in tr { XCTAssertEqual(Cues.kind(of: t, lang: "tr"), .question, t) }
    }

    /// Written without commas on purpose: a comma is a clause boundary, and a question word right after one already set a
    /// cue before this change ("Cioè, come dicevo" was and is a question; see the report of 2026-11-12). These are the
    /// statements the skipping itself could have turned into questions.
    func testStatementsThatStartWithFillersStayStatements() {
        let en = ["Um so we shipped it last week",
                  "You know what we did was rebuild the extraction step",
                  "Well the dispatcher pilot went fine",
                  "Okay and the team has six people now",
                  "So and the how it works is a long story"]
        for t in en { XCTAssertNotEqual(Cues.kind(of: t, lang: "en"), .question, t) }
        let it = ["Cioè come dicevo il modello sbagliava spesso",
                  "Beh perché era tardi e il team era stanco",
                  "Senti cosa normale in un progetto così",
                  "Cioè come tutti gli altri team del settore",
                  "Quindi abbiamo ridotto i costi del trenta per cento"]
        for t in it { XCTAssertNotEqual(Cues.kind(of: t, lang: "it"), .question, t) }
        let tr = ["Şey yani projeyi geçen yıl bitirdik", "Peki tamam anlaştık o zaman"]
        for t in tr { XCTAssertNotEqual(Cues.kind(of: t, lang: "tr"), .question, t) }
    }
}
