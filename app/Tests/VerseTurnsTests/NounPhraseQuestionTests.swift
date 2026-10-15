import XCTest
import VerseTurns

/// Short noun-phrase questions (open item #9, option B): a two or three word turn with no question cue and no "?"
/// ("Notice period") is a question only when it names something the session knows (glossary term, fact, bank phrase).
final class NounPhraseQuestionTests: XCTestCase {
    private let bank = Bank(entries: [
        BankEntry(id: "b001", question: "What is your notice period?", paraphrases: ["en": ["How soon could you start?"]]),
        BankEntry(id: "b002", question: "Is the role remote work or on site?"),
        BankEntry(id: "b003", question: "Tell me about your experience with routing."),
    ])

    private func facts(glossary: [String] = [], names: [String] = []) -> FactIndex {
        FactIndex(
            facts: names.enumerated().map { i, n in
                FactIndex.FactRecord(id: "f\(i)", kind: "name", text: n, value: n, sourceRef: "prep:L\(i)")
            } + [FactIndex.FactRecord(id: "fb", kind: "number", text: "€42K budget", value: "42000", sourceRef: "prep:L9")],
            glossary: glossary.enumerated().map { i, t in
                FactIndex.GlossaryRecord(id: "g\(i)", term: t, line: "", sourceRef: "prep:L\(i)")
            })
    }

    private func kind(_ text: String, terms: SessionTerms?, lang: String = "en") -> TurnKind {
        Cues.kind(of: text, lang: lang, terms: terms)
    }

    // MARK: the glossary decides

    func testNoticePeriodWithTheTermInTheGlossaryIsAQuestion() {
        let terms = SessionTerms(bank: .empty, facts: facts(glossary: ["notice period"]))
        XCTAssertEqual(kind("Notice period", terms: terms), .question)
        XCTAssertEqual(kind("And notice period", terms: terms), .question, "a leader word in front changes nothing")
        XCTAssertEqual(kind("Your notice period", terms: terms), .question)
    }

    func testTheSameTurnWithoutSessionTermsStaysAFragment() {
        XCTAssertEqual(kind("Notice period", terms: nil), .fragment, "today's behaviour")
        XCTAssertEqual(kind("Notice period", terms: .empty), .fragment)
        let other = SessionTerms(bank: .empty, facts: facts(glossary: ["dispatcher"]))
        XCTAssertEqual(kind("Notice period", terms: other), .fragment, "the glossary has other terms")
    }

    func testAcknowledgementsStayNonQuestionsWhateverTheSessionHolds() {
        let terms = SessionTerms(bank: bank, facts: facts(glossary: ["notice period", "great", "thanks"], names: ["Marco"]))
        // Acknowledgements are made of leader words ("okay", "great", "thanks", "sure"): they are never content, even
        // when the pack's glossary happens to hold one of them.
        XCTAssertEqual(kind("Okay great", terms: SessionTerms(bank: bank, facts: facts(glossary: ["notice period"]))), .fragment)
        XCTAssertEqual(kind("Thanks", terms: SessionTerms(bank: bank, facts: facts(glossary: ["notice period"]))), .fragment, "one word")
        XCTAssertEqual(kind("Thank you", terms: SessionTerms(bank: bank, facts: facts(glossary: ["notice period"]))), .fragment)
        XCTAssertEqual(kind("Sure thing", terms: SessionTerms(bank: bank, facts: facts(glossary: ["notice period"]))), .fragment)
        XCTAssertEqual(kind("Pretty good", terms: SessionTerms(bank: bank, facts: facts(glossary: ["notice period"]))), .fragment)
        XCTAssertEqual(kind("Okay great", terms: terms), .fragment, "\"great\" and \"thanks\" are glossary terms in this pack")
        XCTAssertEqual(kind("Thanks Marco", terms: terms), .fragment, "a name alone is an address")
    }

    // MARK: facts

