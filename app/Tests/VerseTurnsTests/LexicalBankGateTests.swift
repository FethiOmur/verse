import Foundation
import VerseSpeech
@testable import VerseTurns
import XCTest

/// The word-level check on lexical bank hits (`BankMatcher.coverage`, `TurnConfig.matchCoverage`). The partial sequences
/// are the recognizer's own, copied from the 2026-11-12 replays (eval/out/f3-fresh, live1, it-fresh).
final class LexicalBankGateTests: XCTestCase {

    private func hits(_ partials: [String], bank: Bank = SampleSession.bankEN, lang: String = "en", coverage: Double? = nil) async -> [String] {
        await run(partials, bank: bank, lang: lang, coverage: coverage).ids
    }

    /// The cards of one turn fed partial by partial and closed at the end (the endpoint check runs there), and the partial
    /// each first appeared on ("<end>" when the endpoint sent it).
    private func run(_ partials: [String], bank: Bank = SampleSession.bankEN, lang: String = "en",
                     coverage: Double? = nil) async -> (ids: [String], at: [String]) {
        var cfg = TurnConfig(lang: lang)
        if let coverage { cfg.matchCoverage = coverage }
        let engine = TurnEngine(config: cfg, bank: bank, facts: .empty)
        var ids: [String] = [], at: [String] = []
        // The engine sends a hit again when its score moves by 0.08 or more; one card is one entry here.
        func note(_ events: [TurnEngine.Timed], _ label: String) {
            for b in events.bankHits.map(\.bank) where ids.last != b { ids.append(b); at.append(label) }
        }
        // 0.15 s apart: inside the 300/600 ms endpoint, so the turn stays open until the flush.
        for (i, p) in partials.enumerated() {
            var e = ev(p, at: 1.0 + Double(i) * 0.15)
            e.lang = lang
            note(await engine.ingestTimed(e), p)
        }
        note(await engine.flush(at: 1.0 + Double(partials.count) * 0.15), "<end>")
        return (ids, at)
    }

    // MARK: wrong cards of the replay

    static let dispatcher = ["How", "How would", "How would you", "How would you measure", "How would you measure success",
                             "How would you measure success for", "How would you measure success for the",
                             "How would you measure success for the dis", "How would you measure success for the disp",
                             "How would you measure success for the dispatcher", "How would you measure success for the dispatcher pilot?"]
    static let courier = ["What", "What did", "What did the", "What did the c", "What did the cou", "What did the couri",
                          "What did the courier", "What did the courier p", "What did the courier pil", "What did the courier pilot",
                          "What did the courier pilot teach you about live traffic"]
    static let aboutYourself = ["Can you", "Can you tell me", "Can you tell me about", "Can you tell me about",
                                "Can you tell me about yourself", "Can you tell me about yourself and",
                                "Can you tell me about yourself and your", "Can you tell me about yourself and your background"]

    func testOffBankQuestionSharingAPhraseShowsNoCard() async {
        let gated = await hits(Self.dispatcher)
        XCTAssertEqual(gated, [], "'measure success' is shared with a Lantern paraphrase; the question is about the dispatcher pilot")
        let old = await hits(Self.dispatcher, coverage: 0)
        XCTAssertEqual(old, ["b004"], "without the word check the n-gram matcher shows the Lantern card (replay d04)")
    }

    func testOffBankQuestionSharingARareWordShowsNoCard() async {
        let gated = await hits(Self.courier)
        XCTAssertEqual(gated, [])
        let old = await hits(Self.courier, coverage: 0)
        XCTAssertEqual(old, ["b007"], "replay d06: 'courier' alone brought the route optimiser card")
    }

    func testSharedPrefixWaitsForTheWordThatDecides() async {
        let gated = await hits(Self.aboutYourself)
        XCTAssertEqual(gated, ["b001"], "'Can you tell me about' starts b001 and b003 alike; no b003 flash")
        let old = await hits(Self.aboutYourself, coverage: 0)
        XCTAssertEqual(old.first, "b003", "replay d01/d07: b003 flashed before b001")
        let lantern = await hits(["Can you", "Can you tell me about", "Can you tell me about", "Can you tell me about the",
                                  "Can you tell me about the Lantern", "Can you tell me about the Lantern Project"])
        XCTAssertEqual(lantern, ["b003"])
    }

    // MARK: exact hits stay

