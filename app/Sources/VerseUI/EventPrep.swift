import Foundation
import VerseMeet

/// The app's calendar-event prep: the real model run (`CalendarPrep.live`), never the offline fake. The brain reads the
/// Anthropic key from the Keychain itself; nothing here touches it or puts it on a command line.
public enum EventPrep {
    /// Builds the prep for a brain folder. Tests pass their own (a fake with a recording runner) to stay offline.
    public typealias Make = @Sendable (URL) -> CalendarPrep

    public static let live: Make = { CalendarPrep.live(brainDir: $0) }

    /// The `prepare` closure `HomeUpNextModel` and `MeetingCoordinator` default to.
    public static func prepare(brainDir: URL?, make: @escaping Make = EventPrep.live) -> @Sendable (MeetingEvent, String) async throws -> URL {
        { event, lang in
            guard let brain = brainDir else { throw CalendarPrepError.brainDirNotFound("(not found)") }
            return try await make(brain).makeSession(for: event, lang: lang)
        }
    }
}
