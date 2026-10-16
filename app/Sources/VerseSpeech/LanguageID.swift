import Foundation
import NaturalLanguage

/// A guess of the language of a text, from `NLLanguageRecognizer` limited to the languages Verse knows.
public struct LanguageGuess: Sendable, Equatable {
    /// "en", "it" or "tr".
    public var lang: String
    /// The recognizer's probability for `lang` (0...1).
    public var confidence: Double

    public init(lang: String, confidence: Double) {
        self.lang = lang
        self.confidence = confidence
    }
}

/// Text language identification for the interim AUTO language mode (spec 2.5, "interim AUTO"). Pure functions over
/// `NLLanguageRecognizer`; no state is kept between calls.
public enum LanguageID {
    public static let supported = ["en", "it", "tr"]

    /// Below this many words a text is not judged: two words ("Okay thanks", "Perché no") are too short for a language
    /// recognizer, and a loanword is exactly that long.
    public static let minWords = 3

    /// The probability a guess needs before it names a turn's language (spec 2.5: 0.8).
    public static let turnConfidence = 0.8

    static func nl(_ lang: String) -> NLLanguage {
        switch lang {
        case "it": return .italian
        case "tr": return .turkish
        default: return .english
        }
    }

    static func code(_ l: NLLanguage) -> String? {
        switch l {
        case .english: return "en"
        case .italian: return "it"
        case .turkish: return "tr"
        default: return nil
        }
    }

    /// Words of `text` (letters and apostrophes), for the minimum-length rule.
    static func wordCount(_ text: String) -> Int {
        text.split { !($0.isLetter || $0 == "'" || $0 == "’") }.count
    }

    /// All hypotheses over `allowed`, best first. Empty when the text is too short or the recognizer has none.
    public static func hypotheses(_ text: String, allowed: [String] = supported, minWords: Int = minWords) -> [LanguageGuess] {
        guard wordCount(text) >= minWords else { return [] }
        let r = NLLanguageRecognizer()
        r.languageConstraints = allowed.map(nl)
        r.processString(text)
        return r.languageHypotheses(withMaximum: allowed.count)
            .compactMap { (l, p) in code(l).map { LanguageGuess(lang: $0, confidence: p) } }
            .sorted { $0.confidence > $1.confidence }
    }

    /// The most likely language, or nil for a text that is too short.
    public static func guess(_ text: String, allowed: [String] = supported, minWords: Int = minWords) -> LanguageGuess? {
        hypotheses(text, allowed: allowed, minWords: minWords).first
    }

    /// The language a turn or partial is sent with: the text's own when the recognizer is confident (>= 0.8), else the
    /// language of the engine that heard it.
    public static func turnLang(_ text: String, engineLang: String) -> String {
        if let g = guess(text), g.confidence >= turnConfidence { return g.lang }
        return engineLang
    }
}
