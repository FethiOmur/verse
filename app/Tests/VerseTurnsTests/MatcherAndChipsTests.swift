import Foundation
import VerseSpeech
import VerseTurns
import XCTest

final class MatcherAndChipsTests: XCTestCase {

    static let bank = Bank(entries: [
        BankEntry(id: "b001", question: "Can you tell me about the Lantern project?",
                  paraphrases: ["en": ["What was Lantern and what did it do?", "Walk me through your invoice extraction pipeline.", "Tell us about the LLM project you led."]]),
        BankEntry(id: "b002", question: "What results did Lantern deliver?",
                  paraphrases: ["en": ["What was the impact of your invoice project?", "How did you measure success on Lantern?", "What numbers can you share from your best project?"]]),
        BankEntry(id: "b003", question: "What is your biggest weakness?",
                  paraphrases: ["en": ["What's something you're working to improve?", "Tell us about a professional weakness and how you deal with it."]]),
        BankEntry(id: "b004", question: "When could you start if we made an offer?",
                  paraphrases: ["en": ["What is your notice period?", "What's your earliest start date?"]]),
        // two near-duplicates: neither may win on its own
        BankEntry(id: "b010", question: "How do you handle on call incidents at night?", paraphrases: ["en": ["How do you deal with on call incidents at night?"]]),
        BankEntry(id: "b011", question: "How do you handle on call incidents on weekends?", paraphrases: ["en": ["How do you deal with on call incidents on weekends?"]]),
    ])

    func testMatcherHitAndMargin() async {
        let engine = TurnEngine(config: TurnConfig(), bank: Self.bank, facts: .empty)

        // A paraphrase: a hit on the right entry once two consecutive events agree (not on the first).
        let e1 = await engine.ingestTimed(ev("what was the impact of your invoice project", at: 1.0))
        XCTAssertTrue(e1.bankHits.isEmpty, "one event is not enough")
        let e2 = await engine.ingestTimed(ev("what was the impact of your invoice project", at: 1.1))
        XCTAssertEqual(e2.bankHits.count, 1)
        XCTAssertEqual(e2.bankHits.first?.bank, "b002")
        XCTAssertEqual(e2.bankHits.first?.id, "r1")
        XCTAssertGreaterThanOrEqual(e2.bankHits.first?.score ?? 0, 0.55)
        let e3 = await engine.ingestTimed(ev("what was the impact of your invoice project", at: 1.15))
        XCTAssertTrue(e3.bankHits.isEmpty, "the same hit is not repeated")
        _ = await engine.advance(to: 3.0)

        // Two near-duplicate entries: no hit, however often the partial repeats (margin).
        let engine2 = TurnEngine(config: TurnConfig(), bank: Self.bank, facts: .empty)
        var hits: [TurnEngine.Timed] = []
        for i in 0..<4 { hits += await engine2.ingestTimed(ev("how do you handle on call incidents", at: 1.0 + Double(i) * 0.1)) }
        XCTAssertTrue(hits.bankHits.isEmpty, "near-duplicate candidates must not produce a hit")

        // A single noisy partial that happens to look like an entry, then something else: no hit.
        let engine3 = TurnEngine(config: TurnConfig(), bank: Self.bank, facts: .empty)
        var noisy: [TurnEngine.Timed] = []
        noisy += await engine3.ingestTimed(ev("what is your biggest week", at: 1.0, start: 0, end: 1.0))
        noisy += await engine3.ingestTimed(ev("what is your biggest week end plan for the trip", at: 1.1, start: 0, end: 1.1))
        noisy += await engine3.ingestTimed(ev("what is your biggest week end plan for the trip to the mountains", at: 1.2, start: 0, end: 1.2))
        XCTAssertTrue(noisy.bankHits.isEmpty, "a single matching partial is not sustained")

        // Unrelated speech: nothing.
        let engine4 = TurnEngine(config: TurnConfig(), bank: Self.bank, facts: .empty)
        var none: [TurnEngine.Timed] = []
        for i in 0..<3 { none += await engine4.ingestTimed(ev("the weather has been really nice this week", at: 1.0 + Double(i) * 0.1)) }
        XCTAssertTrue(none.bankHits.isEmpty)
    }

