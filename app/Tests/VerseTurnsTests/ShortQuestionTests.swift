import XCTest
import VerseTurns

/// Short remote turns (fewer than `minTurnWords` words): a complete short question is a question, not a fragment.
/// The eval (docs/eval-report-v1.md, d13) lost 3 of 6 two-word questions to the fragment guard.
final class ShortQuestionTests: XCTestCase {
    private func kind(_ text: String, lang: String = "en") -> TurnKind { Cues.kind(of: text, lang: lang) }

    // MARK: short questions are questions

    func testWhyHaldenIsAQuestion() {
        XCTAssertEqual(kind("Why Halden?"), .question)
        XCTAssertEqual(kind("Why Halden"), .question, "the recognizer emits no question mark")
    }

    func testAndSalaryIsAQuestion() {
        XCTAssertEqual(kind("And salary?"), .question)
    }

    func testAnyQuestionsIsAQuestion() {
        XCTAssertEqual(kind("Any questions?"), .question)
        XCTAssertEqual(kind("Any questions"), .question)
        XCTAssertEqual(kind("So, any questions"), .question)
        XCTAssertEqual(kind("Any questions for us"), .question, "four words: the cue itself was missing")
    }

    func testImperativeAskIsAQuestion() {
        XCTAssertEqual(kind("Describe Lantern"), .question)
        XCTAssertEqual(kind("Describe Lantern."), .question)
    }

    func testQuestionMarkAloneMakesAShortQuestion() {
        XCTAssertEqual(kind("Notice period?"), .question)
    }

    /// Nemotron spelled "Why Halden?" as "Y Halden" in the recorded d13 run.
    func testRecognizerSpellingOfWhy() {
        XCTAssertEqual(kind("Y Halden"), .question)
    }

    func testShortAuxiliaryFirstQuestion() {
        XCTAssertEqual(kind("Remote work?"), .question)
        XCTAssertEqual(kind("Is it remote"), .question)   // three words: unchanged by this change
    }

    // MARK: cut-off and non-questions stay fragments

    func testWhereDoYouIsAFragment() {
        XCTAssertEqual(kind("Where do you"), .fragment)
        XCTAssertEqual(kind("Where do"), .fragment, "an auxiliary is not a complete ending")
        XCTAssertEqual(kind("Can you"), .fragment)
    }

    func testShortTurnEndingInAPrepositionOrConjunctionStaysAFragment() {
        XCTAssertEqual(kind("Work in"), .fragment)
        XCTAssertEqual(kind("Team you work in"), .fragment, "…work in")
        XCTAssertEqual(kind("And the"), .fragment)
        XCTAssertEqual(kind("Why the"), .fragment)
        XCTAssertEqual(kind("And you"), .fragment)
        XCTAssertEqual(kind("What about"), .fragment)
    }

    func testCutOffPrefixesStayFragments() {
        XCTAssertEqual(kind("Why this"), .fragment, "prefix of \"Why this company\"")
        XCTAssertEqual(kind("How big"), .fragment, "prefix of \"How big is the team\"")
        XCTAssertEqual(kind("How many"), .fragment)
        XCTAssertEqual(kind("Why um"), .fragment)
    }

    func testOkayStaysAsToday() {
        XCTAssertEqual(kind("Okay."), .fragment)
        XCTAssertEqual(kind("Thanks"), .fragment)
        XCTAssertEqual(kind("Sure thing."), .fragment)
        XCTAssertEqual(kind("Okay, right?"), .fragment, "only leader words before the question mark")
        XCTAssertEqual(kind("Sure?"), .fragment, "one word")
        XCTAssertEqual(kind("Thank you"), .fragment)
    }

    func testShortTurnWithoutAnyCueStaysAFragment() {
        XCTAssertEqual(kind("Notice period"), .fragment, "no cue and no question mark")
        XCTAssertEqual(kind("Pretty good"), .fragment)
    }

    func testLongerTurnsAreUnchanged() {
        XCTAssertEqual(kind("That sounds great"), .statement)
        XCTAssertEqual(kind("We shipped it and we"), .fragment)
        XCTAssertEqual(kind("I don't have any questions"), .statement, "\"any questions\" only counts at the start of a clause")
    }

    // MARK: other languages keep their own cues

    func testItalianAndTurkishUseTheirExistingCues() {
        XCTAssertEqual(kind("Perché Halden", lang: "it"), .question)
        XCTAssertEqual(kind("Ho lavorato", lang: "it"), .fragment)
        XCTAssertEqual(kind("Perché il", lang: "it"), .fragment)
        XCTAssertEqual(kind("Halden mı", lang: "tr"), .question)
        XCTAssertEqual(kind("Çok iyi", lang: "tr"), .fragment)
    }

    // MARK: endpoint timing is untouched

    /// A short question still waits the fragment hold (1.2 s) so that "Why this" + a pause + "company" is one turn;
    /// only the kind on the wire changes.
    func testShortQuestionKeepsTheFragmentHold() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await engine.ingestTimed(ev("Why Halden", at: 10.0, start: 9))
        let early = await engine.advance(to: 11.1)
        XCTAssertTrue(early.turns.isEmpty, "a short question closed after only 1.1 s")
        let due = await engine.advance(to: 11.25)
        XCTAssertEqual(due.turns.first?.at ?? 0, 11.2, accuracy: 0.05)
        XCTAssertEqual(due.turns.first?.text, "Why Halden")
        XCTAssertEqual(due.turnKinds, [.question])
    }

    func testCutOffPrefixStillJoinsItsContinuation() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await engine.ingestTimed(ev("Why this", at: 3.0, final: true, start: 0, end: 2.0))
        let out = await engine.ingestTimed(ev("company", at: 3.9, start: 2.8, end: 3.8))
        XCTAssertTrue(out.turns.isEmpty, "the prefix was split off: \(out.turns.map(\.text))")
        let end = await engine.advance(to: 5.0)
        XCTAssertEqual(end.turns.first?.text, "Why this company")
        XCTAssertEqual(end.turnKinds, [.question])
    }
}
