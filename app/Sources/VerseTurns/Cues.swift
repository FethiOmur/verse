import Foundation

/// Question cues and clause-completeness checks on volatile transcript text (plan P1-4).
/// English is the tuned language; Italian and Turkish only use the simple cue lists from the plan.
public enum Cues {
    // MARK: hesitation

    private static let hesitationWords: [String: Set<String>] = [
        "en": ["um", "uh", "uhm", "uhh", "umm", "er", "erm", "hmm", "hm", "mm", "mmm", "ah", "eh"],
        "it": ["ehm", "eh", "ehh", "mmm", "uhm", "uh", "hmm", "ah"],
        "tr": ["şey", "ee", "eee", "ıı", "hmm", "ııı", "eh"],
    ]

    public static func isHesitation(_ token: String, lang: String) -> Bool {
        (hesitationWords[lang] ?? hesitationWords["en"]!).contains(token)
    }

    /// True when the text ends in a filler word ("could you um"): the speaker is mid-thought.
    public static func endsWithHesitation(_ text: String, lang: String = "en") -> Bool {
        guard let last = Text.tokens(text, lang: lang).last else { return false }
        return isHesitation(last, lang: lang)
    }

    /// True when the text is nothing but fillers (or empty).
    public static func isOnlyHesitation(_ text: String, lang: String = "en") -> Bool {
        let t = Text.tokens(text, lang: lang)
        return t.allSatisfy { isHesitation($0, lang: lang) }
    }

    // MARK: cue

    private static let enWh: Set<String> = ["what", "why", "how", "when", "where", "which", "who", "whom", "whose", "what's", "how's", "who's"]
    private static let enAux: Set<String> = ["do", "does", "did", "can", "could", "would", "will", "is", "are", "have", "has",
                                             "should", "was", "were", "may", "shall"]
    private static let enImperative: Set<String> = ["explain", "describe", "tell", "walk", "talk", "give", "share", "elaborate"]
    /// Words that may sit in front of a clause without changing where the clause "starts" ("so, what ...").
    private static let enLeaders: Set<String> = ["and", "so", "but", "okay", "ok", "well", "alright", "then", "now", "also", "yeah",
                                                 "um", "uh", "right", "great", "thanks", "thank", "sure", "good", "oh", "hey", "hi",
                                                 "hello", "perfect", "nice", "cool"]
    private static let itCue: Set<String> = ["come", "perché", "perche", "quando", "dove", "quale", "quali", "può", "potrebbe"]
    private static let trCue: Set<String> = ["mı", "mi", "mu", "mü", "nasıl", "neden", "hangi"]

    /// True when the text carries a question signal. Hesitation-only tails never set it.
    public static func hasCue(_ text: String, lang: String = "en") -> Bool {
        let w = Text.words(text, lang: lang)
        guard let last = w.last, !isHesitation(last.text, lang: lang) else { return false }
        let t = w.map(\.text)
        switch lang {
        case "it": return t.contains { itCue.contains($0) }
        case "tr":
            if t.contains(where: { trCue.contains($0) }) { return true }
            return zip(t, t.dropFirst()).contains { $0 == "ne" && $1 == "zaman" }
        default: return englishCue(w)
        }
    }

    private static func englishCue(_ w: [Word]) -> Bool {
        let t = w.map(\.text)
        let n = t.count
        guard n >= 2 else { return false }
        // Clause starts: the beginning, after punctuation, or after leader words ("so what ...").
        var isStart = [Bool](repeating: false, count: n)
        for i in 0..<n {
            isStart[i] = i == 0 || w[i].afterBoundary || (enLeaders.contains(t[i - 1]) && isStart[i - 1])
        }
        for i in 0..<n {
            if isStart[i], i + 1 < n {
                if enWh.contains(t[i]) || enAux.contains(t[i]) || enImperative.contains(t[i]) { return true }
            }
            // Anywhere: "<aux> you", "tell me", "walk me through".
            if i + 1 < n {
                if enAux.contains(t[i]) && (t[i + 1] == "you" || t[i + 1] == "your") { return true }
                if (t[i] == "tell" || t[i] == "talk") && (t[i + 1] == "me" || t[i + 1] == "us") { return true }
                if (t[i] == "walk" || t[i] == "take") && i + 2 < n && (t[i + 1] == "me" || t[i + 1] == "us") && t[i + 2] == "through" { return true }
            }
        }
        return false
    }

    // MARK: complete clause

    private static let incomplete: [String: Set<String>] = [
        "en": ["and", "or", "but", "so", "because", "although", "while", "if", "which", "who", "whom", "whose", "when", "where", "than", "as",
               "of", "to", "in", "on", "at", "by", "for", "with", "from", "about", "into", "over", "under", "through", "during",
               "between", "among", "after", "before", "the", "a", "an", "my", "your", "our", "their", "his", "her", "its", "any",
               "some", "each", "every", "whether", "like", "also", "then", "is", "are", "was", "were", "do", "does", "did", "can",
               "could", "would", "will", "have", "has", "had", "should", "what", "how", "why", "not", "i", "we", "they", "he", "she"],
        "it": ["e", "ed", "o", "ma", "che", "di", "da", "del", "della", "dei", "delle", "nel", "nella", "nei", "in", "con", "per", "su",
               "tra", "fra", "il", "lo", "la", "i", "gli", "le", "un", "una", "uno", "come", "perché", "se", "quando", "dove", "a"],
        "tr": ["ve", "ile", "ama", "fakat", "ki", "için", "gibi", "kadar", "de", "da", "bir", "veya", "ya", "çünkü", "ne"],
    ]

    /// True when the text ends with a content word, not a conjunction, preposition, determiner or bare auxiliary.
    /// (A trailing filler is "not complete" too.)
    public static func endsComplete(_ text: String, lang: String = "en") -> Bool {
        let t = Text.tokens(text, lang: lang)
        guard let last = t.last else { return false }
        if isHesitation(last, lang: lang) { return false }
        // "Can you" is unfinished, "Why should we hire you" is not.
        if lang == "en", last == "you" { return t.count >= 4 }
        return !(incomplete[lang] ?? incomplete["en"]!).contains(last)
    }
}
