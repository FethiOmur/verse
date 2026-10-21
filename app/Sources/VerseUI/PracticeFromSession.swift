import Foundation

/// The Practise button of a session's detail on the Sessions page: which sessions get it, and how loud it is.
///
/// It opens the Practice page with the session chosen as "A meeting" (`HomeRouter.showPractice(session:)` ->
/// `SimSetupView.takeRequestedMeeting` -> `SimController.practise(session:)`), the same road as Up next's Practise. It never builds
/// or starts the interview by itself: building is a paid brain call, and the Practice page owns its guards (a meeting running, a
/// practice already running, a voice without its key) and the messages for them.
enum PracticeFromSession {
    enum Style: Equatable, Sendable {
        /// A prepared session that was never used in a meeting: the lime button of the header.
        case prominent
        /// A past meeting that has a pack: a neutral button.
        case secondary
    }

    /// `pack.md` is non-empty: the same test `PracticeMeetings.list` uses to call a session prepared.
    static func hasPack(_ session: HomeSession) -> Bool {
        let pack = session.dir.appendingPathComponent("pack.md")
        let size = (try? FileManager.default.attributesOfItem(atPath: pack.path))?[.size] as? Int
        return (size ?? 0) > 0
    }

    /// nil when the session gets no button: practice runs (`sim-`), unprepared calls (`adhoc-`), the standing general prep, a
    /// session without a pack, and the session being recorded right now.
    static func style(for session: HomeSession, hasPack: Bool, recordingSession: String?) -> Style? {
        guard PracticeMeetings.isEligibleName(session.name), hasPack, session.name != recordingSession else { return nil }
        switch session.kind {
        case .prepared: return .prominent
        case .meeting: return .secondary
        case .practice, .call: return nil
        }
    }

    /// The button the detail shows for `session`, reading the pack from disk.
    static func style(for session: HomeSession, recordingSession: String?) -> Style? {
        style(for: session, hasPack: hasPack(session), recordingSession: recordingSession)
    }

    /// The symbol of the Practice sidebar item, so the button reads as the same thing.
    static let symbol = HomePage.practice.symbol
}
