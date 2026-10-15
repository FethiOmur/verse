import Foundation

/// A me result the text guard discarded (text and times only).
public struct EchoDrop: Sendable, Equatable {
    public var text: String
    public var isFinal: Bool
    public var audioStart: Double
    public var audioEnd: Double
    public var at: Double
    /// Share of the me words found, in order, in what the remote channel said around the same time (0...1).
    public var similarity: Double
}

/// Second line of defense against speaker bleed (the first one is the envelope gate in `ListenSession`, VerseSpeech): a
/// microphone result whose words are, in order, mostly the words the remote channel said at about the same time is the
/// remote voice coming out of the speakers, not Alex.
///
/// It works on text and audio times only, so it does not depend on loudness, on the room, or on how well the two envelopes
/// line up (the gate needs the lag within 80 ms and a clean 10 ms envelope). It remembers the last `retainSeconds` of
/// remote results (each with the audio range the recognizer gave it) and compares a me result with those that overlap
/// its range widened by `windowSeconds`.
public struct EchoGuard: Sendable {
    struct Span: Sendable {
        var start: Double
        var end: Double
        var tokens: [String]
        var at: Double
    }

    private(set) var spans: [Span] = []
    let retainSeconds = 20.0

    public init() {}

    /// Remote result: a later result for the same audio range replaces the earlier one (volatile text grows).
    mutating func noteRemote(text: String, start: Double, end: Double, now: Double, lang: String) {
        let tokens = Text.tokens(text, lang: lang)
        guard !tokens.isEmpty else { return }
        spans.removeAll { s in
            let overlap = min(s.end, end) - max(s.start, start)
            if overlap <= 0 { return abs(s.start - start) < 0.02 }
            return overlap >= 0.5 * max(min(s.end - s.start, end - start), 0.02) || (s.start >= start - 0.05 && s.start < end)
        }
        spans.append(Span(start: start, end: end, tokens: tokens, at: now))
        spans.removeAll { now - $0.at > retainSeconds }
    }

    /// Similarity of a me result to the remote speech around it, nil when the remote channel said nothing near it or the
    /// result has fewer than `minWords` words (a single common word such as "you" proves nothing).
    func similarity(text: String, start: Double, end: Double, windowSeconds: Double, minWords: Int, lang: String) -> Double? {
        let mine = Text.tokens(text, lang: lang)
        guard mine.count >= max(minWords, 1) else { return nil }
        let near = spans.filter { $0.end >= start - windowSeconds && $0.start <= end + windowSeconds }.sorted { $0.start < $1.start }
        let theirs = near.flatMap(\.tokens)
        guard !theirs.isEmpty else { return nil }
        return Double(Self.lcs(mine, theirs)) / Double(mine.count)
    }

    /// Words match when equal, or one letter apart on words of 5+ letters ("country" / "countries" are two apart and do
    /// not match, "labelled" / "labeled" do).
    public static func sameWord(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count >= 5, b.count >= 5, abs(a.count - b.count) <= 1 else { return false }
        return Text.editDistance(a.map(String.init), b.map(String.init)) <= 1
    }

    public static func lcs(_ a: [String], _ b: [String]) -> Int {
        var prev = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var cur = [0]
            for (j, y) in b.enumerated() {
                cur.append(sameWord(x, y) ? prev[j] + 1 : max(prev[j + 1], cur[j]))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
