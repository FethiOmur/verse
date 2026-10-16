import Foundation

/// The two buttons of a notch prompt.
public enum PromptAction: Equatable, Sendable {
    /// "Start" / "Save" / "OK": the left, prominent button.
    case accept
    /// "Dismiss" / "Not now": the quiet button.
    case dismiss
}

/// A question under the notch with a prominent button and a quiet one. Pure value: the overlay draws it, the
/// `MeetingCoordinator` makes it and answers the buttons. It is not a runner event and no click is implied: nothing
/// happens until a button is pressed.
public struct MeetingPrompt: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A call started (the meeting app's microphone is running): "Meeting detected · Start Verse?".
        case detected
        /// A calendar event with a video link starts soon: "Meeting in 4 min · Start Verse?".
        case upcoming
        /// A session ended with a `summary.md`: "Save summary to vault?".
        case saveSummary
        /// The summary was written (information; the button closes it).
        case saved
    }

    public var kind: Kind
    public var title: String
    public var subtitle: String
    public var acceptLabel: String
    /// nil: only the accept button (information).
    public var dismissLabel: String?
    /// Work in progress after the accept button ("Preparing from the invite…"): both buttons wait.
    public var busy: Bool
    /// The island's layout of a start prompt (UI redesign spec 3.2, state 0): a small meta line ("Comet is using the
    /// microphone"), the meeting title, and one line of what Start will use. nil: the island shows `title` and
    /// `subtitle` as they are.
    public var eyebrow: String?
    public var headline: String?
    public var detailLine: String?

    public init(kind: Kind, title: String, subtitle: String, acceptLabel: String, dismissLabel: String? = nil, busy: Bool = false,
                eyebrow: String? = nil, headline: String? = nil, detailLine: String? = nil) {
        self.eyebrow = eyebrow
        self.headline = headline
        self.detailLine = detailLine
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.acceptLabel = acceptLabel
        self.dismissLabel = dismissLabel
        self.busy = busy
    }

    // MARK: start prompts

    /// How a start prompt names the session it will use.
    public enum SessionPlan: Equatable, Sendable {
        /// A session folder already exists for this meeting (a remembered one, or one named like the event).
        case prepared(String)
        /// None exists: Start builds one from the calendar invite first.
        case fromInvite
        /// No calendar event: Start uses the session chosen in the menu (nil: none is prepared yet).
        case selected(String?)
    }

    /// "Meeting detected · Start Verse?" with the calendar event and the session it will use underneath.
    public static func detected(appName: String, eventTitle: String?, plan: SessionPlan, questionCount: Int? = nil) -> MeetingPrompt {
        MeetingPrompt(kind: .detected, title: "Meeting detected · Start Verse?",
                      subtitle: subtitle(app: appName, eventTitle: eventTitle, plan: plan),
                      acceptLabel: "Start", dismissLabel: "Dismiss",
                      eyebrow: "\(appName) is using the microphone", headline: eventTitle ?? "Meeting detected",
                      detailLine: detailLine(plan: plan, questionCount: questionCount))
    }

    /// The same question ahead of a meeting that has not begun: ready before he joins.
    public static func upcoming(eventTitle: String, minutes: Int, plan: SessionPlan, questionCount: Int? = nil) -> MeetingPrompt {
        let when = minutes <= 0 ? "Meeting now" : "Meeting in \(minutes) min"
        return MeetingPrompt(kind: .upcoming, title: "\(when) · Start Verse?",
                             subtitle: subtitle(app: nil, eventTitle: eventTitle, plan: plan),
                             acceptLabel: "Start", dismissLabel: "Dismiss",
                             eyebrow: when, headline: eventTitle, detailLine: detailLine(plan: plan, questionCount: questionCount))
    }

    /// "Prepared · 14 questions" (or the session's name when the count is not known), "Prepares a session from the invite".
    private static func detailLine(plan: SessionPlan, questionCount: Int?) -> String {
        func prepared(_ name: String) -> String {
            if let n = questionCount { return "Prepared · \(n) question\(n == 1 ? "" : "s")" }
            return "Prepared · \(name)"
        }
        switch plan {
        case .prepared(let name): return prepared(name)
        case .fromInvite: return "Prepares a session from the invite"
        case .selected(let name?): return prepared(name)
        case .selected(nil): return "No session prepared yet"
        }
    }

    private static func subtitle(app: String?, eventTitle: String?, plan: SessionPlan) -> String {
        let head = [eventTitle, app].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let tail: String
        switch plan {
        case .prepared(let name): tail = "session \(name)"
        case .fromInvite: tail = "prepares a session from the invite"
        case .selected(let name?): tail = "session \(name)"
        case .selected(nil): tail = "no session prepared yet"
        }
        return head.isEmpty ? tail : head + "\n" + tail
    }

    /// The accept button was pressed and a session is being prepared.
    public func preparing() -> MeetingPrompt {
        var p = self
        p.subtitle = "Preparing a session from the invite…"
        p.busy = true
        return p
    }

    // MARK: summary prompts

    public static func saveSummary(session: String, folder: String) -> MeetingPrompt {
        MeetingPrompt(kind: .saveSummary, title: "Save summary to vault?",
                      subtitle: "\(session)\nWrites a new note to \(folder)",
                      acceptLabel: "Save", dismissLabel: "Not now")
    }

    public static func saved(path: String) -> MeetingPrompt {
        MeetingPrompt(kind: .saved, title: "Summary saved", subtitle: path, acceptLabel: "OK")
    }

    public static func saveFailed(_ message: String) -> MeetingPrompt {
        MeetingPrompt(kind: .saved, title: "Summary not saved", subtitle: message, acceptLabel: "OK")
    }
}