    func testExactQuestionsAsTheRecognizerHeardThemStillHit() async {
        let cases: [(String, [String])] = [
            ("b004", ["What results", "What results did", "What results did Lantern deliver"]),
            ("b013", ["How would you", "How would you approach", "How would you approach building an",
                      "How would you approach building an Elm ass", "How would you approach building an Elm assisted despair?"]),
            ("b007", ["Tell me about the root optimizer you built for the couri", "Tell me about the root optimizer you built for the courier",
                      "Tell me about the root optimizer you built for the courier P", "Tell me about the root optimizer you built for the courier Pil",
                      "Tell me about the root optimizer you built for the courier Pilot", "Tell me about the root optimizer you built for the courier pilot."]),
            ("b022", ["What does eat", "What does eat ad", "What does eat adri", "What does eat adrift", "What does eat adrift mean",
                      "What does eat adrift mean to", "What does eat adrift mean to you"]),
            ("b002", ["Why do you want to join Hald", "Why do you want to join Hald and", "Why do you want to join Hald and Fre",
                      "Why do you want to join Hald and Freight", "Why do you want to join Hald and Freight Systems"]),
            ("b005", ["What", "What is", "What is your", "What is your biggest", "What is your biggest we", "What is your biggest weak"]),
            ("b015", ["When could you", "When could you start", "When could you start if", "When could you start if we made",
                      "When could you start if we made an offer?"]),
            ("b014", ["Do you have", "Do you have any", "Do you have any questions", "Do you have any questions for us?"]),
            ("b018", ["How does your experience relate to what", "How does your experience relate to what we",
                      "How does your experience relate to what we do", "How does your experience relate to what we do in",
                      "How does your experience relate to what we do in root", "How does your experience relate to what we do in root planning?"]),
        ]
        for (id, partials) in cases {
            let got = await hits(partials)
            XCTAssertEqual(got, [id], partials.last!)
        }
    }

    func testItalianExactQuestionsStillHit() async {
        let cases: [(String, [String])] = [
            ("b001", ["Puoi", "Puoi parlarmi", "Puoi parlarmi di te", "Puoi parlarmi di te e", "Puoi parlarmi di te e del tuo",
                      "Puoi parlarmi di te e del tuo percorso"]),
            ("b003", ["you", "you Puoi parlarmi", "you Puoi parlarmi del progetto", "you Puoi parlarmi del progetto L",
                      "you Puoi parlarmi del progetto Lan", "you Puoi parlarmi del progetto Lanter"]),
            ("b015", ["Quando potresti", "Quando potresti iniziare", "Quando potresti iniziare se", "Quando potresti iniziare se ti face",
                      "Quando potresti iniziare se ti facessimo un'o"]),
            ("b005", ["Qual è il tuo", "Qual è il tuo punto", "Qual è il tuo punto de", "Qual è il tuo punto debo",
                      "Qual è il tuo punto debole più grande?"]),
        ]
        for (id, partials) in cases {
            let got = await hits(partials, bank: SampleSession.bankIT, lang: "it")
            XCTAssertEqual(got, [id], partials.last!)
        }
    }

    // MARK: no delay the check does not need (2026-11-12, second pass)

    /// Replay fake-it-after, it03: the name comes last in the Italian question and in the recognizer's next burst, about a
    /// second after "pipel". The query reads the prepared question word for word up to there, so the card does not wait.
    func testItalianCardDoesNotWaitForTheNameWhenTheQuestionIsReadVerbatim() async {
        let accuracy = ["Sì", "Quanto", "Quanto era", "Quanto era acc", "Quanto era curata", "Quanto era curata la",
                        "Quanto era curata la pi", "Quanto era curata la pip", "Quanto era curata la pipel",
                        "Quanto era curata la pipeline di", "Quanto era curata la pipeline di L", "Quanto era curata la pipeline di Lan",
                        "Quanto era curata la pipeline di Lantern"]
        let r = await run(accuracy, bank: SampleSession.bankIT, lang: "it")
        XCTAssertEqual(r.ids, ["b011"])
        XCTAssertEqual(r.at.first, "Quanto era curata la pipel", "the card came with the name, a burst later")
        // it02: a stray word before the question does not stop the word-for-word reading.
        let project = ["you", "you Puoi", "you Puoi parla", "you Puoi parlarmi", "you Puoi parlarmi del", "you Puoi parlarmi del progetto",
                       "you Puoi parlarmi del progetto L", "you Puoi parlarmi del progetto Lan", "you Puoi parlarmi del progetto Lantern"]
        let p = await run(project, bank: SampleSession.bankIT, lang: "it")
        XCTAssertEqual(p.ids, ["b003"])
        XCTAssertEqual(p.at.first, "you Puoi parlarmi del progetto")
    }

    /// A different word before the name still waits for the name: the off-bank question of replay d04 differs from the
    /// paraphrase "How did you measure success on Lantern?" at its second word.
    func testVerbatimReadingNeedsEveryWordBeforeTheName() {
        XCTAssertFalse(BankMatcher.readsVerbatim(BankMatcher.foldedWords("How would you measure success"),
                                                 BankMatcher.foldedWords("How did you measure success on Lantern?")))
        XCTAssertTrue(BankMatcher.readsVerbatim(BankMatcher.foldedWords("How did you measure success on"),
                                                BankMatcher.foldedWords("How did you measure success on Lantern?")))
        XCTAssertTrue(BankMatcher.readsVerbatim(BankMatcher.foldedWords("Why do you want to join H"),
                                                BankMatcher.foldedWords("Why do you want to join Halden Freight Systems?")))
        XCTAssertFalse(BankMatcher.readsVerbatim(BankMatcher.foldedWords("How would you measure success for the dis"),
                                                 BankMatcher.foldedWords("How did you measure success on Lantern?")))
    }

