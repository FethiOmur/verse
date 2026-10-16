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
}
