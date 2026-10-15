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
                // "Any questions?" / "Any questions for us" (no auxiliary in front).
                if t[i] == "any" && t[i + 1].hasPrefix("question") { return true }
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

    // MARK: fragment / kind

    /// Words a finished clause does not end on: conjunctions, articles and determiners, prepositions and subject
    /// pronouns. A turn that ends on one is cut off mid-clause ("... and we").
    private static let fragmentEnders: [String: Set<String>] = [
        "en": ["and", "or", "but", "so", "because", "although", "though", "while", "if", "unless", "whether", "since", "until",
               "as", "than", "which", "who", "whom", "whose", "when", "where", "also", "then", "not",
               "the", "a", "an", "my", "your", "our", "their", "his", "her", "its", "any", "some", "each", "every",
               "of", "to", "in", "on", "at", "by", "for", "with", "from", "about", "into", "over", "under", "through", "during",
               "between", "among", "after", "before", "like", "around", "against", "without", "within", "toward", "towards",
               "i", "we", "they", "he", "she", "i'm", "we're", "they're", "i've", "we've", "they've", "i'd", "we'd", "i'll", "we'll"],
        "it": ["e", "ed", "o", "ma", "che", "di", "da", "del", "della", "dei", "delle", "nel", "nella", "nei", "in", "con", "per", "su",
               "tra", "fra", "il", "lo", "la", "i", "gli", "le", "un", "una", "uno", "se", "perché", "perche", "a", "io", "noi", "loro", "lui", "lei"],
        "tr": ["ve", "ile", "ama", "fakat", "ki", "için", "gibi", "kadar", "bir", "veya", "ya", "çünkü", "ben", "biz", "onlar"],
    ]

    /// Prepositions that may end a finished wh-question ("Where are you from", "What are you working on").
    private static let strandedPrepositions: Set<String> = ["from", "on", "with", "about", "for", "at"]

    /// True when the text is not a finished turn yet: fewer than `minWords` words, a filler at the end, or a last word
    /// that no finished clause ends on ("... and we", "... to the"). Sentence-final punctuation from the recognizer
    /// ("." "?" "!") counts as the speaker having finished the clause, but not as enough words.
    public static func isFragment(_ text: String, lang: String = "en", minWords: Int = 3) -> Bool {
        let t = Text.tokens(text, lang: lang)
        guard let last = t.last else { return true }
        if t.count < minWords { return true }
        if isHesitation(last, lang: lang) { return true }
        if let c = text.trimmingCharacters(in: .whitespacesAndNewlines).last, ".?!".contains(c) { return false }
        // "Why should we hire you" is finished, "And you" is not.
        if lang == "en", last == "you" { return t.count < 4 }
        if lang == "en", strandedPrepositions.contains(last), t.count >= 4, enWh.contains(t[0]) { return false }
        return (fragmentEnders[lang] ?? fragmentEnders["en"]!).contains(last)
    }

    /// The kind of a finished turn: fragment (see `isFragment`), question (a question cue or a closing "?"), or statement.
    /// A turn shorter than `minWords` is still a question when it is a complete short question (`isShortQuestion`).
    /// Only the kind changes: `isFragment` (and with it the endpoint hold) is the same for short turns as before.
    public static func kind(of text: String, lang: String = "en", minWords: Int = 3, terms: SessionTerms? = nil) -> TurnKind {
        if isFragment(text, lang: lang, minWords: minWords) {
            return isShortQuestion(text, lang: lang, minWords: minWords, terms: terms) ? .question : .fragment
        }
        if hasCue(text, lang: lang) || text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") { return .question }
        // A noun phrase of up to `minWords` words that names something the session knows ("And notice period").
        if let terms, isNounPhraseQuestion(text, lang: lang, minWords: minWords, terms: terms) { return .question }
        return .statement
    }

    /// Two or `minWords` words, ending where a clause can end, and naming a session term (`SessionTerms.names`).
    /// Only called for turns without a cue and without a "?".
    static func isNounPhraseQuestion(_ text: String, lang: String, minWords: Int, terms: SessionTerms) -> Bool {
        let t = Text.tokens(text, lang: lang)
        guard t.count >= 2, t.count <= minWords, let last = t.last, !isHesitation(last, lang: lang),
              !(fragmentEnders[lang] ?? fragmentEnders["en"]!).contains(last) else { return false }
        if lang == "en", t.allSatisfy({ enLeaders.contains($0) }) { return false }
        return endsComplete(text, lang: lang) && terms.names(text, lang: lang)
    }

    // MARK: short questions

    /// Words that carry no topic of their own (leaders, conjunctions, articles, prepositions, bare auxiliaries,
    /// question words, subject pronouns): what is left of a short turn after these is its content.
    static func functionWords(lang: String) -> Set<String> {
        var out = enLeaders.union(enWh).union(enAux)
        out.formUnion(fragmentEnders[lang] ?? fragmentEnders["en"]!)
        if lang != "en" { out.formUnion(fragmentEnders["en"]!) }
        out.formUnion(["you", "your", "me", "it", "that", "this", "is", "be", "just", "very", "really", "yes", "no"])
        return out
    }

    /// Second words that make a wh-question a cut-off prefix ("Why this", "How big", "How many"): the rest follows.
    private static let openSecondWords: Set<String> = ["this", "that", "these", "those", "big", "long", "many", "much", "often", "far", "old",
                                                       "kind", "sort", "type"]

    /// True for a turn of two words up to `minWords - 1` that is a complete short question ("Why Halden?", "And salary?",
    /// "Any questions"): it carries a question cue (the language's own cues, "any questions", an imperative ask, or
    /// the recognizer's "Y" for "why") or a closing "?", and it does not end where a clause cannot end (a preposition,
    /// conjunction, article, bare auxiliary, "Where do you", a filler) or look like a prefix ("Why this").
    /// One word is never a question here ("Okay.", "Sure?"), and a "?" after nothing but leader words ("Okay, right?") is not either.
    ///
    /// A short noun phrase without a cue or a "?" ("Notice period", "And salary") is a question only when it names
    /// something the session knows (`terms`: a glossary term, a fact, or a phrase of a prepared bank question).
    /// Without `terms` it stays a fragment, as before.
    public static func isShortQuestion(_ text: String, lang: String = "en", minWords: Int = 3, terms: SessionTerms? = nil) -> Bool {
        let w = Text.words(text, lang: lang)
        let t = w.map(\.text)
        guard t.count >= 2, t.count < minWords, let last = t.last, !isHesitation(last, lang: lang) else { return false }
        if (fragmentEnders[lang] ?? fragmentEnders["en"]!).contains(last) { return false }
        let closedByQuestionMark = text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        if lang == "en" {
            if openSecondWords.contains(last), t.count == 2, enWh.contains(t[0]) || t[0] == "y" { return false }
            // Nothing but leaders ("Okay, right?") is an acknowledgement, not a question.
            if t.allSatisfy({ enLeaders.contains($0) }) { return false }
        }
        if closedByQuestionMark { return true }
        // Without a "?" the clause must also end where a question can: "Where do" and "Can you" are cut off.
        guard endsComplete(text, lang: lang) else { return false }
        if hasCue(text, lang: lang) { return true }
        // Nemotron wrote "Why Halden?" as "Y Halden".
        if lang == "en" && t[0] == "y" { return true }
        return terms.map { isNounPhraseQuestion(text, lang: lang, minWords: minWords, terms: $0) } ?? false
    }
}
