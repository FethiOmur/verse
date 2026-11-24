import AppKit
import Combine
import Foundation
import SwiftUI
import VerseMeet

/// Applies `SessionAutoSelect` to `settings.sessionName` on the main actor. It writes only when nothing is under way (no run, stop,
/// route or language switch, practice interview or meeting prompt) and only when the value changes, and logs one line per change.
///
/// UI hooks (published): `target` (the meeting the selection is for), `upcoming` and `matches` (every real meeting in the lookahead and
/// its matched session, by occurrence key), `targetMatch`, `reason` (why the selection is what it is) and `manual` (the live manual pick).
@MainActor
public final class SessionSelector: ObservableObject {
    @Published public private(set) var target: MeetingEvent?
    @Published public private(set) var targetMatch: SessionMatch?
    /// Real meetings that have not ended and start within the lookahead, soonest first (empty with the calendar off).
    @Published public private(set) var upcoming: [MeetingEvent] = []
    /// Occurrence key -> the matched session, for the events in `upcoming` that have one.
    @Published public private(set) var matches: [String: SessionMatch] = [:]
    @Published public private(set) var reason: SessionAutoSelect.Reason = .noMeeting
    /// What Start now's choice (`QuickStart.pickSession`) depends on beyond the session list: the events inside the start window
    /// (from `QuickStart.leadTime` before they start until `QuickStart.afterEnd` after they end) and the manual pick that still
    /// holds. It changes when the clock crosses a window edge (seen on the next 60 s tick) or a pick is made or ends, so the menu's
    /// Start row, which observes the selector, is labelled again then (owner decision 3: the row says what ⌥⌘V does).
    @Published public private(set) var startWindow = StartWindow()

    public struct StartWindow: Equatable, Sendable {
        /// Occurrence keys of the events inside the start window, sorted.
        public var events: [String] = []
        /// The manual pick that still holds (`manualSession(now:)`), if any.
        public var manual: String?
    }

    /// Off for a `--session` launch: the session named on the command line is kept.
    public var autoSelectEnabled = true

    private let settings: AppSettings
    private let busy: () -> Bool
    private let sessions: () -> [String]
    private let readEvents: (Date) -> [MeetingEvent]
    private let loadMatcher: ([String]) -> SessionMatcher
    private let createdAt: ([String]) -> [String: Date]
    private let clock: () -> Date
    private let log: (String) -> Void
    /// The events of the last calendar read; the fallback uses them so it never reads the calendar (it runs inside Start).
    private(set) var events: [MeetingEvent] = []

    public init(settings: AppSettings, busy: @escaping () -> Bool, sessions: @escaping () -> [String],
                readEvents: @escaping (Date) -> [MeetingEvent], loadMatcher: @escaping ([String]) -> SessionMatcher,
                createdAt: @escaping ([String]) -> [String: Date], clock: @escaping () -> Date, log: @escaping (String) -> Void) {
        self.settings = settings
        self.busy = busy
        self.sessions = sessions
        self.readEvents = readEvents
        self.loadMatcher = loadMatcher
        self.createdAt = createdAt
        self.clock = clock
        self.log = log
    }

    public var manual: ManualChoice? { settings.sessionPickManual }

    /// The pickers' binding: reads the selection, and a pick through it is a manual pick (`choose`).
    public var manualBinding: Binding<String> {
        Binding(get: { [settings] in settings.sessionName }, set: { [weak self] in self?.choose($0) })
    }

    /// Reads the calendar and applies the rule. A no-op while something is under way (the calendar is not read then either).
    public func reevaluate() {
        guard !busy() else { return }
        let now = clock()
        let names = sessions()
        events = readEvents(now)
        let matcher = loadMatcher(names)
        publish(now: now, matcher: matcher)
        let d = SessionAutoSelect.pick(now: now, events: events, matcher: matcher, manual: autoSelectEnabled ? manual : nil)
        if reason != d.reason { reason = d.reason }
        // A manual pick that no longer holds is dropped, so it never comes back with an old meeting.
        if let m = manual, d.reason != .manual, autoSelectEnabled {
            settings.sessionPickManual = nil
            log("manual session pick ended: \(m.session)")
        }
        refreshStartWindow(now: now)
        guard autoSelectEnabled, let s = d.select, s != settings.sessionName, names.contains(s) else { return }
        settings.sessionName = s
        log("session auto-selected \(s) for \(d.target?.occurrenceKey ?? "-")")
    }

    /// He picked `session` by hand: it is selected and holds while the current target is the target (see `ManualChoice`).
    public func choose(_ session: String) {
        let now = clock()
        let t = SessionAutoSelect.target(now: now, events: events)
        settings.sessionPickManual = ManualChoice(session: session, targetKey: t?.occurrenceKey, at: now)
        if settings.sessionName != session { settings.sessionName = session }
        if reason != .manual { reason = .manual }
        refreshStartWindow(now: now)
        log("session chosen by hand \(session) for \(t?.occurrenceKey ?? "-")")
    }

