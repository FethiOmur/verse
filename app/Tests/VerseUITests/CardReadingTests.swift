import Foundation
import Testing
import VersePrompter
import VerseSpeech
@testable import VerseUI

// The prompter-style answer card: how much of the SAY line he has said, from his own `me` partials (spec 3.2, states 4
// and 5). The matcher is the teleprompter's; these tests pin the wiring and the reset rules.

@MainActor
struct CardReadingTests {
    private let say = "In Lantern, bad invoices never blocked the pipeline — they went to a review queue."

    @Test
    func theSplitCutsAfterTheSpokenWordsAndJoinsBackExactly() {
        let a = SaySplit.split(say, spokenWords: 0)
        #expect(a.spoken == "" && a.rest == say)
        let b = SaySplit.split(say, spokenWords: 6)
        #expect(b.spoken == "In Lantern, bad invoices never blocked ")
        #expect(b.spoken + b.rest == say)
        let all = SaySplit.split(say, spokenWords: 99)
        #expect(all.spoken == say && all.rest == "")
    }

    @Test
    func hisPartialsMoveTheSpokenWordsForward() {
        let reading = CardReading(clock: ManualPrompterClock())
        reading.setSay(say)
        #expect(reading.spoken(for: say) == 0)
        reading.ingest(micEvent("in lantern bad invoices"))
        #expect(reading.spoken(for: say) == 4)
        reading.ingest(micEvent("in lantern bad invoices never blocked the"))
        #expect(reading.spoken(for: say) == 7)
    }

    @Test
    func withoutAMeChannelEverythingStaysUnspoken() {
        let reading = CardReading(clock: ManualPrompterClock())
        reading.setSay(say)
        reading.ingest(micEvent("in lantern bad invoices never blocked", channel: .remote))
        #expect(reading.spoken(for: say) == 0)
    }

    @Test
    func aNewSayStartsUnspokenEvenWhileHeIsStillTalking() {
        let reading = CardReading(clock: ManualPrompterClock())
        reading.setSay(say)
        reading.ingest(micEvent("in lantern bad invoices never"))
        #expect(reading.spoken(for: say) == 5)
        let follow = "And on the route optimiser I built the first pilot on my own, in six weeks."
        reading.setSay(follow)
        #expect(reading.spoken(for: follow) == 0)
        #expect(reading.spoken(for: say) == 0)   // the old line's progress never shows on another text
        // his open partial still contains the old words: they do not count for the new line
        reading.ingest(micEvent("in lantern bad invoices never"))
        #expect(reading.spoken(for: follow) == 0)
        reading.ingest(micEvent("in lantern bad invoices never and on the route"))
        #expect(reading.spoken(for: follow) == 4)
    }

    @Test
    func theSameSayAgainKeepsTheProgress() {
        let reading = CardReading(clock: ManualPrompterClock())
        reading.setSay(say)
        reading.ingest(micEvent("in lantern bad invoices"))
        reading.setSay(say)
        #expect(reading.spoken(for: say) == 4)
    }

    @Test
    func theMeetingTapFeedsTheCardWhateverThePrompterSetting() async {
        let model = PrompterModel(settings: PrompterSettings(defaults: .init(suiteName: "dev.fethiverse.verse.cardreading")!))
        model.settings.followMeetingCards = false
        let tap = model.meetingStarted()
        var card = OverlayCard(turnID: "t1", question: "Walk me through Lantern")
        card.say = say
        model.meetingCard(card)
        tap.ingest(micEvent("in lantern bad invoices never blocked", channel: .remote))
        tap.ingest(micEvent("in lantern bad invoices"))
        #expect(await waitUntil { model.cardReading.spoken(for: say) == 4 })
        model.meetingEnded()
        UserDefaults.standard.removePersistentDomain(forName: "dev.fethiverse.verse.cardreading")
    }

    // MARK: room route (one microphone, its events arrive as `remote`)

    private let roomSay = "I chose this school for its co-op program, and I chose accounting because I like turning messy payment data into a clear story."

