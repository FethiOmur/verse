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

    // MARK: room route: cumulative partials of one range, 17 Oct (live English call: the highlight stopped mid-sentence)

    private let enSay = "I am a data analyst who builds reporting tools for small logistics teams, most recently a dashboard called Pier Ledger."

    @Test
    func aRevisedPartialOfTheSameRangeKeepsMovingTheHighlight() {
        let clock = ManualPrompterClock()
        let reading = CardReading(clock: clock)
        reading.roomRoute = true
        reading.setSay(enSay)
        // the recognizer revises the opening between two partials of ONE range (same start time): the second is not an extension of the first
        reading.ingest(roomEvent("I am a data analyst who builds", start: 0, final: false))
        let first = reading.spoken(for: enSay)
        #expect(first >= 6, "spoken \(first)")
        // 12 words, 8 of them on the line (0.67): under the start rule's 0.75 and the window rule's 0.7, and the cursor is already past
        // where this text begins, so only "this range is already his" can take it
        reading.ingest(roomEvent("well I'm a um data analyst you who builds reporting tools", start: 0, final: false))
        #expect(reading.spoken(for: enSay) >= 9, "spoken \(reading.spoken(for: enSay))")
        reading.ingest(roomEvent("well I'm a um data analyst you who builds reporting tools for small logistics teams", start: 0, final: true))
        #expect(reading.spoken(for: enSay) >= 12, "spoken \(reading.spoken(for: enSay))")
    }

    @Test
    func theGateStaysOnOnceTheRangeIsHisAndLetsGoBelowTheExitShare() {
        var gate = RoomReadingGate()
        let entered = gate.accepts(roomEvent("I am a data", start: 0, final: false), say: enSay, now: 0)
        let stayed = gate.accepts(roomEvent("I am a data uh well analyst you know who builds", start: 0, final: false), say: enSay, now: 0.3)
        #expect(entered)
        #expect(stayed, "10 words, 7 on the line")
        // the same range now carries somebody else's question: under 60 % of it is on the path
        let left = gate.accepts(roomEvent("I am a data uh well analyst you know who builds and what did you do before that in your last role", start: 0, final: false), say: enSay, now: 0.6)
        #expect(!left)
    }

    @Test
    func aBankCardsOpenerIsTheSayLineAndFollowsFragments() {
        let opener = "Sure, I'll give you the short version of my background."          // the P card: the bank entry's opener is the card's SAY
        let reading = CardReading(clock: ManualPrompterClock())
        reading.roomRoute = true
        reading.setSay(opener)
        reading.ingest(roomEvent("Sure I'll give you", start: 0, final: true))
        #expect(reading.spoken(for: opener) >= 4)
        reading.ingest(roomEvent("the short version of", start: 1, final: true))
        #expect(reading.spoken(for: opener) >= 7)
    }

    // MARK: re-anchoring anywhere on the card (twin: brain/tests/test_runtime_reanchor.py)

    private let s1 = "I built the invoice pipeline at Lantern."                                    // words 0..<7
    private let s2 = "Bad invoices never blocked the pipeline, they went to a review queue."      // words 7..<19
    private let s3 = "Then I moved to the route optimiser project."                               // words 19..<27
    private let p1 = "The first pilot shipped in six weeks."
    private let p2 = "Routing costs dropped by eleven percent."
    private var anchorSay: String { "\(s1) \(s2) \(s3)" }

    private func anchorReading(roomRoute: Bool = false) -> CardReading {
        let reading = CardReading(clock: ManualPrompterClock())
        reading.roomRoute = roomRoute
        reading.setSay(anchorSay)
        reading.setPoints([p1, p2])
        return reading
    }

    private func enEvent(_ text: String, start: Double, channel: Channel = .me, final: Bool = true) -> TranscriptEvent {
        TranscriptEvent(channel: channel, text: text, isFinal: final, audioStart: start, audioEnd: start + 1, emittedAt: start, lang: "en")
    }

    /// Reads `texts` as finals of their own ranges, one per second.
    private func read(_ texts: [String], on reading: CardReading, channel: Channel = .me, from start: Double = 0) {
        for (k, text) in texts.enumerated() { reading.ingest(enEvent(text, start: start + Double(k), channel: channel)) }
    }

    @Test(arguments: [Channel.me, Channel.remote])
    func skippingASentenceAheadAnchorsThereAndStrikesNothingItSkipped(channel: Channel) {
        let reading = anchorReading(roomRoute: channel == .remote)
        read([s1], on: reading, channel: channel)
        #expect(reading.struckWords(for: anchorSay) == IndexSet(integersIn: 0..<7))
        read([s3], on: reading, channel: channel, from: 1)
        let struck = reading.struckWords(for: anchorSay)
        #expect(struck.intersection(IndexSet(integersIn: 7..<19)).isEmpty, "the skipped sentence stays unstruck: \(struck)")
        #expect(struck.isSuperset(of: IndexSet(integersIn: 19..<26)), "the sentence he read is struck: \(struck)")
        #expect(reading.trackerWord >= 26)
    }

    @Test(arguments: [Channel.me, Channel.remote])
    func reReadingTheFirstLineAfterTheSecondAnchorsBackAndUnstrikesNothing(channel: Channel) {
        let reading = anchorReading(roomRoute: channel == .remote)
        read([s1, s2], on: reading, channel: channel)
        #expect(reading.struckWords(for: anchorSay) == IndexSet(integersIn: 0..<19))
        #expect(reading.readingCursor == 19 && reading.trackerWord >= 18)       // 19 words, 19 tokens
        read([s1], on: reading, channel: channel, from: 2)
        #expect(reading.readingCursor == 7, "cursor moved back: \(reading.readingCursor)")
        #expect(reading.trackerWord >= 6 && reading.trackerWord <= 8, "the word tracker is back on the first line: \(reading.trackerWord)")
        #expect(reading.struckWords(for: anchorSay) == IndexSet(integersIn: 0..<19), "nothing is un-struck")
        // and from there he goes on: the second sentence continues the moved cursor
        read([s2], on: reading, channel: channel, from: 3)
        #expect(reading.readingCursor == 19)
    }

    @Test(arguments: [Channel.me, Channel.remote])
    func startingFromTheSecondPointAnchorsToItWithoutTouchingTheSayLine(channel: Channel) {
        let reading = anchorReading(roomRoute: channel == .remote)
        read([s1], on: reading, channel: channel)
        let before = reading.readingCursor
        read([p2], on: reading, channel: channel, from: 1)
        let card = ReadingCard(lines: [anchorSay, p1, p2])
        #expect(reading.readingCursor == card.tokens.count, "cursor at the end of the second point: \(reading.readingCursor) of \(card.tokens.count)")
        #expect(reading.readingCursor > before)
        #expect(reading.struckWords(for: anchorSay) == IndexSet(integersIn: 0..<7), "the SAY line is untouched")
        read([p1], on: reading, channel: channel, from: 2)
        #expect(reading.readingCursor == card.tokens.count - RoomReading.words(p2).count, "and back to the first point")
    }

    @Test
    func aQuestionFromTheOtherSideSharingTwoOrThreeCardWordsIsNotHisAndMovesNothing() {
        let reading = anchorReading(roomRoute: true)
        read([s1], on: reading, channel: .remote)
        let cursor = reading.readingCursor, struck = reading.struckWords(for: anchorSay), tracker = reading.trackerWord
        let questions = [
            "Can you tell me more about how bad invoices ended up in the review process",       // bad invoices ... review
            "What was the hardest part of the route you chose for the optimiser",                 // route, optimiser
            "And how long did the pilot take, six weeks or more",                                   // pilot, six, weeks
        ]
        let card = ReadingCard(lines: [anchorSay, p1, p2])
        for (k, q) in questions.enumerated() {
            let event = enEvent(q, start: 10 + Double(k), channel: .remote)
            var gate = RoomReadingGate()
            gate.observe(event)
            #expect(gate.anchor(for: event, card: card) == nil, Comment(rawValue: q))
            let accepted = gate.accepts(event, say: anchorSay, now: 10)
            #expect(!accepted, Comment(rawValue: "not his: \(q)"))
            reading.ingest(event)
        }
        #expect(reading.readingCursor == cursor && reading.struckWords(for: anchorSay) == struck && reading.trackerWord == tracker)
    }

    /// The room route's gate lets none of it through. On his own channel the word tracker alone takes whatever he says (it creeps forward
    /// on off-script speech, as before); what a single word must never do there is re-anchor: no jump, nothing un-struck.
    @Test(arguments: [Channel.me, Channel.remote])
    func aSingleMatchingWordNeverMovesTheCursor(channel: Channel) {
        let reading = anchorReading(roomRoute: channel == .remote)
        read([s1, s2], on: reading, channel: channel)
        let cursor = reading.readingCursor, struck = reading.struckWords(for: anchorSay)
        let card = ReadingCard(lines: [anchorSay, p1, p2])
        for (k, text) in ["pipeline", "queue", "we talked about the pipeline yesterday during lunch", "Lantern", "sure, six"].enumerated() {
            let event = enEvent(text, start: 20 + Double(k), channel: channel)
            var gate = RoomReadingGate()
            gate.observe(event)
            #expect(gate.anchor(for: event, card: card) == nil, Comment(rawValue: text))
            reading.ingest(event)
            if channel == .remote {
                #expect(reading.readingCursor == cursor && reading.struckWords(for: anchorSay) == struck, Comment(rawValue: text))
            } else {
                #expect(reading.readingCursor >= cursor && reading.struckWords(for: anchorSay).isSuperset(of: struck), Comment(rawValue: text))
            }
        }
    }

    @Test
    func functionWordsDoNotCountTowardTheThreshold() {
        let card = ReadingCard(lines: [anchorSay, p1, p2])
        var gate = RoomReadingGate()
        // eight words, all on the card in order, but only "pipeline" and "queue" are content words
        for text in ["the pipeline they went to a review queue", "then i to the at a the"] {
            let event = enEvent(text, start: 0)
            gate.observe(event)
            #expect(gate.anchor(for: event, card: card) == nil, Comment(rawValue: text))
        }
    }

    @Test
    func aJumpIsStricterThanContinuing() {
        // two words that continue from the cursor keep him reading; the same number of words elsewhere do not jump
        let continuing = anchorReading(roomRoute: true)
        read([s1], on: continuing, channel: .remote)
        read(["bad invoices never blocked"], on: continuing, channel: .remote, from: 1)
        #expect(continuing.struckWords(for: anchorSay).contains(7))
        let far = anchorReading(roomRoute: true)
        read([s1, "eleven percent"], on: far, channel: .remote)
        #expect(far.readingCursor == 7)
    }

    @Test
    func aLineSaidTwiceAnchorsAtTheOccurrenceNearestTheCursor() {
        let card = Array("abcdxxabcd").map(String.init), text = Array("abcd").map(String.init)
        #expect(RoomReading.anchorPath(text, card, maxGap: 1, near: 7).map(\.1) == [6, 7, 8, 9])
        #expect(RoomReading.anchorPath(text, card, maxGap: 1, near: 1).map(\.1) == [0, 1, 2, 3])
    }

    @Test
    func theStruckRunsJoinBackIntoTheText() {
        let runs = SaySplit.segments("  One two  three four", struck: IndexSet([0, 2]))
        #expect(runs.map(\.text).joined() == "  One two  three four")
        #expect(runs.map(\.spoken) == [true, false, true, false])
        #expect(SaySplit.segments("", struck: IndexSet()).isEmpty)
    }
}
