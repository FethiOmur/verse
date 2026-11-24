import Foundation
import VerseMeet

/// When the background prep may start, and for which meeting (owner decision 3). Pure: time, the meetings and the facts come in.
public enum AutoPrepGate {
    /// An attempt is remembered this long, then forgotten (the meeting is long over by then).
    public static let rememberAttempts: TimeInterval = 3 * 86_400

    /// The meeting to prepare now, or nil: the setting is on, nothing is under way (`busy`: a run, a stop, a switch, the practice
    /// interview or a meeting prompt), no prep is running, and a real meeting that has not started yet, starts within the
    /// lookahead and has no session (`matched`: its occurrence key has one) was not tried before (`attempted`). The soonest wins;
    /// one at a time.
    public static func candidate(now: Date, enabled: Bool, busy: Bool, upcoming: [MeetingEvent], matched: Set<String>,
                                 attempted: Set<String>, inFlight: Set<String>,
                                 lookahead: TimeInterval = SessionAutoSelect.lookahead) -> MeetingEvent? {
        guard enabled, !busy, inFlight.isEmpty else { return nil }
        return upcoming
            .filter { e in
                e.start > now && e.start <= now.addingTimeInterval(lookahead) && RealMeeting.isReal(e)
                    && !matched.contains(e.occurrenceKey) && !attempted.contains(e.occurrenceKey)
            }
            .min { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// `attempted` without the entries older than `rememberAttempts`.
    public static func pruned(_ attempted: [String: Date], now: Date) -> [String: Date] {
        attempted.filter { now.timeIntervalSince($0.value) < rememberAttempts }
    }
}

/// Runs the background prep from the invite (the same `EventPrep` path Up next's Prepare uses), one meeting at a time. Each
/// occurrence is tried once, remembered across relaunches; a failed one is not retried by itself (Prepare in the picker or in Up
/// next still can). It never starts while something is under way; a prep that is running when a call starts finishes in the
/// background, and its session is then recorded but not selected under the call.
@MainActor
public final class MeetingAutoPrep: ObservableObject {
    /// Occurrence keys being prepared now (the pickers show "Preparing…").
    @Published public private(set) var inFlight: Set<String> = []
    /// The last failure, for the log and the picker; nil after a success.
    @Published public private(set) var lastError: String?

    private let settings: MeetingSettings
    private let prepare: @Sendable (MeetingEvent, String) async throws -> URL
    private let language: () -> String
    private let onPrepared: @MainActor (MeetingEvent, URL) -> Void
    private let log: (String) -> Void

    public init(settings: MeetingSettings, prepare: @escaping @Sendable (MeetingEvent, String) async throws -> URL,
                language: @escaping () -> String, onPrepared: @escaping @MainActor (MeetingEvent, URL) -> Void,
                log: @escaping (String) -> Void) {
        self.settings = settings
        self.prepare = prepare
        self.language = language
        self.onPrepared = onPrepared
        self.log = log
    }

    /// One look: starts the prep of `AutoPrepGate.candidate`, if any. Returns the meeting it started for.
    @discardableResult
    public func consider(now: Date, busy: Bool, upcoming: [MeetingEvent], matched: Set<String>) -> MeetingEvent? {
        let attempted = AutoPrepGate.pruned(settings.autoPrepAttempted, now: now)
        guard let e = AutoPrepGate.candidate(now: now, enabled: settings.autoPrepare && settings.useCalendar, busy: busy,
                                             upcoming: upcoming, matched: matched, attempted: Set(attempted.keys),
                                             inFlight: inFlight) else { return nil }
        run(e, now: now, attempted: attempted, reason: "background")
        return e
    }

    /// Prepare clicked in the picker: the same prep for `event` now, whatever the setting and earlier attempts; not while
    /// another prep of it runs. The caller checks that nothing is under way.
    public func prepareNow(_ event: MeetingEvent, now: Date) {
        guard !inFlight.contains(event.occurrenceKey) else { return }
        run(event, now: now, attempted: AutoPrepGate.pruned(settings.autoPrepAttempted, now: now), reason: "by hand")
    }

    /// A prep of `event` was started elsewhere (Up next's Prepare, Practice): the background prep leaves it alone.
    public func noteAttempt(_ event: MeetingEvent, now: Date) {
        var attempted = AutoPrepGate.pruned(settings.autoPrepAttempted, now: now)
        attempted[event.occurrenceKey] = now
        settings.autoPrepAttempted = attempted
    }

    private func run(_ event: MeetingEvent, now: Date, attempted: [String: Date], reason: String) {
        let key = event.occurrenceKey
        var attempted = attempted
        attempted[key] = now
        settings.autoPrepAttempted = attempted
        inFlight.insert(key)
        lastError = nil
        log("prep from the invite started (\(reason)) for \(key)")
        let lang = language()
        let prepare = self.prepare
        Task { @MainActor [weak self] in
            let result: Result<URL, any Error>
            do { result = .success(try await prepare(event, lang)) } catch { result = .failure(error) }
            guard let self else { return }
            self.inFlight.remove(key)
            switch result {
            case .success(let dir):
                self.log("prep from the invite done for \(key): \(dir.lastPathComponent)")
                self.onPrepared(event, dir)
            case .failure(let error):
                self.lastError = String(describing: error)
                self.log("prep from the invite failed for \(key): \(error)")
            }
        }
    }
}
