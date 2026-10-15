import Foundation

// Ported from Textream: TextreamiOS/Speech/PromptMatcher.swift (upstream commit 2c02f3e), which is the pure-struct
// refactor of the macOS matcher in Textream/SpeechRecognizer.swift (charLevelMatch, wordLevelMatch, matchCharacters).
// MIT License, Copyright (c) 2026 Fatih Kadir Akin. Full text: THIRD_PARTY_NOTICES at the repo root.
// Changes for Verse: works on a `PromptPage`; `advance(spoken:)` returns nil when nothing was committed; spoken text
// goes through `SpokenText.normalize` first (fillers, number forms); `replace(page:)` for meeting-card updates.

/// Matches recognized speech against one page and tracks how far the reader has got, in `Character` offsets.
/// Forward only: skipped words (up to 5) are tolerated, a re-read word does not move it back, tap-to-jump is
/// `jump(to:)`. `spoken` is the transcript since the last `restartFromCurrentProgress()` (or jump/start).
public struct PromptMatcher: Sendable {
    public private(set) var page: PromptPage
    /// Characters of the page that count as read.
    public private(set) var readOffset: Int
    private(set) var matchStartOffset: Int
    private var recentMatchPositions: [Int] = []

    public init(page: PromptPage, startingAt offset: Int = 0) {
        self.page = page
        let start = SpeechTextAlignment.advancePastAnnotations(in: page.text, ranges: page.annotationRanges, from: offset)
        readOffset = start
        matchStartOffset = start
    }

    /// Next transcript is a fresh recognizer range: match from the current progress.
    public mutating func restartFromCurrentProgress() {
        matchStartOffset = readOffset
        recentMatchPositions.removeAll(keepingCapacity: true)
    }

    @discardableResult
    public mutating func jump(to offset: Int) -> Int {
        let clamped = max(0, min(offset, page.characterCount))
        let target = SpeechTextAlignment.advancePastAnnotations(in: page.text, ranges: page.annotationRanges, from: clamped)
        readOffset = target
        matchStartOffset = target
        recentMatchPositions.removeAll(keepingCapacity: true)
        return target
    }

    /// Swap the page text keeping `offset` as the read position (Textream `updateText(_:preservingCharCount:)`).
    public mutating func replace(page newPage: PromptPage, readOffset offset: Int) {
        self = PromptMatcher(page: newPage, startingAt: min(offset, newPage.characterCount))
    }

    /// Feed the transcript; returns the new read offset if it moved forward, otherwise nil.
    public mutating func advance(spoken: String) -> Int? {
        let before = readOffset
        let after = match(transcript: spoken)
        return after > before ? after : nil
    }

    @discardableResult
    mutating func match(transcript rawTranscript: String) -> Int {
        guard !rawTranscript.isEmpty, matchStartOffset < page.characterCount else { return readOffset }
        let sourceTokens = SpokenText.tokens(of: String(page.text.dropFirst(matchStartOffset)))
        let transcript = SpokenText.normalize(rawTranscript, sourceTokens: sourceTokens)
        guard !transcript.isEmpty else { return readOffset }

        let characterResult = characterLevelMatch(spoken: transcript)
        let wordResult = wordLevelMatch(spoken: transcript)
        let best = SpeechTextAlignment.bestOffset(characterResult: characterResult, wordResult: wordResult)
        let rawCandidate = min(matchStartOffset + best, page.characterCount)
        let candidate = SpeechTextAlignment.advancePastAnnotations(
            in: page.text, ranges: page.annotationRanges, from: rawCandidate)
        guard candidate > readOffset else { return readOffset }

        recentMatchPositions.append(candidate)
        if recentMatchPositions.count > 3 { recentMatchPositions.removeFirst() }
        let confirmed = recentMatchPositions.filter { abs($0 - candidate) <= 10 }.count >= 2

        if SpeechTextAlignment.shouldCommit(
            characterResult: characterResult,
            wordResult: wordResult,
            current: readOffset,
            rawCandidate: rawCandidate,
            candidate: candidate,
            confirmed: confirmed
        ) {
            readOffset = candidate
        }
        return readOffset
    }

