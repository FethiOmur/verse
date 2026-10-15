import Foundation
import Testing
@testable import VersePrompter
import VerseSpeech

@Suite("Scroll drivers")
struct DriverTests {
    // MARK: classic

    @Test
    func classicAdvancesAtTheSetSpeed() {
        let driver = ClassicDriver(wordCount: 1000, wordsPerMinute: 150, now: 0)   // 2.5 words per second
        #expect(abs(driver.position(at: 10) - 25) < 0.001)
        driver.setWordsPerMinute(300, at: 10)
        #expect(abs(driver.position(at: 12) - 35) < 0.001)
    }

    @Test
    func classicPausesResumesAndStopsAtTheEnd() {
        let driver = ClassicDriver(wordCount: 10, wordsPerMinute: 60, now: 0)
        driver.setPaused(true, at: 3)
        #expect(abs(driver.position(at: 8) - 3) < 0.001)
        driver.setPaused(false, at: 8)
        #expect(abs(driver.position(at: 10) - 5) < 0.001)
        #expect(driver.position(at: 100) == 10)
        driver.jump(toWord: 2, at: 100)
        #expect(driver.position(at: 100) == 2)
    }

    // MARK: voice paced

    @Test
    func voicePacedStopsWithinTheHangoverAfterSilence() {
        let driver = VoicePacedDriver(wordCount: 1000, wordsPerMinute: 120, now: 0)   // 2 words per second
        // Speech from 1.00 s to 2.00 s, then silence.
        for k in 0...20 { driver.ingest(level: 0.05, at: 1.0 + Double(k) * 0.05) }
        let silenceStarts = 2.0
        let hangoverEnd = silenceStarts + 0.75
        #expect(driver.isSpeaking(at: silenceStarts + 0.5))
        #expect(!driver.isSpeaking(at: hangoverEnd + 0.01))
        // It keeps moving during the hangover and not after it.
        let atHangoverEnd = driver.position(at: hangoverEnd)
        #expect(atHangoverEnd > driver.position(at: silenceStarts))
        #expect(abs(driver.position(at: hangoverEnd + 5) - atHangoverEnd) < 1e-9)
        // Total moved: about (2.75 - 1.0) seconds at 2 words per second.
        #expect(abs(atHangoverEnd - 3.5) < 0.2)
    }

    @Test
    func voicePacedStandsStillBeforeSpeechAndBelowThreshold() {
        let driver = VoicePacedDriver(wordCount: 100, wordsPerMinute: 120, now: 0)
        for i in 0..<40 { driver.ingest(level: 0.005, at: Double(i) * 0.05) }
        #expect(driver.position(at: 3) == 0)
        #expect(!driver.isSpeaking(at: 2))
    }

    @Test
    func voicePacedNeedsTwoQuietFramesButOneLoudOne() {
        let quiet = VoicePacedDriver(wordCount: 100, wordsPerMinute: 120, now: 0)
        quiet.ingest(level: 0.02, at: 1)
        #expect(!quiet.isSpeaking(at: 1.01))
        let loud = VoicePacedDriver(wordCount: 100, wordsPerMinute: 120, now: 0)
        loud.ingest(level: 0.05, at: 1)
        #expect(loud.isSpeaking(at: 1.01))
    }

    @Test
    func voicePacedPauseFreezesPosition() {
        let driver = VoicePacedDriver(wordCount: 100, wordsPerMinute: 120, now: 0)
        driver.ingest(level: 0.05, at: 0)
        driver.setPaused(true, at: 0.5)
        let frozen = driver.position(at: 0.5)
        driver.ingest(level: 0.05, at: 0.6)
        #expect(driver.position(at: 1.2) == frozen)
    }

    @Test
    func listenSessionLevelsConvertFromDbfsToLinear() {
        #expect(ListenSessionLevelSource.linear(fromDbfs: nil) == 0)
        #expect(abs(ListenSessionLevelSource.linear(fromDbfs: -20) - 0.1) < 1e-9)
        #expect(ListenSessionLevelSource.linear(fromDbfs: 6) == 1)
        // Textream's activation level 0.012 is about -38 dBFS.
        #expect(ListenSessionLevelSource.linear(fromDbfs: -38) > 0.012)
    }

    // MARK: word tracking

    private func tracker(_ text: String = MatcherTests.text, lostAfter: TimeInterval = 8) -> (WordTrackingDriver, PromptPage) {
        let page = PromptPage(text: text)
        return (WordTrackingDriver(page: page, lostAfter: lostAfter), page)
    }

    @Test
    func wordTrackingAdvancesOnMicEvents() {
        let (driver, page) = tracker()
        driver.ingest(event("the quick brown fox"), at: 1)
        #expect(driver.position(at: 1) >= 4)
        #expect(driver.position(at: 1) <= Double(page.wordCount))
        #expect(driver.isSpeaking(at: 1.2))
        #expect(!driver.isSpeaking(at: 5))
    }

