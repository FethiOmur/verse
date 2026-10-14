import Foundation
import VerseSpeech
import VerseTurns
import XCTest
@testable import VerseTurns

/// Plan F4: statements that come close to a prepared topic surface a `chip{kind:"topic"}` without a brain call.
final class TopicTriggerTests: XCTestCase {

    static let bank = Bank(entries: [
        BankEntry(id: "t001", question: "Can you tell me about the Lantern project?",
                  paraphrases: ["en": ["Walk me through your invoice extraction pipeline.", "Tell us about the LLM project you led."]]),
        BankEntry(id: "t002", question: "What is your biggest weakness?",
                  paraphrases: ["en": ["What's something you're working to improve?", "Tell us about a professional weakness and how you deal with it."]]),
        BankEntry(id: "t003", question: "How do you handle on call incidents at night?",
                  paraphrases: ["en": ["How do you deal with on call incidents at night?"]]),
        BankEntry(id: "t004", question: "When could you start if we made an offer?",
                  paraphrases: ["en": ["What is your notice period?", "What's your earliest start date?"]]),
        BankEntry(id: "t005", question: "What is your experience with Kubernetes deployments?",
                  paraphrases: ["en": ["How have you run production clusters on Kubernetes?"]]),
        BankEntry(id: "t006", question: "What is the longest and most complicated production incident you have ever had to resolve?",
                  paraphrases: ["en": ["Tell us about your most complicated production incident."]]),
    ])

    /// One utterance as the recognizer sends it: two identical volatile results, then time moves past the endpoint so
    /// the turn closes. Returns everything the engine emitted.
    @discardableResult
    private func say(_ engine: TurnEngine, _ text: String, at t: Double, channel: Channel = .remote) async -> [TurnEngine.Timed] {
        var out: [TurnEngine.Timed] = []
        out += await engine.ingestTimed(ev(text, at: t, channel: channel, start: t - 1, end: t))
        out += await engine.ingestTimed(ev(text, at: t + 0.1, channel: channel, start: t - 1, end: t + 0.1))
        out += await engine.advance(to: t + 1.5)
        return out
    }

    private func topicChips(_ events: [TurnEngine.Timed]) -> [String] {
        events.chips.filter { $0.kind == "topic" }.map(\.factID)
    }

    // MARK: statement -> chip

