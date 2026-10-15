import Foundation
import Testing
@testable import VersePrompter
import VerseSpeech

@Suite("Prompter session")
struct SessionTests {
    static let script = ScriptParser.parse("""
    The quick brown fox jumps over the lazy dog near the river bank.

    ---
    Second page has its own words to read aloud.
    """)

    @Test
    func fallsBackToClassicWhenTheSpeechSourceFailsToStart() async {
        let clock = ManualClock()
        let session = PrompterSession(script: Self.script, mode: .wordTracking, transcript: ThrowingTranscriptSource(),
                                      clock: clock, autoTick: false)
        await session.start()
        let state = await session.state
        #expect(state.mode == .classic)
        #expect(state.requestedMode == .wordTracking)
        guard case .fellBackToClassic = state.notice else { Issue.record("no fallback notice"); return }
        #expect(!state.isPaused)
        clock.set(4)
        #expect(await session.state.wordPosition > 0)          // classic is moving
        await session.stop()
    }

    @Test
    func fallsBackToClassicWithoutAnySource() async {
        let session = PrompterSession(script: Self.script, mode: .voicePaced, clock: ManualClock(), autoTick: false)
        await session.start()
        #expect(await session.state.mode == .classic)
        await session.stop()
    }

    @Test
    func voicePacedModeFallsBackWhenLevelsFail() async {
        let session = PrompterSession(script: Self.script, mode: .voicePaced, levels: ThrowingLevelSource(),
                                      clock: ManualClock(), autoTick: false)
        await session.start()
        #expect(await session.state.mode == .classic)
        await session.stop()
    }

    @Test
    func wordTrackingFollowsMicEventsAndIgnoresRemoteOnes() async {
        let clock = ManualClock()
        let feed = FeedTranscriptSource()
        let session = PrompterSession(script: Self.script, mode: .wordTracking, transcript: feed, clock: clock, autoTick: false)
        await session.start()
        #expect(await session.state.mode == .wordTracking)

        clock.set(1)
        feed.broadcaster.yield(event("the quick brown fox jumps over", channel: .remote))
        feed.broadcaster.yield(event("the quick brown fox", channel: .me))
        #expect(await eventually { await session.state.wordPosition >= 4 })
        let position = await session.state.wordPosition
        #expect(position < 7)      // the remote line did not add "jumps over"
        await session.stop()
    }

    @Test
    func lostIsSetAfterEightSecondsOfUnmatchedSpeech() async {
        let clock = ManualClock()
        let feed = FeedTranscriptSource()
        let session = PrompterSession(script: Self.script, mode: .wordTracking, transcript: feed, clock: clock, autoTick: false)
        await session.start()

        // Results two seconds apart, so "speaking" turns true only once an event has been delivered.
        for second in [0.0, 2, 4, 6] {
            clock.set(second)
            feed.broadcaster.yield(event("so anyway about my weekend"))
            #expect(await eventually { await session.state.isSpeaking })
            #expect(await session.state.isLost == false)
        }
        clock.set(8)
        feed.broadcaster.yield(event("so anyway about my weekend"))
        #expect(await eventually { await session.state.isLost })
        await session.tick()
        // Published state carries it too.
        var lastSeen: PrompterState?
        for await s in session.states { lastSeen = s; break }
        #expect(lastSeen?.isLost == true)
        await session.stop()
    }

    @Test
    func pagesNavigateAndTheLastPageFinishes() async {
        let clock = ManualClock()
        let session = PrompterSession(script: Self.script, mode: .classic, wordsPerMinute: 60, clock: clock, autoTick: false)
        await session.start()
        #expect(await session.state.pageIndex == 0)
        #expect(await session.state.pageCount == 2)
        await session.previousPage()
        #expect(await session.state.pageIndex == 0)
        await session.nextPage()
        let second = await session.state
        #expect(second.pageIndex == 1 && second.wordPosition == 0 && !second.isDone)
        clock.set(1000)
        let done = await session.state
        #expect(done.isDone && done.wordPosition == Double(done.wordCount))
        await session.previousPage()
        let back = await session.state
        #expect(back.pageIndex == 0 && !back.isDone)
        await session.stop()
    }