    private func characterLevelMatch(spoken: String) -> Int {
        let remainingSource = String(page.text.dropFirst(matchStartOffset))
        let sourceCharacters = Array(remainingSource.lowercased())
        let spokenCharacters = Array(Self.normalize(spoken))
        var sourceIndex = 0
        var spokenIndex = 0
        var lastGoodSourceIndex = 0

        while sourceIndex < sourceCharacters.count && spokenIndex < spokenCharacters.count {
            let sourceCharacter = sourceCharacters[sourceIndex]
            let spokenCharacter = spokenCharacters[spokenIndex]

            if sourceCharacter == "[",
               let closingIndex = sourceCharacters[sourceIndex...].firstIndex(of: "]") {
                sourceIndex = closingIndex + 1
                lastGoodSourceIndex = sourceIndex
                continue
            }
            if !sourceCharacter.isLetter && !sourceCharacter.isNumber {
                sourceIndex += 1
                continue
            }
            if !spokenCharacter.isLetter && !spokenCharacter.isNumber {
                spokenIndex += 1
                continue
            }

            if sourceCharacter == spokenCharacter {
                sourceIndex += 1
                spokenIndex += 1
                lastGoodSourceIndex = sourceIndex
                continue
            }

            var found = false
            let maxSpokenSkip = min(5, spokenCharacters.count - spokenIndex - 1)
            if maxSpokenSkip >= 1 {
                for skip in 1...maxSpokenSkip where spokenCharacters[spokenIndex + skip] == sourceCharacter {
                    spokenIndex += skip
                    found = true
                    break
                }
            }
            if found { continue }

            let maxSourceSkip = min(5, sourceCharacters.count - sourceIndex - 1)
            if maxSourceSkip >= 1 {
                for skip in 1...maxSourceSkip where sourceCharacters[sourceIndex + skip] == spokenCharacter {
                    sourceIndex += skip
                    found = true
                    break
                }
            }
            if found { continue }
            spokenIndex += 1
        }

        while sourceIndex < sourceCharacters.count {
            if sourceCharacters[sourceIndex] == "[",
               let closingIndex = sourceCharacters[sourceIndex...].firstIndex(of: "]") {
                sourceIndex = closingIndex + 1
                lastGoodSourceIndex = sourceIndex
            } else if !sourceCharacters[sourceIndex].isLetter && !sourceCharacters[sourceIndex].isNumber {
                sourceIndex += 1
                lastGoodSourceIndex = sourceIndex
            } else {
                break
            }
        }
        return lastGoodSourceIndex
    }