    func testMatcherPartialQuestionGrowsIntoAHit() async {
        let engine = TurnEngine(config: TurnConfig(), bank: Self.bank, facts: .empty)
        var all: [TurnEngine.Timed] = []
        let growth = ["What results", "What results did", "What results did Lantern", "What results did Lantern deliver"]
        for (i, t) in growth.enumerated() { all += await engine.ingestTimed(ev(t, at: 1.0 + Double(i) * 0.1)) }
        XCTAssertFalse(all.bankHits.isEmpty)
        XCTAssertEqual(all.bankHits.last?.bank, "b002")
    }

    func testMatcherSpeed() {
        // 120 synthetic entries, a question and three paraphrases each, from a seeded vocabulary.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
        let syll = ["ka", "to", "mi", "re", "su", "no", "la", "ve", "pi", "do", "ru", "ne", "sa", "bo", "li", "gu"]
        let vocab: [String] = (0..<260).map { _ in (0..<(2 + next() % 2)).map { _ in syll[next() % syll.count] }.joined() }
        func sentence(_ n: Int) -> String { (0..<n).map { _ in vocab[next() % vocab.count] }.joined(separator: " ") }
        let entries = (0..<120).map { i in
            BankEntry(id: String(format: "b%03d", i + 1), question: sentence(9) + "?",
                      paraphrases: ["en": [sentence(8), sentence(10), sentence(7)]])
        }
        let matcher = BankMatcher(bank: Bank(entries: entries), lang: "en")
        var queries = entries.flatMap { [$0.question, $0.paraphrases["en"]![0]] }
        queries += (0..<40).map { _ in sentence(12) }
        var times: [Double] = []
        let clock = ContinuousClock()
        for q in queries {
            let d = clock.measure { _ = matcher.top2(q) }
            times.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        }
        times.sort()
        let p50 = times[times.count / 2], p99 = times[Int(Double(times.count - 1) * 0.99)]
        print(String(format: "[testMatcherSpeed] %d queries over 120 entries: p50 %.3f ms, p99 %.3f ms, max %.3f ms", times.count, p50, p99, times.last ?? 0))
        XCTAssertLessThan(p99, 20, "match time p99 \(p99) ms")
        // sanity: an exact paraphrase finds its entry
        let probe = entries[57].paraphrases["en"]![1]
        XCTAssertEqual(matcher.top2(probe).first?.id, entries[57].id)
    }

    func testBankLoadsFromSessionFolder() throws {
        let s = try TempSession(bank: [("b001", "What results did Lantern deliver?", ["How did Lantern do?"]),
                                       ("b002", "What is your biggest weakness?", [])])
        defer { s.delete() }
        let bank = try Bank.load(sessionDir: s.dir)
        XCTAssertEqual(bank.entries.map(\.id), ["b001", "b002"])
        XCTAssertEqual(bank.entries[0].paraphrases["en"], ["How did Lantern do?"])
        XCTAssertEqual(BankMatcher(bank: bank, lang: "en").top2("what results did lantern deliver").first?.id, "b001")
    }

    // MARK: chips

    static let facts = FactIndex(
        facts: [
            .init(id: "f001", kind: "number", text: "The Compass budget is 42K euros.", value: "42000", sourceRef: "prep:L9"),
            .init(id: "f002", kind: "name", text: "Compass is Halden's re-planning product.", value: "Compass", sourceRef: "prep:L10"),
            .init(id: "f003", kind: "date", text: "The interview is on 22 October.", value: "2026-10-22", sourceRef: "prep:L3"),
            .init(id: "f004", kind: "name", text: "Ingrid Solberg is the VP Engineering.", value: "Ingrid Solberg", sourceRef: "prep:L4"),
            .init(id: "f005", kind: "number", text: "Lantern cut entry time to 2 minutes.", value: "2", sourceRef: "prep:L14"),
            .init(id: "f006", kind: "number", text: "Accuracy was 96.4 percent.", value: "96.4", sourceRef: "prep:L18"),
        ],
        glossary: [.init(id: "g001", term: "ETA drift", line: "The gap between promised and actual arrival.", sourceRef: "prep:L37")])