    @Test
    func inTheRoomRouteTheMicrophonesRemoteEventsMoveTheCard() {
        let reading = CardReading(clock: ManualPrompterClock())
        reading.roomRoute = true
        reading.setSay(roomSay)
        reading.ingest(micEvent("i chose this school for its co-op program", channel: .remote))
        #expect(reading.spoken(for: roomSay) == 8)
        reading.ingest(micEvent("i chose this school for its co-op program and i chose accounting because i like", channel: .remote))
        #expect(reading.spoken(for: roomSay) >= 14)
    }

    @Test
    func theInterviewersSpeechRarelyMovesIt() {
        let reading = CardReading(clock: ManualPrompterClock())
        reading.roomRoute = true
        reading.setSay(roomSay)
        let interviewer = [
            "one of the big decisions you have made is which university or college to attend",
            "and an equally big if not bigger one is what your major will be",
            "i am interested in why you chose this school and in particular why you chose accounting as a major",   // shares a few words
            "so why did you choose accounting as a major in the end",
            "and what did you do on the co-op placement with the finance team",
        ]
        for text in interviewer {
            reading.ingest(micEvent(text, channel: .remote, final: true))
        }
        #expect(reading.spoken(for: roomSay) == 0, "spoken \(reading.spoken(for: roomSay)) of \(roomSay.split(separator: " ").count)")
        // and when he then reads the card, the count moves from where it was: nothing the interviewer said was held against it
        reading.ingest(micEvent("i chose this school for its co-op program and i chose accounting", channel: .remote))
        #expect(reading.spoken(for: roomSay) == 12)
    }

    /// The measure behind it, on its own: reading with slips passes, a sentence that restates the SAY in order does not.
    @Test
    func theRoomGateTellsReadingFromAQuestionThatSharesWords() {
        #expect(RoomReading.reads("i chose this school for its coop program and chose accounting because i like turning messy payment data in a clear story", say: roomSay))
        #expect(RoomReading.reads("so why did you ask that i chose this school for its co-op program and i chose accounting", say: roomSay), "the tail is what counts")
        #expect(!RoomReading.reads("i am interested in why you chose this school and in particular why you chose accounting as a major", say: roomSay))
        #expect(RoomReading.reads("so you chose this school for the co-op program", say: roomSay), "an interviewer quoting the card's words is read as reading: the limit of a text-only rule")
        #expect(!RoomReading.reads("chose this school", say: roomSay), "fewer than four words prove nothing")
        #expect(RoomReading.aligned(["a", "b", "c"], ["a", "b", "c", "d"]) == 3)
        #expect(RoomReading.aligned(["c", "b", "a"], ["a", "b", "c"]) == 1)
        #expect(RoomReading.aligned(["a", "f"], ["a", "b", "c", "d", "e", "f"]) == 1, "four skipped words start a new path")
    }

    @Test
    func outsideTheRoomTheRemoteChannelNeverCounts() {
        let reading = CardReading(clock: ManualPrompterClock())
        reading.setSay(roomSay)
        reading.ingest(micEvent("i chose this school for its co-op program and i chose accounting", channel: .remote))
        #expect(reading.spoken(for: roomSay) == 0)
    }

    @Test
    func theMeetingTapGivesTheCardEveryEventButThePrompterOnlyHisOwn() async {
        let tap = MeetingMicTap()
        let reading = CardReading(clock: ManualPrompterClock())
        reading.roomRoute = true
        reading.setSay(roomSay)
        reading.connect(tap)
        let prompterStream = tap.stream()
        tap.ingest(micEvent("i chose this school for its co-op program", channel: .remote))
        #expect(await waitUntil { reading.spoken(for: roomSay) == 8 })
        tap.ingest(micEvent("my own words on the prompter", channel: .me))
        var prompterSaw: [String] = []
        for await e in prompterStream { prompterSaw.append(e.text); tap.finish() }
        #expect(prompterSaw == ["my own words on the prompter"], "the prompter never sees the room route's remote events: \(prompterSaw)")
    }

    // MARK: room route: the card read aloud in fragments (live Italian call, 16 Oct)