    func testTopicChipOnStatement() async {
        let engine = TurnEngine(config: TurnConfig(), bank: Self.bank, facts: .empty)
        let out = await say(engine, "so the invoice extraction pipeline went live last quarter", at: 1.0)
        XCTAssertEqual(topicChips(out), ["t001"], "one topic chip with the bank id, not repeated by the second identical partial")
        XCTAssertEqual(out.chips.first?.text, "Can you tell me about the Lantern project?")
        XCTAssertTrue(out.bankHits.isEmpty, "a statement at topic level is not a bank hit")
        XCTAssertFalse(out.partials.contains { $0.cue })
        // the chip belongs to the turn that carried the statement
        if let chip = out.first(where: { if case .chip = $0.event { return true } else { return false } }) {
            XCTAssertEqual(chip.event.turnID, "r1")
            XCTAssertEqual(chip.event.typeName, "chip")
            XCTAssertFalse(chip.event.isForBrain)
        }

        // A long bank question is shortened to the label limit. (This statement is close enough to the entry to be a bank
        // hit with the default threshold, which has its own card, so the bank hit is switched off here.)
        let long = TurnEngine(config: TurnConfig(matchThreshold: 0.95), bank: Self.bank, facts: .empty)
        let lout = await say(long, "the longest and most complicated production incident we ever had", at: 1.0)
        XCTAssertEqual(topicChips(lout), ["t006"])
        let label = lout.chips.first?.text ?? ""
        XCTAssertLessThanOrEqual(label.count, 60)
        XCTAssertTrue(label.hasPrefix("What is the longest and most complicated"), label)
        XCTAssertTrue(label.hasSuffix("\u{2026}"), label)

        // A glossary topic in the fact sheet, described without its exact term, gives a topic chip with its id and source.
        let facts = FactIndex(facts: [], glossary: [.init(id: "g001", term: "ETA drift", line: "The gap between promised and actual arrival.", sourceRef: "prep:L37")])
        let g = TurnEngine(config: TurnConfig(), bank: .empty, facts: facts)
        let gout = await say(g, "the gap between the promised arrival and the actual arrival keeps growing", at: 1.0)
        XCTAssertEqual(topicChips(gout), ["g001"])
        XCTAssertEqual(gout.chips.first?.text, "ETA drift: The gap between promised and actual arrival.")
        XCTAssertEqual(gout.chips.first?.ref, "prep:L37")

        // Remote speech about someone else still counts: topics are context, not answers.
        let other = TurnEngine(config: TurnConfig(otherNames: ["Ingrid"]), bank: Self.bank, facts: .empty)
        let oout = await say(other, "Ingrid said the invoice extraction pipeline went live last quarter", at: 1.0)
        XCTAssertEqual(topicChips(oout), ["t001"])
        XCTAssertEqual(oout.turns.first?.addressee, Addressee.other)

        // The owner's own speech never triggers, and unrelated remote speech does not either.
        let mine = TurnEngine(config: TurnConfig(), bank: Self.bank, facts: .empty)
        let mout = await say(mine, "so the invoice extraction pipeline went live last quarter", at: 1.0, channel: .me)
        XCTAssertTrue(topicChips(mout).isEmpty)
        let chatter = TurnEngine(config: TurnConfig(), bank: Self.bank, facts: .empty)
        var cout: [TurnEngine.Timed] = []
        for (i, line) in ["the weather has been really nice this week and we had lunch outside",
                          "yeah the quarterly planning meeting was moved to thursday afternoon",
                          "thanks for joining everyone I think we can start now"].enumerated() {
            cout += await say(chatter, line, at: 1.0 + Double(i) * 20)
        }
        XCTAssertTrue(topicChips(cout).isEmpty, "unrelated chatter: \(topicChips(cout))")
    }

    func testNoTopicChipOnQuestion() async {
        // Control: the statement form of this text gives a chip.
        let statement = TurnEngine(config: TurnConfig(), bank: Self.bank, facts: .empty)
        let sOut = await say(statement, "we described the invoice extraction pipeline to them", at: 1.0)
        XCTAssertEqual(topicChips(sOut), ["t001"])

        // The same topic asked with a question cue: the question path owns it, no topic chip.
        for q in ["can you describe the invoice extraction pipeline to them",
                  "what about the invoice extraction pipeline",
                  "tell me about the invoice extraction pipeline"] {
            let engine = TurnEngine(config: TurnConfig(), bank: Self.bank, facts: .empty)
            let out = await say(engine, q, at: 1.0)
            XCTAssertTrue(out.partials.contains { $0.cue }, "\(q): expected a question cue")
            XCTAssertTrue(topicChips(out).isEmpty, "\(q): \(topicChips(out))")
        }

        // A topic that was part of a question turn does not come back as a chip once the speaker moves on.
        let engine = TurnEngine(config: TurnConfig(), bank: Self.bank, facts: .empty)
        var out = await say(engine, "can you describe the invoice extraction pipeline to them", at: 1.0)
        out += await say(engine, "okay let me share my screen so you can see the numbers for this quarter", at: 4.0)
        XCTAssertTrue(topicChips(out).isEmpty, "\(topicChips(out))")
    }

    // MARK: cooldown

    func testTopicCooldown() async {
        let engine = TurnEngine(config: TurnConfig(), bank: Self.bank, facts: .empty)
        var chips: [String] = []
        // Two hits 5 s apart on different topics: the first one only (one chip per 12 s).
        chips += topicChips(await say(engine, "so the invoice extraction pipeline went live last quarter", at: 1.0))
        chips += topicChips(await say(engine, "our notice period is two months for engineers", at: 6.0))
        XCTAssertEqual(chips, ["t001"])

        // Same id after 2 minutes: still nothing (once per 5 minutes) ...
        chips += topicChips(await say(engine, "so the invoice extraction pipeline went live last quarter", at: 121.0))
        XCTAssertEqual(chips, ["t001"], "the same id inside 5 minutes")

        // ... a topic that has not been shown yet is fine after the cooldown ...
        chips += topicChips(await say(engine, "our notice period is two months for engineers", at: 130.0))
        XCTAssertEqual(chips, ["t001", "t004"])

        // ... and the first one is allowed again after 5 minutes.
        chips += topicChips(await say(engine, "so the invoice extraction pipeline went live last quarter", at: 305.0))
        XCTAssertEqual(chips, ["t001", "t004", "t001"])
    }

