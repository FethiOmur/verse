import Foundation

/// One answer the notch showed during the running session.
public struct AnswerEntry: Equatable, Sendable {
    /// Which card this is (`AnswerHistory.key(for:)`): one entry per card, however often its text streamed.
    public var key: String
    /// Arrival order in the session; never reused, so "newer than" survives evictions.
    public var seq: Int
    /// The card as the notch last showed it.
    public var card: OverlayCard
}

/// The answers the notch showed in the running session, and whether the island shows the live state or one of them.
///
/// It sits beside the overlay's reducer, not in it: it only watches the card the reducer decided to show (`observe`), so
/// nothing about listening, turns or answer generation depends on it. Pure value; tests drive it directly.
///
/// - Live (default): the island shows whatever the reducer shows.
/// - Pinned: the island shows one entry, found by its key, so the same entry stays on screen while new answers keep
///   arriving and being recorded. Nothing returns to live by itself; only `forward`, `returnToLive` or `clear` do.
public struct AnswerHistory: Equatable, Sendable {
    /// How many answers are kept. A pinned entry is never the one that goes.
    public static let capacity = 10

    public private(set) var entries: [AnswerEntry] = []
    /// The pinned entry's key; nil while live.
    public private(set) var pinnedKey: String?
    /// The key of the entry the live card is, while the live card shows an answer; nil when the live card is empty, still
    /// being heard, or closed.
    public private(set) var liveKey: String?
    private var nextSeq = 0
    /// The newest entry when pinning began (from live): later entries are "newer ones arrived".
    private var pinnedAtSeq: Int?

    public init() {}

    // MARK: identity

    /// One key per displayed card: the turn, and for "follow my answer" the follow card on screen (a follow card replaces
    /// the answer's text, so it is an answer of its own and the original stays in the history as it was).
    public static func key(for card: OverlayCard) -> String {
        guard card.following, let follow = card.followCardID else { return card.turnID }
        return card.turnID + "|C|" + follow
    }

    /// A card shows an answer once it has a SAY line or a point (a card that only shows the heard question does not).
    public static func isAnswer(_ card: OverlayCard) -> Bool { card.say != nil || !card.bullets.isEmpty }

    // MARK: recording

    /// The card the reducer shows now (after every change). An answer card adds an entry, or updates its own entry when it
    /// streams; anything else only notes that the live island shows no entry.
    public mutating func observe(_ card: OverlayCard?) {
        guard let card, Self.isAnswer(card) else {
            liveKey = nil
            return
        }
        liveKey = Self.key(for: card)
        record(card)
    }

    /// A card that streams off screen (a regenerated card holds the island): it updates its own entry, or adds one once it shows an
    /// answer. What the live island shows (`liveKey`) does not change.
    public mutating func record(_ card: OverlayCard) {
        guard Self.isAnswer(card) else { return }
        let key = Self.key(for: card)
        if let i = entries.firstIndex(where: { $0.key == key }) {
            if entries[i].card != card { entries[i].card = card }
            return
        }
        entries.append(AnswerEntry(key: key, seq: nextSeq, card: card))
        nextSeq += 1
        trim()
    }

    /// Keeps `capacity` entries: the oldest that is not pinned goes.
    private mutating func trim() {
        while entries.count > Self.capacity {
            guard let i = entries.firstIndex(where: { $0.key != pinnedKey }) else { return }
            entries.remove(at: i)
        }
    }

    /// The session stopped or a new one started: nothing is kept, the island is live.
    public mutating func clear() {
        self = AnswerHistory()
    }

    // MARK: viewing

    public var isPinned: Bool { pinnedKey != nil }

    /// The entry on screen while pinned.
    public var pinned: AnswerEntry? {
        guard let pinnedKey else { return nil }
        return entries.first { $0.key == pinnedKey }
    }

    private var pinnedIndex: Int? {
        guard let pinnedKey else { return nil }
        return entries.firstIndex { $0.key == pinnedKey }
    }

    /// While pinned: answers arrived after pinning began.
    public var hasNewerSincePin: Bool {
        guard isPinned, let since = pinnedAtSeq else { return false }
        return entries.contains { $0.seq > since }
    }

    /// The entry one step back from what the island shows now, if there is one. Live, the island shows the newest entry
    /// when it is the live card, so one back is the one before it; when the live card shows no answer (closed, or a new
    /// question still being heard), one back is the newest entry itself.
    private var backTarget: Int? {
        if let i = pinnedIndex { return i > 0 ? i - 1 : nil }
        guard let last = entries.indices.last else { return nil }
        if entries[last].key == liveKey { return last > 0 ? last - 1 : nil }
        return last
    }

    public var canGoBack: Bool { backTarget != nil }

    /// Forward is offered only while pinned (live is already the newest).
    public var canGoForward: Bool { isPinned }

    /// The next forward step returns to live (the pinned entry is the newest, or the one just before the live card).
    public var forwardReturnsToLive: Bool {
        guard let i = pinnedIndex else { return false }
        return i + 1 >= entries.count || entries[i + 1].key == liveKey
    }

    /// One entry older. At the oldest entry nothing happens.
    public mutating func back() {
        guard let target = backTarget else { return }
        if !isPinned { pinnedAtSeq = entries.last?.seq }
        pinnedKey = entries[target].key
    }

    /// One entry newer; past the newest (or onto the entry the live card is) the island is live again.
    public mutating func forward() {
        guard let i = pinnedIndex else { return }
        if forwardReturnsToLive {
            returnToLive()
        } else {
            pinnedKey = entries[i + 1].key
        }
    }

    public mutating func returnToLive() {
        pinnedKey = nil
        pinnedAtSeq = nil
    }

    /// What the island draws: the live state, or the live state with the pinned entry's card in place of the live card.
    /// Everything else (status, cues, tags, the running flag) stays live.
    public func display(_ live: OverlayState) -> OverlayState {
        guard let entry = pinned else { return live }
        var s = live
        s.card = entry.card
        return s
    }

    /// The quiet line on a pinned card.
    public var marker: String? {
        guard isPinned else { return nil }
        return hasNewerSincePin ? L10n.tr("Earlier answer · newer ones arrived") : L10n.tr("Earlier answer")
    }
}