    @Test
    func wordTrackingIgnoresRemoteChannelEvents() {
        let (driver, _) = tracker()
        driver.ingest(event("the quick brown fox jumps over", channel: .remote), at: 1)
        driver.ingest(event("the quick brown fox jumps over", channel: .remote, final: true), at: 2)
        #expect(driver.position(at: 2) == 0)
        #expect(!driver.isSpeaking(at: 2))
        driver.ingest(event("the quick"), at: 3)
        #expect(driver.position(at: 3) >= 2)
    }

    @Test
    func remoteSpeechNeverCountsTowardsLost() {
        let (driver, _) = tracker()
        for i in 0..<20 { driver.ingest(event("some other person talking about budgets", channel: .remote), at: Double(i)) }
        #expect(!driver.isLost(at: 20))
    }

    @Test
    func finalEventsRestartMatchingFromTheReadPosition() {
        let (driver, page) = tracker()
        driver.ingest(event("the quick brown", final: true), at: 1)
        let afterFirst = driver.position(at: 1)
        #expect(afterFirst >= 3)
        // The next range contains only new words.
        driver.ingest(event("fox jumps over"), at: 2)
        #expect(driver.position(at: 2) >= 6)
        #expect(driver.position(at: 2) <= Double(page.wordCount))
    }

    /// Cumulative off-script transcript, one more word per result, as a recognizer range would grow.
    private static let offScript = "so anyway let me tell you about my weekend and then some of the other things we did on the river".split(separator: " ").map(String.init)

    @Test
    func lostAfterEightSecondsOfSpeechWithoutACommit() {
        let (driver, _) = tracker()
        for k in 0..<16 {
            let second = Double(k) * 0.5
            driver.ingest(event(Self.offScript.prefix(k + 3).joined(separator: " ")), at: second)
            if second < 8 { #expect(!driver.isLost(at: second), "not lost at \(second)") }
        }
        #expect(driver.isLost(at: 7.5 + 0.5))
        // Shared letters let the matcher creep forward a little (upstream behaviour); it never counted as reading.
        #expect(driver.position(at: 8) < 8)
        // It stays lost through a pause in speech, and a click clears it.
        #expect(driver.isLost(at: 20))
        driver.jump(toWord: 3, at: 20)
        #expect(!driver.isLost(at: 20))
        #expect(driver.position(at: 20) >= 3)
    }

    @Test
    func aCommitClearsLostAndSilenceDoesNotCountAsLost() {
        let (driver, _) = tracker()
        for second in stride(from: 0.0, through: 9.0, by: 1) {
            driver.ingest(event("completely different topic here"), at: second)
        }
        #expect(driver.isLost(at: 9))
        driver.ingest(event("the quick brown fox"), at: 10)
        #expect(!driver.isLost(at: 10))

        // Long silence, then he starts talking: the 8 s clock restarts with the new speech.
        let (quiet, _) = tracker()
        quiet.ingest(event("hmm let me think"), at: 0)
        quiet.ingest(event("ok so the other thing"), at: 30)
        #expect(!quiet.isLost(at: 30))
    }

    @Test
    func jumpMovesBothWaysAndOldSpeechDoesNotLeakBack() {
        let (driver, page) = tracker()
        driver.ingest(event("the quick brown fox jumps over the lazy"), at: 1)
        let forward = driver.position(at: 1)
        #expect(forward >= 8)
        driver.jump(toWord: 1, at: 2)
        #expect(abs(driver.position(at: 2) - 1) < 0.01)
        // The recognizer's open range still carries the old words; they must not move the script.
        driver.ingest(event("the quick brown fox jumps over the lazy dog"), at: 2.1)
        #expect(driver.position(at: 2.1) <= 1.01 || driver.position(at: 2.1) < forward)
        // Re-reading from the jump target is picked up on a fresh range.
        driver.ingest(event("quick brown fox", final: true), at: 3)
        driver.ingest(event("jumps over the"), at: 4)
        #expect(driver.position(at: 4) >= 7 - 0.01)
        #expect(driver.position(at: 4) <= Double(page.wordCount))
    }

    @Test
    func pausedWordTrackingIgnoresSpeechUntilResumed() {
        let (driver, _) = tracker()
        driver.setPaused(true, at: 0)
        driver.ingest(event("the quick brown fox"), at: 1)
        #expect(driver.position(at: 1) == 0)
        driver.setPaused(false, at: 2)
        driver.ingest(event("the quick brown fox jumps"), at: 2.1)       // same open range: trimmed as old speech
        #expect(driver.position(at: 2.1) < 5)
    }
}