    func testANameAloneIsNotAQuestion() {
        let terms = SessionTerms(bank: .empty, facts: facts(names: ["Marco", "Halden"]))
        XCTAssertEqual(kind("Thanks Marco", terms: terms), .fragment)
        XCTAssertEqual(kind("Hi Halden", terms: terms), .fragment)
    }

    func testANameWithAnotherContentWordIsAQuestion() {
        let terms = SessionTerms(bank: .empty, facts: facts(names: ["Halden"]))
        XCTAssertEqual(kind("Halden culture", terms: terms), .question)
        XCTAssertEqual(kind("And Halden roadmap", terms: terms), .question)
    }

    func testANumberOfTheFactSheetCounts() {
        let terms = SessionTerms(bank: .empty, facts: facts())
        XCTAssertEqual(kind("42K budget", terms: terms), .question)
        XCTAssertEqual(kind("Pretty good", terms: terms), .fragment)
    }

    // MARK: bank phrases

    func testTwoContentWordsFromABankQuestionCount() {
        let terms = SessionTerms(bank: bank, facts: .empty)
        XCTAssertEqual(kind("Notice period", terms: terms), .question, "\"notice period\" is in \"What is your notice period?\"")
        XCTAssertEqual(kind("Remote work", terms: terms), .question)
    }

    func testOneBankWordIsTooCommon() {
        let terms = SessionTerms(bank: bank, facts: .empty)
        XCTAssertEqual(kind("Great experience", terms: terms), .fragment, "\"experience\" alone is in the bank, but it is a compliment here")
        XCTAssertEqual(kind("Very routing", terms: terms), .fragment)
    }

    func testNonAdjacentBankWordsDoNotCount() {
        let terms = SessionTerms(bank: bank, facts: .empty)
        XCTAssertEqual(kind("Notice routing", terms: terms), .fragment)
    }

    // MARK: only short turns are touched

    func testCueAndQuestionMarkRulesAreUnchanged() {
        let terms = SessionTerms(bank: bank, facts: facts(glossary: ["notice period"]))
        XCTAssertEqual(kind("Why Halden", terms: terms), .question)
        XCTAssertEqual(kind("Okay, right?", terms: terms), .fragment, "an acknowledgement with a question mark")
        XCTAssertEqual(kind("Where do", terms: terms), .fragment, "cut off")
        XCTAssertEqual(kind("That sounds great", terms: terms), .statement)
        XCTAssertEqual(kind("Notice period and", terms: terms), .fragment, "ends where a clause cannot end")
    }

    // MARK: the engine

    func testEngineSendsAShortNounPhraseAsAQuestionOnlyWithTheTerm() async {
        let known = TurnEngine(config: TurnConfig(), bank: .empty, facts: facts(glossary: ["notice period"]))
        _ = await known.ingestTimed(ev("Notice period", at: 10.0, start: 9))
        let q = await known.advance(to: 12.0)
        XCTAssertEqual(q.turns.first?.text, "Notice period")
        XCTAssertEqual(q.turnKinds, [.question])

        let unknown = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await unknown.ingestTimed(ev("Notice period", at: 10.0, start: 9))
        let f = await unknown.advance(to: 12.0)
        XCTAssertEqual(f.turnKinds, [.fragment])

        let okay = TurnEngine(config: TurnConfig(), bank: .empty, facts: facts(glossary: ["notice period"]))
        _ = await okay.ingestTimed(ev("Okay great", at: 10.0, start: 9))
        let o = await okay.advance(to: 12.0)
        XCTAssertEqual(o.turnKinds, [.fragment])
    }

    func testTheFragmentHoldIsUnchangedForANounPhraseQuestion() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: facts(glossary: ["notice period"]))
        _ = await engine.ingestTimed(ev("Notice period", at: 10.0, start: 9))
        let early = await engine.advance(to: 11.1)
        XCTAssertTrue(early.turns.isEmpty, "a short question still waits the fragment hold so a continuation can join it")
    }
}
