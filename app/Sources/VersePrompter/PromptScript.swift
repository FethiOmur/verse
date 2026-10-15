import Foundation

// splitPromptTextIntoWords and the cue flagging are ported from Textream
// (TextreamiOS/Models/PromptTextProcessor.swift, upstream commit 2c02f3e).
// MIT License, Copyright (c) 2026 Fatih Kadir Akin. Full text: THIRD_PARTY_NOTICES at the repo root.
// Rewritten here as value types for Swift 6; the CJK splitting branch is kept because it costs nothing.

/// One word of a page. `characterRange` indexes `Character`s of `PromptPage.text`.
/// `isCue`: part of a `[bracketed]` note, or a token with no letter or digit. The UI shows cues in the cue
/// colour and the matcher skips them.
public struct PromptWord: Sendable, Equatable, Identifiable {
    public let id: Int
    public let text: String
    public let characterRange: Range<Int>
    public let isCue: Bool
}

/// A page is whitespace-collapsed text plus its words. Page-local indexing everywhere.
public struct PromptPage: Sendable, Equatable {
    /// Words joined by single spaces.
    public let text: String
    public let words: [PromptWord]
    /// Balanced `[...]` ranges, in `Character` offsets of `text` (speech ranges include the brackets).
    let annotationRanges: [Range<Int>]

    public init(text rawText: String) {
        let rawWords = splitPromptTextIntoWords(rawText)
        let collapsed = rawWords.joined(separator: " ")
        let flags = SpeechTextAlignment.annotationFlags(for: rawWords)
        var offset = 0
        var built: [PromptWord] = []
        built.reserveCapacity(rawWords.count)
        for (index, word) in rawWords.enumerated() {
            let range = offset..<(offset + word.count)
            let readable = word.contains { $0.isLetter || $0.isNumber }
            built.append(PromptWord(id: index, text: word, characterRange: range, isCue: flags[index] || !readable))
            offset = range.upperBound + 1
        }
        text = collapsed
        words = built
        annotationRanges = SpeechTextAlignment.annotationRanges(in: collapsed)
    }

    public var characterCount: Int { text.count }
    public var wordCount: Int { words.count }
    public var isEmpty: Bool { words.isEmpty }

    /// Character offset for a fractional word index (`1.5` = halfway through the second word).
    public func characterOffset(forWordProgress progress: Double) -> Int {
        guard !words.isEmpty else { return 0 }
        let clamped = max(0, min(progress, Double(words.count)))
        let whole = min(Int(clamped), words.count)
        guard whole < words.count else { return characterCount }
        let fraction = clamped - Double(whole)
        let word = words[whole]
        return min(characterCount, word.characterRange.lowerBound + Int(Double(word.text.count) * fraction))
    }

    /// Inverse of `characterOffset(forWordProgress:)`.
    public func wordProgress(forCharacterOffset offset: Int) -> Double {
        let clamped = max(0, min(offset, characterCount))
        for word in words where clamped <= word.characterRange.upperBound {
            let position = max(0, clamped - word.characterRange.lowerBound)
            return Double(word.id) + Double(position) / Double(max(1, word.text.count))
        }
        return Double(words.count)
    }

    /// Meeting-card update (Textream `updateText(_:preservingCharCount:)` semantics): keep the text up to
    /// `readOffset` (a word that is half read counts as read) and replace everything after it with `newText`.
    /// Returns the new page and the read offset inside it.
    public func replacingUnread(from readOffset: Int, with newText: String) -> (page: PromptPage, readOffset: Int) {
        var cut = max(0, min(readOffset, characterCount))
        if let word = words.first(where: { $0.characterRange.lowerBound < cut && cut < $0.characterRange.upperBound }) {
            cut = word.characterRange.upperBound
        }
        let prefix = String(text.prefix(cut)).trimmingCharacters(in: .whitespaces)
        let tail = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = prefix.isEmpty ? tail : (tail.isEmpty ? prefix : prefix + " " + tail)
        let page = PromptPage(text: combined)
        // The prefix is already collapsed, so its length is the read offset in the new text.
        return (page, min(prefix.count, page.characterCount))
    }
}

public struct PromptScript: Sendable, Equatable {
    public let pages: [PromptPage]

    public init(pages: [PromptPage]) { self.pages = pages.filter { !$0.isEmpty } }
    public init(text: String) { self = ScriptParser.parse(text) }

    public var isEmpty: Bool { pages.isEmpty }
    public var totalWordCount: Int { pages.reduce(0) { $0 + $1.wordCount } }
}

public enum ScriptParser {
    /// Page break: a blank line followed by a line that is exactly `---`. A `---` directly under text is not a
    /// break (Markdown heading underline). `[bracketed]` text becomes cue words. Pages without words are dropped.
    public static func parse(_ text: String) -> PromptScript {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var chunks: [[String]] = [[]]
        for (index, line) in lines.enumerated() {
            let isBreak = line.trimmingCharacters(in: .whitespaces) == "---"
                && index > 0
                && lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty
            if isBreak {
                chunks.append([])
            } else {
                chunks[chunks.count - 1].append(line)
            }
        }
        return PromptScript(pages: chunks.map { PromptPage(text: $0.joined(separator: "\n")) })
    }
}

extension Unicode.Scalar {
    var isPromptCJK: Bool {
        let value = value
        return (value >= 0x4E00 && value <= 0x9FFF)
            || (value >= 0x3400 && value <= 0x4DBF)
            || (value >= 0x20000 && value <= 0x2A6DF)
            || (value >= 0xF900 && value <= 0xFAFF)
            || (value >= 0x3040 && value <= 0x309F)
            || (value >= 0x30A0 && value <= 0x30FF)
            || (value >= 0xAC00 && value <= 0xD7AF)
    }
}

func splitPromptTextIntoWords(_ text: String) -> [String] {
    let tokens = text.replacingOccurrences(of: "\n", with: " ")
        .split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        .map(String.init)

    var result: [String] = []
    for token in tokens {
        guard token.unicodeScalars.contains(where: \.isPromptCJK) else {
            result.append(token)
            continue
        }
        var buffer = ""
        for character in token {
            if character.unicodeScalars.first?.isPromptCJK == true {
                if !buffer.isEmpty {
                    result.append(buffer)
                    buffer = ""
                }
                result.append(String(character))
            } else {
                buffer.append(character)
            }
        }
        if !buffer.isEmpty { result.append(buffer) }
    }
    return result
}
