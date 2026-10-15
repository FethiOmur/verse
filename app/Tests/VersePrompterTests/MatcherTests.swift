import Foundation
import Testing
@testable import VersePrompter

@Suite("Matcher, Verse cases")
struct MatcherTests {
    static let text = "The quick brown fox jumps over the lazy dog near the river bank"

    private func offset(after phrase: String, in page: PromptPage) -> Int {
        let range = page.text.range(of: phrase)!
        return page.text.distance(from: page.text.startIndex, to: range.upperBound)
    }

    @Test
    func followsPlainReadingInSteps() {
        let page = PromptPage(text: Self.text)
        var matcher = PromptMatcher(page: page)
        #expect(matcher.advance(spoken: "the quick brown") != nil)
        #expect(matcher.readOffset >= offset(after: "brown", in: page))
        #expect(matcher.advance(spoken: "the quick brown fox jumps over") != nil)
        #expect(matcher.readOffset >= offset(after: "over", in: page))
    }

    @Test
    func advanceReturnsNilWhenNothingMoves() {
        var matcher = PromptMatcher(page: PromptPage(text: Self.text))
        #expect(matcher.advance(spoken: "xx jj vv") == nil)
        #expect(matcher.readOffset == 0)
        #expect(matcher.advance(spoken: "") == nil)
    }

    @Test
    func skippedWordStillAdvancesPastIt() {
        let page = PromptPage(text: Self.text)
        var matcher = PromptMatcher(page: page)
        _ = matcher.advance(spoken: "the quick fox jumps over")                 // "brown" skipped
        #expect(matcher.readOffset >= offset(after: "over", in: page))
        #expect(matcher.readOffset <= offset(after: "over the", in: page))
    }

    @Test
    func reReadWordDoesNotMoveBackOrStall() {
        let page = PromptPage(text: Self.text)
        var matcher = PromptMatcher(page: page)
        _ = matcher.advance(spoken: "the quick brown fox")
        let afterFox = matcher.readOffset
        // He says "fox" again, then carries on: the offset never goes back and the new words are picked up.
        _ = matcher.advance(spoken: "the quick brown fox")
        #expect(matcher.readOffset >= afterFox)
        matcher.restartFromCurrentProgress()
        _ = matcher.advance(spoken: "fox jumps over the lazy")
        #expect(matcher.readOffset >= offset(after: "lazy", in: page))
    }

    @Test
    func stutterInsideTheTranscriptStillMatches() {
        let page = PromptPage(text: Self.text)
        var matcher = PromptMatcher(page: page)
        _ = matcher.advance(spoken: "the quick quick brown fox jumps")
        #expect(matcher.readOffset >= offset(after: "jumps", in: page))
    }

    @Test
    func fillerWordsBetweenScriptWordsAreIgnored() {
        let page = PromptPage(text: Self.text)
        var matcher = PromptMatcher(page: page)
        _ = matcher.advance(spoken: "the um quick uh brown er fox hmm jumps")
        #expect(matcher.readOffset >= offset(after: "jumps", in: page))
    }

    @Test
    func aFillerThatIsInTheScriptIsKept() {
        let page = PromptPage(text: "Well um that was the plan")
        var matcher = PromptMatcher(page: page)
        _ = matcher.advance(spoken: "well um that")
        #expect(matcher.readOffset >= offset(after: "that", in: page))
    }

    @Test
    func spelledNumberMatchesDigitsInTheScript() {
        let page = PromptPage(text: "We shipped 42 builds last week")
        var matcher = PromptMatcher(page: page)
        _ = matcher.advance(spoken: "we shipped forty two builds")
        #expect(matcher.readOffset >= offset(after: "builds", in: page))
    }

    @Test
    func digitsMatchASpelledNumberInTheScript() {
        let page = PromptPage(text: "We shipped forty-two builds last week")
        var matcher = PromptMatcher(page: page)
        _ = matcher.advance(spoken: "we shipped 42 builds")
        #expect(matcher.readOffset >= offset(after: "builds", in: page))
    }

    @Test
    func numberNormalizationCovers0To999AndKeepsLargerNumbersAlone() {
        let digits: Set<String> = ["105", "7", "300", "19", "100"]
        #expect(SpokenText.normalize("one hundred and five", sourceTokens: digits) == "105")
        #expect(SpokenText.normalize("seven", sourceTokens: digits) == "7")
        #expect(SpokenText.normalize("three hundred", sourceTokens: digits) == "300")
        #expect(SpokenText.normalize("nineteen", sourceTokens: digits) == "19")
        // Known gap: not in the script as digits, so left alone.
        #expect(SpokenText.normalize("forty two", sourceTokens: ["hello"]) == "forty two")
        let words: Set<String> = ["one", "hundred", "five"]
        #expect(SpokenText.normalize("105", sourceTokens: words) == "one hundred five")
    }

    @Test
    func jumpMovesBothWaysAndSkipsCues() {
        let page = PromptPage(text: "alpha [pause] beta gamma delta")
        var matcher = PromptMatcher(page: page)
        _ = matcher.advance(spoken: "alpha beta gamma")
        let far = matcher.readOffset
        let back = matcher.jump(to: 0)
        #expect(back == 0 && far > 0)
        let intoCue = matcher.jump(to: page.text.distance(from: page.text.startIndex, to: page.text.range(of: "[pause]")!.lowerBound))
        #expect(intoCue >= "alpha [pause]".count)
    }

    @Test
    func replacePageKeepsTheReadOffset() {
        let page = PromptPage(text: "alpha beta gamma delta")
        var matcher = PromptMatcher(page: page)
        _ = matcher.advance(spoken: "alpha beta")
        let read = matcher.readOffset
        let replaced = page.replacingUnread(from: read, with: "one two three")
        matcher.replace(page: replaced.page, readOffset: replaced.readOffset)
        #expect(matcher.readOffset >= "alpha beta".count)
        _ = matcher.advance(spoken: "one two")
        #expect(matcher.readOffset >= "alpha beta one two".count)
    }
}
