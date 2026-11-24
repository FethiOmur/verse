import Foundation
import VerseMeet

/// When the background prep may start, and for which meeting (owner decision 3). Pure: time, the meetings and the facts come in.
public enum AutoPrepGate {
    /// An attempt is remembered this long, then forgotten (the meeting is long over by then).
    public static let rememberAttempts: TimeInterval = 3 * 86_400
    /// Background preps started per local day at most (each costs a paid model call). Prepare by hand is never capped.
    public static let dailyCap = 5

    /// The meeting to prepare now, or nil: the setting is on, nothing is under way (`busy`: a run, a stop, a switch, the practice
    /// interview or a meeting prompt), no prep is running, and a real meeting that he organises or accepted
    /// (`MeetingEvent.ownerConfirmed`: an invite anyone can send shows in his calendar before he answers it), has not started
    /// yet, starts within the lookahead and has no session (`matched`: its occurrence key has one) was not tried before
    /// (`attempted`). The soonest wins; one at a time. The daily cap is checked apart (`capReached`).
    public static func candidate(now: Date, enabled: Bool, busy: Bool, upcoming: [MeetingEvent], matched: Set<String>,
                                 attempted: Set<String>, inFlight: Set<String>,
                                 lookahead: TimeInterval = SessionAutoSelect.lookahead) -> MeetingEvent? {
        guard enabled, !busy, inFlight.isEmpty else { return nil }
        return upcoming
            .filter { e in
                e.ownerConfirmed && e.start > now && e.start <= now.addingTimeInterval(lookahead) && RealMeeting.isReal(e)
                    && !matched.contains(e.occurrenceKey) && !attempted.contains(e.occurrenceKey)
            }
            .min { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// The background preps of `now`'s local day among `runs`.
    public static func runsToday(_ runs: [Date], now: Date, calendar: Calendar) -> Int {
        runs.filter { calendar.isDate($0, inSameDayAs: now) }.count
    }

    /// `dailyCap` background preps were started on `now`'s local day.
    public static func capReached(_ runs: [Date], now: Date, calendar: Calendar, cap: Int = dailyCap) -> Bool {
        runsToday(runs, now: now, calendar: calendar) >= cap
    }

    /// `runs` without the ones older than two days (only today's count).
    public static func prunedRuns(_ runs: [Date], now: Date) -> [Date] {
        runs.filter { abs(now.timeIntervalSince($0)) < 2 * 86_400 }
    }

    /// `attempted` without the entries older than `rememberAttempts`.
    public static func pruned(_ attempted: [String: Date], now: Date) -> [String: Date] {
        attempted.filter { now.timeIntervalSince($0.value) < rememberAttempts }
    }
}

/// Runs the background prep from the invite (the same `EventPrep` path Up next's Prepare uses), one meeting at a time, only for
/// meetings he organises or accepted, and at most `AutoPrepGate.dailyCap` a local day (counted across relaunches; at the cap the
/// meeting stays "not prepared" and Prepare by hand still works). Each occurrence is tried once, remembered across relaunches; a
/// failed one is not retried by itself (Prepare in the picker or in Up next still can). It never starts while something is under way; a prep that is running when a call starts finishes in the
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
    private let calendar: Calendar
    private let dailyCap: Int
    /// The local day whose cap was already logged (one line a day, not one per 60 s tick).
    private var capLogged: Date?

    public init(settings: MeetingSettings, prepare: @escaping @Sendable (MeetingEvent, String) async throws -> URL,
                language: @escaping () -> String, onPrepared: @escaping @MainActor (MeetingEvent, URL) -> Void,
                log: @escaping (String) -> Void, calendar: Calendar = .current, dailyCap: Int = AutoPrepGate.dailyCap) {
        self.settings = settings
        self.calendar = calendar
        self.dailyCap = dailyCap
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
        let runs = AutoPrepGate.prunedRuns(settings.autoPrepBackgroundRuns, now: now)
        if AutoPrepGate.capReached(runs, now: now, calendar: calendar, cap: dailyCap) {
            if capLogged.map({ !calendar.isDate($0, inSameDayAs: now) }) ?? true {
                capLogged = now
                log("prep from the invite skipped: \(dailyCap) background preps today (the daily cap); Prepare by hand still works")
            }
            return nil
        }
        settings.autoPrepBackgroundRuns = runs + [now]
        run(e, now: now, attempted: attempted, reason: "background")
        return e
    }

    /// Prepare clicked in the picker: the same prep for `event` now, whatever the setting, earlier attempts, his answer to the
    /// invite and the daily cap (it is not counted against the cap either); not while another prep of it runs. The caller checks that nothing is under way.
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