    private func wordLevelMatch(spoken: String) -> Int {
        let remainingSource = String(page.text.dropFirst(matchStartOffset))
        let sourceWords = remainingSource.split(separator: " ").map(String.init)
        let spokenWords = splitPromptTextIntoWords(spoken.lowercased())
        var sourceIndex = 0
        var spokenIndex = 0
        var matchedCharacterCount = 0
        var isInsideAnnotation = false

        while sourceIndex < sourceWords.count && spokenIndex < spokenWords.count {
            let beginsAnnotation = sourceWords[sourceIndex].hasPrefix("[")
                && sourceWords[sourceIndex...].contains(where: { $0.contains("]") })
            let skipsAnnotation = isInsideAnnotation || beginsAnnotation || Self.isAnnotationWord(sourceWords[sourceIndex])
            if skipsAnnotation {
                if beginsAnnotation { isInsideAnnotation = true }
                if sourceWords[sourceIndex].contains("]") { isInsideAnnotation = false }
                matchedCharacterCount += sourceWords[sourceIndex].count
                if sourceIndex < sourceWords.count - 1 { matchedCharacterCount += 1 }
                sourceIndex += 1
                continue
            }

            let sourceWord = sourceWords[sourceIndex].lowercased().filter { $0.isLetter || $0.isNumber }
            let spokenWord = spokenWords[spokenIndex].filter { $0.isLetter || $0.isNumber }
            if sourceWord == spokenWord || Self.isFuzzyMatch(sourceWord, spokenWord) {
                matchedCharacterCount += sourceWords[sourceIndex].count
                sourceIndex += 1
                spokenIndex += 1
                if sourceIndex < sourceWords.count { matchedCharacterCount += 1 }
                continue
            }

            var foundSpoken = false
            let maximumSpokenSkip = min(5, spokenWords.count - spokenIndex - 1)
            if maximumSpokenSkip >= 1 {
                for skip in 1...maximumSpokenSkip {
                    let next = spokenWords[spokenIndex + skip].filter { $0.isLetter || $0.isNumber }
                    if sourceWord == next || Self.isFuzzyMatch(sourceWord, next) {
                        spokenIndex += skip
                        foundSpoken = true
                        break
                    }
                }
            }
            if foundSpoken { continue }

            var foundSource = false
            let maximumSourceSkip = min(5, sourceWords.count - sourceIndex - 1)
            if maximumSourceSkip >= 1 {
                for skip in 1...maximumSourceSkip {
                    let next = sourceWords[sourceIndex + skip].lowercased().filter { $0.isLetter || $0.isNumber }
                    if next == spokenWord || Self.isFuzzyMatch(next, spokenWord) {
                        for skippedIndex in 0..<skip {
                            matchedCharacterCount += sourceWords[sourceIndex + skippedIndex].count + 1
                        }
                        sourceIndex += skip
                        foundSource = true
                        break
                    }
                }
            }
            if foundSource { continue }

            if sourceWord.isEmpty {
                matchedCharacterCount += sourceWords[sourceIndex].count
                if sourceIndex < sourceWords.count - 1 { matchedCharacterCount += 1 }
                sourceIndex += 1
            } else {
                spokenIndex += 1
            }
        }

        while sourceIndex < sourceWords.count {
            let beginsAnnotation = sourceWords[sourceIndex].hasPrefix("[")
                && sourceWords[sourceIndex...].contains(where: { $0.contains("]") })
            let skipsAnnotation = isInsideAnnotation || beginsAnnotation || Self.isAnnotationWord(sourceWords[sourceIndex])
            guard skipsAnnotation else { break }
            if beginsAnnotation { isInsideAnnotation = true }
            if sourceWords[sourceIndex].contains("]") { isInsideAnnotation = false }
            matchedCharacterCount += sourceWords[sourceIndex].count
            if sourceIndex < sourceWords.count - 1 { matchedCharacterCount += 1 }
            sourceIndex += 1
        }
        return matchedCharacterCount
    }

    static func isFuzzyMatch(_ first: String, _ second: String) -> Bool {
        guard !first.isEmpty, !second.isEmpty else { return false }
        if first == second { return true }
        let shorter = min(first.count, second.count)
        if shorter >= 3 && (first.hasPrefix(second) || second.hasPrefix(first)) { return true }
        let sharedPrefix = zip(first, second).prefix(while: { $0 == $1 }).count
        if shorter >= 3 && sharedPrefix >= max(3, shorter * 3 / 5) { return true }
        let distance = editDistance(first, second)
        if shorter <= 2 { return false }
        if shorter <= 4 { return distance <= 1 }
        if shorter <= 8 { return distance <= 2 }
        return distance <= max(first.count, second.count) / 3
    }

    static func editDistance(_ first: String, _ second: String) -> Int {
        let firstCharacters = Array(first)
        let secondCharacters = Array(second)
        guard !firstCharacters.isEmpty else { return secondCharacters.count }
        guard !secondCharacters.isEmpty else { return firstCharacters.count }
        var row = Array(0...secondCharacters.count)
        for firstIndex in 1...firstCharacters.count {
            var previous = row[0]
            row[0] = firstIndex
            for secondIndex in 1...secondCharacters.count {
                let temporary = row[secondIndex]
                row[secondIndex] = firstCharacters[firstIndex - 1] == secondCharacters[secondIndex - 1]
                    ? previous
                    : min(previous, row[secondIndex], row[secondIndex - 1]) + 1
                previous = temporary
            }
        }
        return row[secondCharacters.count]
    }

    private static func isAnnotationWord(_ word: String) -> Bool {
        (word.hasPrefix("[") && word.hasSuffix("]"))
            || word.allSatisfy { !$0.isLetter && !$0.isNumber }
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
    }
}