    /// A prep finished (G6): the new session is selected only when it belongs to the target meeting, or when no meeting is ahead,
    /// and only when nothing is under way. A prep he asked for (`byHand`: Prepare in Up next, the picker or the Prepare page) is his
    /// latest choice and ends a manual pick; the background prep never overrides a manual pick that still holds (design 4).
    /// Returns whether it was selected.
    @discardableResult
    public func didPrepare(_ name: String, event: MeetingEvent? = nil, byHand: Bool = false) -> Bool {
        let names = sessions()
        guard names.contains(name), !busy() else { return false }
        let now = clock()
        events = readEvents(now)
        let matcher = loadMatcher(names)
        publish(now: now, matcher: matcher)
        let forTarget: Bool
        if let t = target {
            forTarget = event?.occurrenceKey == t.occurrenceKey || matcher.match(t)?.session == name
        } else {
            forTarget = true
        }
        guard forTarget else {
            log("prepared \(name); kept \(settings.sessionName) for \(target?.occurrenceKey ?? "-")")
            return false
        }
        if !byHand, let m = manual, autoSelectEnabled, m.isActive(now: now, targetKey: target?.occurrenceKey) {
            log("prepared \(name); kept the pick by hand \(m.session) for \(target?.occurrenceKey ?? "-")")
            return false
        }
        if settings.sessionPickManual != nil { settings.sessionPickManual = nil }
        if settings.sessionName != name { settings.sessionName = name }
        reason = target.map { .nextMeeting($0.occurrenceKey) } ?? .noMeeting
        refreshStartWindow(now: now)
        log("session selected after prep \(name) for \(target?.occurrenceKey ?? "-")")
        return true
    }

    /// The selected session is gone (G7): the manual pick ends, then the target's session (from the last calendar read), else the
    /// newest session by creation time, else none. Synchronous and deterministic; `refreshSessions` calls it.
    public func selectionMissing() {
        if settings.sessionPickManual != nil { settings.sessionPickManual = nil }
        let names = sessions()
        let matcher = loadMatcher(names)
        let pick = SessionAutoSelect.fallback(now: clock(), events: autoSelectEnabled ? events : [], matcher: matcher,
                                              createdAt: createdAt(names)) ?? ""
        let gone = settings.sessionName
        if settings.sessionName != pick { settings.sessionName = pick }
        reason = .fallback
        refreshStartWindow(now: clock())
        if !gone.isEmpty || !pick.isEmpty { log("selected session gone (\(gone.isEmpty ? "-" : gone)): now \(pick.isEmpty ? "none" : pick)") }
    }

    /// The occurrence key a manual pick that still holds was made for, if any: he chose a session for that meeting, so the
    /// background prep leaves it alone (no paid prep he did not ask for).
    public func manualTargetKey(now: Date) -> String? {
        guard let m = manual, let key = m.targetKey,
              m.isActive(now: now, targetKey: SessionAutoSelect.target(now: now, events: events)?.occurrenceKey) else { return nil }
        return key
    }

    /// The manual pick Start now may use (G4 ii): one that still holds for the last known target, and whose session exists.
    public func manualSession(now: Date) -> String? {
        guard let m = manual, sessions().contains(m.session),
              m.isActive(now: now, targetKey: SessionAutoSelect.target(now: now, events: events)?.occurrenceKey) else { return nil }
        return m.session
    }

    private func refreshStartWindow(now: Date) {
        let near = events.filter { $0.start <= now.addingTimeInterval(QuickStart.leadTime) && $0.end >= now.addingTimeInterval(-QuickStart.afterEnd) }
            .map(\.occurrenceKey).sorted()
        let w = StartWindow(events: near, manual: manualSession(now: now))
        if startWindow != w { startWindow = w }
    }

    private func publish(now: Date, matcher: SessionMatcher) {
        let real = events.filter { $0.end > now && $0.start <= now.addingTimeInterval(SessionAutoSelect.lookahead) && RealMeeting.isReal($0) }
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        var m: [String: SessionMatch] = [:]
        for e in real { if let hit = matcher.match(e) { m[e.occurrenceKey] = hit } }
        let t = SessionAutoSelect.target(now: now, events: events)
        if upcoming != real { upcoming = real }
        if matches != m { matches = m }
        if target != t { target = t }
        let tm = t.flatMap { m[$0.occurrenceKey] }
        if targetMatch != tm { targetMatch = tm }
    }
}

/// One place that says "the calendar may have changed" (G11): EventKit's store-changed notice, wake from sleep, a new day and a 60 s
/// tick. It also keeps the calendar authorization, so a revoked permission is told apart from an empty calendar.
@MainActor
public final class CalendarWatcher: ObservableObject {
    public enum Trigger: String, Sendable {
        case launch, storeChanged, wake, dayChanged, tick, settings
    }

    @Published public private(set) var authorization: CalendarAuthorization
    /// Every trigger, after `authorization` was read again. The session selector listens; Up next can too.
    public let changes = PassthroughSubject<Trigger, Never>()

    private let readAuthorization: () -> CalendarAuthorization
    private let center: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let tickSeconds: Double
    private var observers: [NSObjectProtocol] = []
    private var tickTask: Task<Void, Never>?

    public init(authorization: @escaping () -> CalendarAuthorization, center: NotificationCenter = .default,
                workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter, tickSeconds: Double = 60) {
        readAuthorization = authorization
        self.authorization = authorization()
        self.center = center
        self.workspaceCenter = workspaceCenter
        self.tickSeconds = tickSeconds
    }

    public var isWatching: Bool { tickTask != nil }

    public func start() {
        guard tickTask == nil else { return }
        let pairs: [(NotificationCenter, Notification.Name, Trigger)] = [
            (center, CalendarSource.storeChangedNotification, .storeChanged),
            (workspaceCenter, NSWorkspace.didWakeNotification, .wake),
            (center, .NSCalendarDayChanged, .dayChanged),
        ]
        for (c, name, trigger) in pairs {
            observers.append(c.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fire(trigger) }
            })
        }
        let period = max(1, tickSeconds)
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(period))
                guard !Task.isCancelled, let self else { return }
                self.fire(.tick)
            }
        }
    }

    public func stop() {
        for o in observers {
            center.removeObserver(o)
            workspaceCenter.removeObserver(o)
        }
        observers = []
        tickTask?.cancel()
        tickTask = nil
    }

    public func fire(_ trigger: Trigger) {
        let a = readAuthorization()
        if a != authorization { authorization = a }
        changes.send(trigger)
    }
}