    func testFactChips() async {
        let chips = Self.facts.chips(in: "what was the 42K budget for Compass")
        XCTAssertEqual(chips.map(\.id), ["f001", "f002"])
        XCTAssertEqual(chips.map(\.kind), ["number", "name"])
        XCTAssertEqual(chips.map(\.sourceRef), ["prep:L9", "prep:L10"])

        // the same number written the other ways
        XCTAssertEqual(Self.facts.chips(in: "a 42,000 euro budget").map(\.id), ["f001"])
        XCTAssertEqual(Self.facts.chips(in: "a 42000 euro budget").map(\.id), ["f001"])
        XCTAssertEqual(Self.facts.chips(in: "forty two k").map(\.id), [], "spelled-out numbers are not matched")
        XCTAssertEqual(Self.facts.chips(in: "accuracy of 96.4 percent").map(\.id), ["f006"])
        // whole word, case-insensitive; a longer word that merely contains the name is not a hit
        XCTAssertEqual(Self.facts.chips(in: "COMPASS is great").map(\.id), ["f002"])
        XCTAssertEqual(Self.facts.chips(in: "the compasses were old").map(\.id), [])
        // 420000 is not 42000; a bare small number is too ambiguous to chip
        XCTAssertEqual(Self.facts.chips(in: "about 420000 and 2 more").map(\.id), [])
        // full names and first names; terms and dates
        XCTAssertEqual(Self.facts.chips(in: "did Ingrid Solberg join").map(\.id), ["f004"])
        XCTAssertEqual(Self.facts.chips(in: "is Ingrid there").map(\.id), ["f004"])
        XCTAssertEqual(Self.facts.chips(in: "what does eta drift mean").map(\.id), ["g001"])
        XCTAssertEqual(Self.facts.chips(in: "on the 22nd of October").map(\.id), ["f003"])
        XCTAssertEqual(Self.facts.chips(in: "October 22").map(\.id), ["f003"])

        // through the engine: one chip per fact per turn, in the partial that first contains it
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: Self.facts)
        var out: [TurnEngine.Timed] = []
        out += await engine.ingestTimed(ev("what was the 42K", at: 1.0))
        out += await engine.ingestTimed(ev("what was the 42K budget for Compass", at: 1.1))
        out += await engine.ingestTimed(ev("what was the 42K budget for Compass again", at: 1.2))
        XCTAssertEqual(out.chips.map(\.factID), ["f001", "f002"])
        XCTAssertEqual(out.chips.map(\.ref), ["prep:L9", "prep:L10"])
        XCTAssertEqual(out.chips.map(\.kind), ["number", "name"])
        // the number chip appeared in the first partial that had it
        XCTAssertEqual(out.firstIndex { if case .chip(_, _, _, _, let f) = $0.event { return f == "f001" } else { return false } }, 1)
    }

    func testFactsLoadFromSessionFolder() throws {
        let s = try TempSession(
            facts: ["{\"id\":\"f001\",\"kind\":\"number\",\"text\":\"38,000 invoices a month\",\"value\":\"38000\",\"sources\":[{\"kind\":\"prep\",\"ref\":\"prep:L14\",\"quote\":\"x\"}]}",
                    "{\"id\":\"f002\",\"kind\":\"name\",\"text\":\"Lantern project\",\"value\":\"Lantern\",\"sources\":[{\"kind\":\"prep\",\"ref\":\"prep:L13\",\"quote\":\"x\"}]}"],
            glossary: ["{\"id\":\"g001\",\"term\":\"Compass\",\"line\":\"Halden's product.\",\"sources\":[{\"kind\":\"prep\",\"ref\":\"prep:L9\",\"quote\":\"x\"}]}"])
        defer { s.delete() }
        let idx = try FactIndex.load(sessionDir: s.dir)
        XCTAssertEqual(idx.chips(in: "38K invoices for Lantern and Compass").map(\.id), ["f001", "f002", "g001"])
        XCTAssertEqual(idx.chips(in: "38K invoices for Lantern and Compass").last?.sourceRef, "prep:L9")
    }
}
