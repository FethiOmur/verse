import Foundation
import Testing
@testable import VersePrompter

// Ported from Textream: TextreamiOSTests/PromptCoreTests.swift (upstream commit 2c02f3e), MIT License,
// Copyright (c) 2026 Fatih Kadir Akin (THIRD_PARTY_NOTICES). Only the cases that cover code ported into
// VersePrompter are here (tokenizer, cues, annotation ranges, matcher, word progress, voice activity, classic
// and voice-paced advance); the rest of that file tests Textream's iOS UI and camera and is not ported.
// Adaptations: `PromptScript("...")` is `PromptPage(text:)`, `isAnnotation` is `isCue`, and the two session
// cases run against `ClassicDriver` / `VoicePacedDriver`.
@Suite("Textream ported")
struct TextreamPortedTests {
    @Test
    func tokenizerCollapsesWhitespaceAndSplitsCJKCharacters() {
        let page = PromptPage(text: "Hello\n\n世界  again")

        #expect(page.words.map(\.text) == ["Hello", "世", "界", "again"])
        #expect(page.text == "Hello 世 界 again")
    }

    @Test
    func balancedCuesAreAnnotationsButUnmatchedOpeningBracketIsReadable() {
        let balanced = PromptPage(text: "Hello [look at camera] world")
        #expect(balanced.words.filter(\.isCue).map(\.text) == ["[look", "at", "camera]"])

        let unmatched = PromptPage(text: "Hello [unfinished world")
        #expect(!unmatched.words[1].isCue)
        #expect(!unmatched.words[2].isCue)
    }

    @Test
    func speechAnnotationRangesMatchMacIncludingEmptyCues() {
        let page = PromptPage(text: "Lead [look at camera] middle [] stray] [unfinished")

        #expect(page.annotationRanges.map { String(Array(page.text)[$0]) } == ["[look at camera]", "[]"])
    }

    @Test
    func annotationRangesFindEmbeddedAndAdjacentCuesExactly() {
        let page = PromptPage(text: "hello[pause]world [one][two]")

        #expect(page.annotationRanges.map { String(Array(page.text)[$0]) } == ["[pause]", "[one]", "[two]"])
        #expect(page.annotationRanges.first == 5..<12)
    }

    @Test
    func matcherSkipsCueAndMovesForwardWithFuzzyTranscript() {
        var matcher = PromptMatcher(page: PromptPage(text: "Welcome [smile] to the presentation today"))

        let first = matcher.match(transcript: "welcome to the")
        let second = matcher.match(transcript: "welcome to the presentation")

        #expect(first > "Welcome".count)
        #expect(second >= first)
        #expect(second > "Welcome [smile] to the".count)
    }

    @Test
    func matcherNeverMovesBackward() {
        var matcher = PromptMatcher(page: PromptPage(text: "one two three four five six"))
        let forward = matcher.match(transcript: "one two three four")
        let stale = matcher.match(transcript: "one")

        #expect(stale == forward)
    }

    @Test
    func wordProgressRoundTripsCharacterOffsets() {
        let page = PromptPage(text: "alpha beta gamma")
        let offset = page.characterOffset(forWordProgress: 1.5)

        #expect(offset == 8)
        #expect(abs(page.wordProgress(forCharacterOffset: offset) - 1.5) < 0.01)
    }

    @Test
    func voiceActivityUsesActivationFramesAndHangover() {
        var detector = VoiceActivityDetector()
        detector.process(level: 0.02, at: 10)
        #expect(!detector.isActive(at: 10))

        detector.process(level: 0.02, at: 10.05)
        #expect(detector.isActive(at: 10.5))
        #expect(!detector.isActive(at: 10.81))
    }

    @Test
    func classicTimerAdvancesFractionalWordProgress() {
        // Textream: classicSessionTimerAdvancesFractionalWordProgress (250 ms of real time, > 0.2 words).
        let driver = ClassicDriver(wordCount: 100, wordsPerMinute: 120, now: 0)   // 2 words per second
        #expect(driver.position(at: 0) == 0)
        #expect(driver.position(at: 0.25) > 0.2)
        #expect(driver.position(at: 0.25) < 1)
    }

    @Test
    func voicePacedDriverEntersSpeakingStateFromMicrophoneLevels() {
        // Textream: voiceFollowerEntersSpeakingStateFromMicrophoneLevels (a level of 0.05 is speech at once).
        let driver = VoicePacedDriver(wordCount: 3, wordsPerMinute: 150, now: 0)
        driver.ingest(level: 0.05, at: 0.1)

        #expect(driver.isSpeaking(at: 0.2))
    }
}
