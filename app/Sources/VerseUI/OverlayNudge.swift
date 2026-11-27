import SwiftUI
import VerseTurns

/// A live nudge (the brain's `nudge` event, docs/specs/2026-11-27-live-nudges-plan.md): a short cue from the prep note for
/// the moment the conversation reaches its topic. Kept apart from the answer card: it never enters the answer history,
/// Regenerate, the marks or the teleprompter.
public struct OverlayNudge: Equatable, Sendable {
    public var id: String
    public var title: String
    /// One to `maxLines` lines, never empty.
    public var lines: [String]
    /// The final turn that triggered it (`r12`, `m3`; a bare number is tolerated). A card that opens for a later turn takes the
    /// nudge down; the card for this same turn keeps it. nil: the event named none, so any card for a new turn is later.
    public var turnID: String?

    /// Lines the island body shows.
    public static let maxLines = 3

    public init(id: String, title: String, lines: [String], turnID: String? = nil) {
        self.id = id
        self.title = title
        self.lines = lines
        self.turnID = turnID
    }

    /// Reads a `nudge` event. Missing or wrong-typed fields are tolerated: no title is an empty title. `ttl_s` is ignored (a
    /// nudge has no timer). No usable line means nothing to show: nil.
    init?(event o: [String: JSONValue]) {
        let lines = (o["lines"]?.array ?? []).compactMap(\.string)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let turn = o[string: "turn_id"] ?? o[double: "turn_id"].flatMap { $0.isFinite ? String(Int($0)) : nil }
        self.init(id: o[string: "id"] ?? "",
                  title: (o[string: "title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                  lines: Array(lines.prefix(Self.maxLines)),
                  turnID: turn.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The text of the amber point on a card: the lines in order, one point.
    public var pointText: String { lines.joined(separator: " ") }

    /// A card opening for `cardTurn` takes this nudge down: it answers a later turn than the one that triggered the nudge. The
    /// same turn keeps it (its card may open just before or just after the nudge). Turn ids are `<letter><count>` per speaker
    /// (`r12` the other side, `m3` the owner): the same letter (or a bare number) compares by count, so a late card for an older
    /// turn keeps the nudge; different letters cannot be ordered, and the card, opened after the nudge, is taken as later.
    func isOutdated(byCardFor cardTurn: String) -> Bool {
        guard let own = turnID else { return true }
        if own == cardTurn { return false }
        let a = Self.split(own), b = Self.split(cardTurn)
        guard let na = a.count, let nb = b.count else { return true }
        if a.prefix == b.prefix || a.prefix.isEmpty || b.prefix.isEmpty { return nb > na }
        return true
    }

    /// `r12` -> ("r", 12); `41` -> ("", 41); `now-3` -> ("now-", 3); text without a trailing number -> (text, nil).
    static func split(_ id: String) -> (prefix: String, count: Int?) {
        let digits = id.reversed().prefix { $0.isNumber }
        guard !digits.isEmpty, let n = Int(String(digits.reversed())) else { return (id, nil) }
        return (String(id.dropLast(digits.count)), n)
    }
}

// MARK: - Views

/// The amber "CUE" label: the caption type in the amber of the status dots.
private struct NudgeLabel: View {
    var body: some View {
        Text("CUE", bundle: .module)
            .font(VT.Font.caption)
            .foregroundStyle(VT.amber)
    }
}

/// The nudge as the island body (no card open): the "CUE" label, the title in the points' size, semibold, and up to three
/// lines in the card's point list. A tap dismisses the nudge only.
struct NudgeBodyView: View {
    var nudge: OverlayNudge
    var scale: CGFloat
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NudgeLabel()
            if !nudge.title.isEmpty {
                Text(verbatim: nudge.title)
                    .font(.system(size: (15 * scale).rounded(), weight: .semibold))
                    .foregroundStyle(VT.Island.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            PointList(points: Array(nudge.lines.prefix(OverlayNudge.maxLines)), scale: scale)
                .padding(.top, nudge.title.isEmpty ? 6 : 8)
        }
        .islandBody(.panel)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Dismisses the cue", bundle: .module))
        .accessibilityAction { onDismiss() }
        .accessibilityIdentifier("verse.nudge")
    }
}