    @Test
    func speedStepsClampAndAffectClassic() async {
        let clock = ManualClock()
        let session = PrompterSession(script: Self.script, mode: .classic, wordsPerMinute: 60, clock: clock, autoTick: false)
        await session.start()
        await session.adjustSpeed(bySteps: 3)
        #expect(await session.state.wordsPerMinute == 90)
        await session.adjustSpeed(bySteps: -100)
        #expect(await session.state.wordsPerMinute == PrompterSession.speedRange.lowerBound)
        await session.adjustSpeed(bySteps: 1000)
        #expect(await session.state.wordsPerMinute == PrompterSession.speedRange.upperBound)
        await session.stop()
    }

    @Test
    func jumpPauseAndResume() async {
        let clock = ManualClock()
        let session = PrompterSession(script: Self.script, mode: .classic, wordsPerMinute: 60, clock: clock, autoTick: false)
        await session.start()
        await session.jump(toWord: 5)
        #expect(await session.state.wordPosition == 5)
        await session.pause()
        clock.set(10)
        #expect(await session.state.wordPosition == 5)
        await session.resume()
        clock.set(12)
        let resumed = await session.state.wordPosition
        #expect(abs(resumed - 7) < 0.001)
        await session.stop()
    }

    @Test
    func liveModeSwitchKeepsThePosition() async {
        let clock = ManualClock()
        let feed = FeedTranscriptSource()
        let session = PrompterSession(script: Self.script, mode: .classic, wordsPerMinute: 60, transcript: feed,
                                      clock: clock, autoTick: false)
        await session.start()
        clock.set(3)
        let before = await session.state.wordPosition
        #expect(abs(before - 3) < 0.001)
        await session.setMode(.wordTracking)
        let after = await session.state
        #expect(after.mode == .wordTracking && after.notice == nil)
        #expect(abs(after.wordPosition - 3) < 0.6)             // lands on the character offset of word 3
        await session.setMode(.classic)
        #expect(await session.state.mode == .classic)
        await session.stop()
    }

    @Test
    func replaceUnreadKeepsTheReadPrefixInTheSession() async {
        let clock = ManualClock()
        let session = PrompterSession(script: ScriptParser.parse("alpha beta gamma delta epsilon"), mode: .classic,
                                      wordsPerMinute: 60, clock: clock, autoTick: false)
        await session.start()
        await session.jump(toWord: 2)
        await session.replaceUnread(with: "one two three")
        let page = await session.currentPage
        #expect(page.text == "alpha beta one two three")
        let state = await session.state
        #expect(state.wordPosition == 2)
        #expect(state.readOffset == "alpha beta".count + 1 || state.readOffset == "alpha beta".count)
        #expect(state.wordCount == 5)
        await session.stop()
    }

    @Test
    func replaceUnreadWorksInWordTrackingAndMatchingContinuesOnTheNewTail() async {
        let clock = ManualClock()
        let feed = FeedTranscriptSource()
        let session = PrompterSession(script: ScriptParser.parse("alpha beta gamma delta epsilon"), mode: .wordTracking,
                                      transcript: feed, clock: clock, autoTick: false)
        await session.start()
        clock.set(1)
        feed.broadcaster.yield(event("alpha beta", final: true))
        #expect(await eventually { await session.state.wordPosition >= 2 })
        await session.replaceUnread(with: "one two three")
        #expect(await session.currentPage.text == "alpha beta one two three")
        clock.set(2)
        feed.broadcaster.yield(event("one two", final: true))
        #expect(await eventually { await session.state.wordPosition >= 4 })
        await session.stop()
    }
}
