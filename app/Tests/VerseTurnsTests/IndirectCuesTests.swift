import XCTest
@testable import VerseTurns

/// Question cues for the embedded and indirect asks of an interviewer ("I'm interested in why you chose ..."), the cases the
/// first live test of the room route missed (anytime calls, room fixes). Fictional sentences.
final class IndirectCuesTests: XCTestCase {

    func testEnglishIndirectAsksCarryTheCue() {
        let asks = [
            "I'm interested in why you chose this school and in particular why you chose accounting as a major",
            "I am interested in how you got into payments",
            "We are interested in hearing about your last project",
            "I'd like to know how the reconciliation service worked",
            "I would like to hear more about the hiking app",
            "I'd love to hear what you built first",
            "I want to understand how you ended up in backend work",
            "I'm curious about the month-end close",
            "I'm curious why you left the freight company",
            "I wonder what made you pick accounting",
            "Help me understand the trade-offs you made",
            "Talk to me about the claims model",
            "Talk me through the first week",
            "And what made you choose this school",
            "Let me ask you about the co-op",
            "I'd like you to walk me through the design",
        ]
        for a in asks { XCTAssertTrue(Cues.hasCue(a), a) }
    }

    func testStatementsAroundThemStayWithoutACue() {
        let statements = [
            "One of the big decisions you have made is which university or college to attend",
            "And an equally big if not bigger one is what your major will be",
            "We have about forty minutes so let me explain how this will go",
            "I was interested in the hiking app when I read your profile",
            "The team is curious people and we like small services",
            "I like to know what is going on in the building",
            "Thanks for coming in today and for making the time",
        ]
        for s in statements { XCTAssertFalse(Cues.hasCue(s), s) }
    }

    func testTheThreeTurnQuestionOfTheLiveTestEndsInAQuestionAndTheSetupTurnsAreStatements() {
        XCTAssertEqual(Cues.kind(of: "One of the big decisions you have made is which university or college to attend"), .statement)
        XCTAssertEqual(Cues.kind(of: "And an equally big if not bigger one is what your major will be"), .statement)
        XCTAssertEqual(Cues.kind(of: "I'm interested in why you chose this school and in particular why you chose accounting as a major"), .question)
    }

    func testAHesitationTailStillSilencesTheCue() {
        XCTAssertFalse(Cues.hasCue("I'm interested in why you um"))
    }

    func testItalianCues() {
        let asks = ["Chi ha guidato il progetto", "Cosa hai costruito per primo", "Quanti utenti aveva l'app", "Puoi spiegare come funziona il servizio",
                    "Potresti raccontarmi del tuo ultimo progetto", "Mi racconti di Harbor Ledger", "Mi parli della tua esperienza", "Raccontami del primo anno",
                    "Che cosa ti ha spinto a scegliere ragioneria", "Secondo te quale scelta ha pesato di più",
                    "Vorrei sapere perché hai lasciato l'azienda", "Mi piacerebbe capire come lavori", "Sono curioso di sapere come hai fatto"]
        for a in asks { XCTAssertTrue(Cues.hasCue(a, lang: "it"), a) }
        XCTAssertFalse(Cues.hasCue("Il servizio elabora quarantunomila pagamenti al mese", lang: "it"))
    }

    func testTurkishCues() {
        let asks = ["Bu projeyi tek başına mı yaptın", "Neden muhasebeyi seçtin", "Niye bu okulu seçtin", "Nerede çalışıyorsun", "Kim yönetti bu işi",
                    "Kaç kullanıcı vardı", "Bana projeden anlatır mısınız", "Anlatabilir misin biraz", "Bahseder misiniz çalıştığınız yerden",
                    "Acaba o iş nasıl bitti", "Merak ediyorum o kararı nasıl verdin", "Bilmek istiyorum neden ayrıldın", "Duymak isterim ilk yılı"]
        for a in asks { XCTAssertTrue(Cues.hasCue(a, lang: "tr"), a) }
        XCTAssertFalse(Cues.hasCue("Servis ayda kırk bin ödemeyi işledi", lang: "tr"))
    }
}