    /// Replay f3-embed, d10: one partial per recognizer result, about 0.56 s apart. The words confirmed b002 on the first
    /// event that had it as the n-gram winner; a second agreeing event cost one result.
    func testWordsThatConfirmTheEntryStandInForTheSecondEvent() async {
        let join = ["Why do you want", "Why do you want to join", "Why do you want to join Hald",
                    "Why do you want to join Halden Freight system", "Why do you want to join Halden Freight systems?"]
        let r = await run(join)
        XCTAssertEqual(r.ids, ["b002"])
        XCTAssertEqual(r.at.first, "Why do you want to join")
        // Same replay, d05: the confirming event was the turn's last one, so the card never came while the turn was open.
        let drift = await run(["What does", "What does eater drift", "What does eater drift mean to you"])
        XCTAssertEqual(drift.at, ["What does eater drift mean to you"])
    }

    /// Replay f3-fresh, d11: "results" is in one b011 paraphrase and "Lantern" in another; no single phrase of b011 says
    /// both, so the two words are not ambiguous and the card does not wait for "deliver".
    func testWordsSpreadOverTwoParaphrasesOfAnotherEntryAreNotAmbiguous() async {
        let r = await run(["What results did L", "What results did Lan", "What results did Lantern", "What results did Lantern del",
                           "What results did Lantern deliver"])
        XCTAssertEqual(r.ids, ["b004"])
        XCTAssertEqual(r.at.first, "What results did Lantern")
    }

    // MARK: a destroyed name

    /// Replay it03: Lantern came back as "l'H". The words before it read the prepared question verbatim.
    func testDestroyedNameDoesNotBlockTheCard() async {
        let heard = ["Che", "Che risultati", "Che risultati ha", "Che risultati ha portato", "Che risultati ha portato l",
                     "Che risultati ha portato l'", "Che risultati ha portato l'H"]
        let r = await run(heard, bank: SampleSession.bankIT, lang: "it")
        XCTAssertEqual(r.ids, ["b004"])
    }

    /// The same turn when the recognizer delivered the destroyed name in the same result as the words before it: nothing
    /// mid-turn reads verbatim ("l'H" is not "Lantern"), so the endpoint check on the finished text sends the card.
    func testEndpointForgivesALostNameAtTheEnd() async {
        let r = await run(["Che", "Che risultati ha portato l'H"], bank: SampleSession.bankIT, lang: "it")
        XCTAssertEqual(r.ids, ["b004"])
        XCTAssertEqual(r.at, ["<end>"])
        // A turn that stops before the name, with no scrap of a lost word, is not the prepared question.
        let generic = await run(["How would you", "How would you measure", "How would you measure success"])
        XCTAssertEqual(generic.ids, [])
        // Nor is one that goes on with words of its own.
        let other = await run(["Che risultati ha portato l'H", "Che risultati ha portato l'H nel dispatching"], bank: SampleSession.bankIT, lang: "it")
        XCTAssertEqual(other.ids, [])
    }

    // MARK: the measure itself

    func testCoverageRules() {
        let m = BankMatcher(bank: SampleSession.bankEN, lang: "en")
        XCTAssertEqual(m.coverage("What results did Lantern deliver", id: "b004"), 1, accuracy: 1e-9)
        // A name in the phrase must be heard: the paraphrase "How did you measure success on Lantern?" is not confirmed by
        // its first words alone.
        XCTAssertEqual(m.coverage("How would you measure success", id: "b004"), 0)
        // One content word is not a question yet.
        XCTAssertEqual(m.coverage("What did the courier", id: "b007"), 0)
        // Words several entries share are ambiguous.
        XCTAssertEqual(m.coverage("Can you tell me about", id: "b003"), 0)
        // A question still being spoken: the phrase words after the last one heard are excused.
        XCTAssertGreaterThanOrEqual(m.coverage("Tell me about the route optimiser you built", id: "b007"), 0.6)
        // ... but not once the speaker went on to other words the bank knows.
        XCTAssertLessThan(m.coverage("Tell me about the route optimiser for live dispatch", id: "b007"), 0.6)
    }

    func testRecognizerSpellingsCountAsTheSameWord() {
        XCTAssertTrue(BankMatcher.wordsMatch("optimizer", "optimiser"))
        XCTAssertTrue(BankMatcher.wordsMatch("weak", "weakness"))       // a word still being spoken
        XCTAssertTrue(BankMatcher.wordsMatch("adrift", "drift"))
        XCTAssertTrue(BankMatcher.wordsMatch("parlami", "parlarmi"))
        XCTAssertFalse(BankMatcher.wordsMatch("root", "route"))
        XCTAssertFalse(BankMatcher.wordsMatch("pil", "pilot"))          // three letters are not a word yet
        XCTAssertFalse(BankMatcher.wordsMatch("elm", "llm"))
    }
}
