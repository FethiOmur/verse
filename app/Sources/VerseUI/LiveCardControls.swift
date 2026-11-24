import Foundation

// The live controls on the island's answer card (owner, 24 Nov 2026): Regenerate (⌥⌘R) and the BAD mark (⌥⌘↓). Both
// act on the card on screen, the live one or an earlier one reached with Back. Pure values; `OverlayModel` holds them and the
// controller sends what they decide to the brain.

/// The owner's mark on an answer card. Only BAD exists in the app (owner, 24 Nov 2026: no GOOD mark); the brain still reads a
/// "good" value from older events, but nothing here writes it.
public enum CardMark: String, Sendable, Equatable {
    case bad
}

/// One mark change for the brain: `card_mark{card, mark, turn, question}` on the wire (`BrainCommand.cardMark`). `mark` is
/// "bad" or "cleared" (the same mark pressed again).
public struct CardMarkEvent: Sendable, Equatable {
    public var card: String
    public var mark: String
    public var turn: String
    public var question: String
}

/// The marks of the running session, by card. Pressing a mark sets it; pressing it again clears it. A mark belongs to the card
/// the island shows (`AnswerHistory.key`), not to the id it was sent under: a card that showed only the bank's opener (`P-<turn>`)
/// keeps its mark when the call's lines replace the opener, and the next press clears the mark under the old id, so the brain
/// never keeps a mark the owner took back.
public struct CardMarks: Sendable, Equatable {
    /// The mark of each card, by `AnswerHistory.key`.
    public private(set) var marks: [String: CardMark] = [:]
    /// The id each mark was sent under (`cardID(for:)` at the press), by `AnswerHistory.key`.
    private var sentAs: [String: String] = [:]

    public init() {}

    /// The id a mark names: the call id of what the card shows (as in the brain's `card` / `card_done` lines), or, for a card that
    /// only shows the bank's opener so far, `P-<turn>` (no call has run for it; the review then finds the card by its turn).
    public static func cardID(for card: OverlayCard) -> String {
        card.cardID ?? "P-" + card.turnID
    }

    public func mark(for card: OverlayCard) -> CardMark? { marks[AnswerHistory.key(for: card)] }

    /// Sets `mark` on `card`, or clears it (a `cleared` for the id the mark was sent under, which may no longer be the card's id);
    /// returns the change to record.
    public mutating func press(_ mark: CardMark, on card: OverlayCard) -> [CardMarkEvent] {
        let key = AnswerHistory.key(for: card)
        let id = Self.cardID(for: card)
        let event = { (sent: String, wire: String) in CardMarkEvent(card: sent, mark: wire, turn: card.turnID, question: card.question) }
        if let old = sentAs[key], marks[key] != nil {
            marks[key] = nil
            sentAs[key] = nil
            return [event(old, "cleared")]
        }
        marks[key] = mark
        sentAs[key] = id
        return [event(id, mark.rawValue)]
    }
}

/// What a press of Regenerate asks the brain for: `control regenerate{turn, question, lang, reset, avoid}`.
public struct RegenerateRequest: Sendable, Equatable {
    /// The turn whose question is answered again (the card on screen's).
    public var turn: String
    public var question: String
    /// The language of the new answer; nil: whatever the brain would use for that turn.
    public var lang: String?
    /// The dominant language is reset to `lang` (the answer on screen was in another language).
    public var reset: Bool
    /// The SAY line on screen: the new answer is a fresh variant of it, not the same text.
    public var avoid: String?
}

public enum RegenerateRule {
    /// The language rule of Regenerate (owner, item 9). `dominant` is the call's dominant language in the owner's sense: the
    /// language of most of the other side's speech so far (`OverlayState.majorityLang`), not the language the cards were last
    /// flipped to. The answer on screen is not in it: the new answer is in it and the automatic language is reset to it (an
    /// Italian card in a mostly English call: English, and AUTO back to English). Otherwise a fresh variant in the same language.
    /// With AUTO off (`dominant` nil) the card's own language holds.
    public static func language(answer: String?, dominant: String?) -> (lang: String?, reset: Bool) {
        guard let dominant else { return (answer, false) }
        guard let answer else { return (dominant, false) }
        return answer == dominant ? (answer, false) : (dominant, true)
    }

    public static func request(for card: OverlayCard, dominant: String?) -> RegenerateRequest {
        let l = language(answer: card.answerLang, dominant: dominant)
        return RegenerateRequest(turn: card.turnID, question: card.question, lang: l.lang, reset: l.reset, avoid: card.say)
    }

    /// A regenerate the brain never confirms (the brain restarted, a line lost) stops blocking the next one after this long.
    public static let inFlightTimeout: TimeInterval = 30
}