    private let itSay = "Certo, sono una sviluppatrice backend con un forte focus sul prodotto. Ho trovato che la chiave sia la chiarezza degli obiettivi e il feedback frequente. Il mio ultimo progetto, Harbor Ledger, ha ridotto la chiusura mensile da sei giorni a due."
    private let fragments = ["Certo, sono una sviluppa", "backend con un forte", "focus sul prodotto", "Ho trovato che la chiave", "sia la chiarezza degli obiettivi",
                             "e il feedback frequente", "Il mio ultimo progetto Harbor", "Ledger ha ridotto la chiusura mensile da sei giorni a due"]

    /// A fragment as the recognizer delivers it: partial, then final, each range with its own start time.
    private func deliver(_ text: String, range: Int, to reading: CardReading) {
        let words = text.split(separator: " ")
        for k in stride(from: 2, to: words.count, by: 2) {
            reading.ingest(roomEvent(words[0..<k].joined(separator: " "), start: Double(range), final: false))
        }
        reading.ingest(roomEvent(text, start: Double(range), final: true))
    }

    private func roomEvent(_ text: String, start: Double, final: Bool) -> TranscriptEvent {
        TranscriptEvent(channel: .remote, text: text, isFinal: final, audioStart: start, audioEnd: start + 1, emittedAt: start, lang: "it")
    }

    @Test
    func theCardReadInFragmentsOfTwoToSixWordsMovesTheCursorToTheEnd() {
        let clock = ManualPrompterClock()
        let reading = CardReading(clock: clock)
        reading.roomRoute = true
        reading.setSay(itSay)
        var last = 0
        for (i, frag) in fragments.enumerated() {
            clock.set(Double(i) * 1.5)                         // a silence between two finals, well inside a reading session
            deliver(frag, range: i, to: reading)
            let now = reading.spoken(for: itSay)
            if i < 6 { #expect(now > last, "fragment \(i) \(frag): \(last) -> \(now)") }
            last = max(last, now)
        }
        let total = itSay.split(separator: " ").count
        #expect(reading.spoken(for: itSay) >= total - 3, "spoken \(reading.spoken(for: itSay)) of \(total)")
    }

    @Test
    func theWindowRuleAloneCouldNotMoveOnFragmentsOfThreeOrFourWords() {
        #expect(!RoomReading.reads(fragments[2], say: itSay), "three words")       // fewer than four words prove nothing to the window rule
    }

    @Test
    func aFragmentFromTheMiddleOfTheCardDoesNotStartAReadingAndAnInterviewerQuotingWordsDoesNotMoveIt() {
        let clock = ManualPrompterClock()
        let reading = CardReading(clock: clock)
        reading.roomRoute = true
        reading.setSay(itSay)
        deliver("e che tipo di feedback ha ricevuto dagli utenti del prodotto", range: 0, to: reading)
        #expect(reading.spoken(for: itSay) == 0)
        deliver("la chiarezza degli obiettivi", range: 1, to: reading)       // on the card, but nobody is reading yet
        #expect(reading.spoken(for: itSay) == 0)
        deliver("Certo, sono una sviluppa", range: 2, to: reading)           // the start of the card: reading begins
        #expect(reading.spoken(for: itSay) > 0)
    }

    @Test
    func aReadingSessionEndsAfterFourSecondsOfNoReading() {
        let clock = ManualPrompterClock()
        let reading = CardReading(clock: clock)
        reading.roomRoute = true
        reading.setSay(itSay)
        deliver(fragments[0], range: 0, to: reading)
        clock.set(2.0)
        deliver(fragments[1], range: 1, to: reading)
        let before = reading.spoken(for: itSay)
        clock.set(9.0)                                                        // 7 s of quiet: the session is over
        deliver(fragments[2], range: 2, to: reading)
        #expect(reading.spoken(for: itSay) == before)
    }

    @Test
    func aNewSayResetsTheCursorAndTheSession() {
        let clock = ManualPrompterClock()
        var gate = RoomReadingGate()
        let taken = gate.accepts(roomEvent(fragments[0], start: 0, final: true), say: itSay, now: 0)
        #expect(taken)
        #expect(gate.cursor > 0 && gate.sessionActive(at: 1))
        gate.reset()
        #expect(gate.cursor == 0 && !gate.sessionActive(at: 1))
        _ = clock
    }
}
