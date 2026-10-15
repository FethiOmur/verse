import Foundation

/// Clean-up of the recognizer's text before it is matched against the script. Written for Verse (not from Textream).
///
/// - Fillers ("um", "uh", ...) are dropped unless the script itself contains that token.
/// - Numbers are reconciled in both directions, only when the script has the other form: spoken "forty two" becomes
///   "42" if the script says "42"; a recognized "42" becomes "forty-two" if the script says "forty-two".
///   Covers 0...999. Known gaps: years ("twenty twenty"), ordinals, decimals, "thousand" and up, currency words.
enum SpokenText {
    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "ah", "hmm", "mm", "mhm"]

    private static let ones: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static func isNumberPart(_ part: String) -> Bool {
        ones[part] != nil || teens[part] != nil || tens[part] != nil || part == "hundred" || part == "and"
    }

    static func tokens(of text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: \.isWhitespace).map { core(String($0)) }.filter { !$0.isEmpty })
    }

    static func core(_ word: String) -> String { word.lowercased().filter { $0.isLetter || $0.isNumber } }

    static func normalize(_ spoken: String, sourceTokens: Set<String>) -> String {
        var words = spoken.split(whereSeparator: \.isWhitespace).map(String.init)
        words.removeAll { fillers.contains(core($0)) && !sourceTokens.contains(core($0)) }
        words = spelledNumbersToDigits(words, sourceTokens: sourceTokens)
        words = digitsToSpelledNumbers(words, sourceTokens: sourceTokens)
        return words.joined(separator: " ")
    }

    // MARK: spelled -> digits

    private static func parseNumber(_ parts: [String], from start: Int) -> (value: Int, end: Int)? {
        var i = start
        var value = 0
        let n = parts.count
        func isBelowHundred(_ p: String) -> Bool { ones[p] != nil || teens[p] != nil || tens[p] != nil }
        if i < n, let o = ones[parts[i]], (1...9).contains(o), i + 1 < n, parts[i + 1] == "hundred" {
            value = o * 100
            i += 2
        } else if i < n, parts[i] == "hundred" {
            value = 100
            i += 1
        }
        if value > 0 {
            if i + 1 < n, parts[i] == "and", isBelowHundred(parts[i + 1]) { i += 1 }
        }
        if i < n {
            if let t = teens[parts[i]] {
                value += t
                i += 1
            } else if let t = tens[parts[i]] {
                value += t
                i += 1
                if i < n, let o = ones[parts[i]], (1...9).contains(o) {
                    value += o
                    i += 1
                }
            } else if let o = ones[parts[i]], value == 0 || o > 0 {
                value += o
                i += 1
            }
        }
        return i > start ? (value, i) : nil
    }

    private static func spelledNumbersToDigits(_ words: [String], sourceTokens: Set<String>) -> [String] {
        guard sourceTokens.contains(where: { $0.allSatisfy(\.isNumber) }) else { return words }
        var out: [String] = []
        var index = 0
        while index < words.count {
            // Collect a run of number tokens.
            var end = index
            var parts: [String] = []
            var partToken: [Int] = []
            while end < words.count {
                let sub = words[end].lowercased().split(separator: "-").map { core(String($0)) }
                guard !sub.isEmpty, sub.allSatisfy(isNumberPart) else { break }
                for p in sub {
                    parts.append(p)
                    partToken.append(end)
                }
                end += 1
            }
            guard !parts.isEmpty else {
                out.append(words[index])
                index += 1
                continue
            }
            var p = 0
            var replaced: [Int: String] = [:]   // first token index -> digits, with the last token index kept alongside
            var lastToken: [Int: Int] = [:]
            while p < parts.count {
                if let (value, e) = parseNumber(parts, from: p) {
                    let firstTok = partToken[p], lastTok = partToken[e - 1]
                    let startsToken = p == 0 || partToken[p - 1] != firstTok
                    let endsToken = e == parts.count || partToken[e] != lastTok
                    if startsToken, endsToken, sourceTokens.contains(String(value)) {
                        replaced[firstTok] = String(value)
                        lastToken[firstTok] = lastTok
                    }
                    p = e
                } else {
                    p += 1
                }
            }
            var t = index
            while t < end {
                if let digits = replaced[t], let last = lastToken[t] {
                    out.append(digits)
                    t = last + 1
                } else {
                    out.append(words[t])
                    t += 1
                }
            }
            index = end
        }
        return out
    }

    // MARK: digits -> spelled

    private static let onesNames = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
    private static let teenNames = ["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
                                    "seventeen", "eighteen", "nineteen"]
    private static let tensNames = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    /// Word forms of 0...999, each a list of tokens: hyphenated and split, with and without "and".
    private static func spelledVariants(_ n: Int) -> [[String]] {
        func below100(_ v: Int, hyphen: Bool) -> [String] {
            if v < 10 { return [onesNames[v]] }
            if v < 20 { return [teenNames[v - 10]] }
            let t = tensNames[v / 10], o = v % 10
            if o == 0 { return [t] }
            return hyphen ? ["\(t)-\(onesNames[o])"] : [t, onesNames[o]]
        }
        var variants: [[String]] = []
        for hyphen in [true, false] {
            if n < 100 {
                variants.append(below100(n, hyphen: hyphen))
            } else {
                let head = [onesNames[n / 100], "hundred"]
                let rest = n % 100
                if rest == 0 {
                    variants.append(head)
                } else {
                    variants.append(head + below100(rest, hyphen: hyphen))
                    variants.append(head + ["and"] + below100(rest, hyphen: hyphen))
                }
            }
        }
        return variants
    }

    private static func digitsToSpelledNumbers(_ words: [String], sourceTokens: Set<String>) -> [String] {
        words.flatMap { word -> [String] in
            let digits = core(word)
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber), digits.count <= 3, let value = Int(digits),
                  !sourceTokens.contains(digits) else { return [word] }
            for variant in spelledVariants(value)
            where variant.allSatisfy({ sourceTokens.contains(core($0)) }) {
                return variant
            }
            return [word]
        }
    }
}