    // MARK: rolling window

    func testTopicWindowRolls() async {
        // Evidence for a topic that arrives while the cooldown blocks it stays usable only while it is inside the last 12 s.
        func run(laterAt: Double) async -> [String] {
            let engine = TurnEngine(config: TurnConfig(), bank: Self.bank, facts: .empty)
            var chips: [String] = []
            chips += topicChips(await say(engine, "so the invoice extraction pipeline went live last quarter", at: 1.0))   // chip, cooldown until 13.0
            chips += topicChips(await say(engine, "they run their clusters on kubernetes", at: 2.0))                // blocked by the cooldown
            XCTAssertEqual(chips, ["t001"])
            chips += topicChips(await say(engine, "okay let me share my screen so you can see the numbers for this quarter", at: laterAt))
            return chips
        }
        let fresh = await run(laterAt: 13.4)
        XCTAssertEqual(fresh, ["t001", "t005"], "13.4 s: the Kubernetes sentence (2.0 s) is still inside the 12 s window")
        let stale = await run(laterAt: 16.0)
        XCTAssertEqual(stale, ["t001"], "16 s: the Kubernetes sentence is older than 12 s and no longer counts")
    }

    // MARK: speed

    func testTopicSpeed() async {
        // 120 synthetic entries, a question and three paraphrases each, plus 40 fact / glossary records.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
        let syll = ["ka", "to", "mi", "re", "su", "no", "la", "ve", "pi", "do", "ru", "ne", "sa", "bo", "li", "gu"]
        let vocab: [String] = (0..<260).map { _ in (0..<(2 + next() % 2)).map { _ in syll[next() % syll.count] }.joined() }
        func sentence(_ n: Int) -> String { (0..<n).map { _ in vocab[next() % vocab.count] }.joined(separator: " ") }
        let entries = (0..<120).map { i in
            BankEntry(id: String(format: "b%03d", i + 1), question: sentence(9) + "?", paraphrases: ["en": [sentence(8), sentence(10), sentence(7)]])
        }
        let facts = FactIndex(
            facts: (0..<20).map { .init(id: String(format: "f%03d", $0), kind: "name", text: sentence(8), value: vocab[$0], sourceRef: "prep:L\($0)") },
            glossary: (0..<20).map { .init(id: String(format: "g%03d", $0), term: vocab[100 + $0], line: sentence(6), sourceRef: "prep:G\($0)") })
        // No cooldown and no id memory: every partial runs the whole topic path (the worst case). Bank hits are off
        // (matchThreshold 2.0) so that the chip is the only thing a partial can add; the bank matching itself still runs.
        // The machine running the tests is shared and loaded, so the rounds of the two engines (topic off / on) alternate
        // and the best round counts: a real cost shows in every round, scheduler noise only in some.
        final class Run {
            let engine: TurnEngine
            var t = 1.0
            var rng: UInt64
            var p99s: [Double] = []
            var all: [Double] = []
            let vocab: [String]
            init(_ config: TurnConfig, bank: Bank, facts: FactIndex, vocab: [String], seed: UInt64) {
                engine = TurnEngine(config: config, bank: bank, facts: facts)
                self.vocab = vocab
                rng = seed
            }
            func nextWord() -> Int { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Int(rng >> 33) }
            func round() async {
                let clock = ContinuousClock()
                var times: [Double] = []
                for i in 0..<120 {
                    // a growing 12-word utterance, three words per partial, then a gap
                    let words = (0..<12).map { _ in vocab[nextWord() % vocab.count] }
                    for n in stride(from: 3, through: 12, by: 3) {
                        let event = ev(words.prefix(n).joined(separator: " "), at: t, start: t - 1, end: t)
                        var out: [TurnEngine.Timed] = []
                        let d = await clock.measure { out = await engine.ingestTimed(event) }
                        _ = out
                        times.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
                        t += 0.1
                    }
                    _ = await engine.advance(to: t + 1.0)
                    t += 3.0 + (i % 2 == 0 ? 0 : 0.5)
                }
                all += times
                times.sort()
                p99s.append(times[Int(Double(times.count - 1) * 0.99)])
            }
            var p50: Double { all.sorted()[all.count / 2] }
        }
        let bank = Bank(entries: entries)
        let off = Run(TurnConfig(matchThreshold: 2.0, topicEnabled: false), bank: bank, facts: facts, vocab: vocab, seed: seed)
        let on = Run(TurnConfig(matchThreshold: 2.0, topicCooldownSeconds: 0, topicSameIDSeconds: 0), bank: bank, facts: facts, vocab: vocab, seed: seed)
        for _ in 0..<6 {
            await off.round()
            await on.round()
        }
        func fmt(_ x: [Double]) -> String { x.map { String(format: "%.2f", $0) }.joined(separator: " ") }
        print("[testTopicSpeed] 6 rounds x 480 partials, 120 bank entries + 40 fact/glossary, debug build, loaded machine. topic off: p50 \(String(format: "%.2f", off.p50)) ms, round p99s [\(fmt(off.p99s))] | topic on: p50 \(String(format: "%.2f", on.p50)) ms, round p99s [\(fmt(on.p99s))]")
        // A whole partial through the engine costs what it costs on this machine right now; what the topic path adds to
        // it must stay under 5 ms at p99 (best round of each, same load).
        let bestOn = on.p99s.min() ?? .infinity, bestOff = off.p99s.min() ?? .infinity
        XCTAssertLessThan(bestOn, bestOff + 5, "topic path adds too much: best round p99 on \(bestOn) ms vs off \(bestOff) ms")

        // The topic path alone, cold: every partial is new text, so nothing comes from the memo. Best of 8 rounds.
        let cache = MatchCache(BankMatcher(bank: bank, lang: "en"))
        var trigger = TopicTrigger(config: TurnConfig(topicCooldownSeconds: 0, topicSameIDSeconds: 0), bank: bank, bankMatches: cache, facts: facts)
        let clock = ContinuousClock()
        var direct: [Double] = []
        var dt = 1.0
        var rng: UInt64 = 0x1234_5678_9ABC_DEF1
        for _ in 0..<8 {
            var times: [Double] = []
            for _ in 0..<120 {
                let words = (0..<12).map { _ -> String in rng = rng &* 6364136223846793005 &+ 1442695040888963407; return vocab[Int(rng >> 33) % vocab.count] }
                for n in stride(from: 3, through: 12, by: 3) {
                    let piece = TopicTrigger.Piece(at: dt, text: words.prefix(n).joined(separator: " "))
                    let d = clock.measure { _ = trigger.evaluate(now: dt, current: [piece], skip: []) }
                    times.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
                    dt += 0.1
                }
                trigger.noteClosed([TopicTrigger.Piece(at: dt, text: words.joined(separator: " "))], now: dt)
                dt += 3
            }
            times.sort()
            direct.append(times[Int(Double(times.count - 1) * 0.99)])
        }
        print("[testTopicSpeed] topic path alone, cold, 120 bank entries + 40 fact/glossary: round p99s [\(fmt(direct))] ms")
        XCTAssertLessThan(direct.min() ?? .infinity, 5, "topic path p99 \(direct)")
        let engine = on.engine
        var t = on.t

        // The loop above must have exercised a working trigger: an exact paraphrase of an entry gives its chip.
        t += 30
        let probe = entries[57].paraphrases["en"]![1]
        let out = await engine.ingestTimed(ev(probe, at: t, start: t - 1, end: t))
        XCTAssertEqual(out.chips.filter { $0.kind == "topic" }.first?.factID, entries[57].id)
    }
}
