import Combine
import Foundation
import os
import VerseMeet

/// What the coordinator needs from the app's session controller (`VerseController` conforms; tests use a fake).
@MainActor
public protocol MeetingHost: AnyObject {
    var settings: AppSettings { get }
    var overlay: OverlayModel { get }
    var running: Bool { get }
    var stopping: Bool { get }
    var sessions: [String] { get }
    func refreshSessions()
    func start()
    /// An unprepared call, started at once (the prompt's Start when no prepared session matches; owner decision 3).
    func startUnprepared()
    func showOverlayPanel()
    func hideOverlayPanel()
    func log(_ line: String)
    /// Session name -> its `event.json`, for the match (`VerseController` reads the folders; the default has none).
    func sessionSidecars() -> [String: EventSidecar]
    /// The session he picked by hand that still holds, if any: a prompt for a meeting without a session uses it instead of an
    /// unprepared call (the default has none).
    func manualSessionForStart() -> String?
    /// A meeting app took the microphone while a session runs (no prompt is shown then). The controller moves a call that the
    /// automatic pick started on the room route to the meeting route (`QuickStart.MeetingRouteUpgrade`); the default does nothing.
    func meetingDetectedDuringRun(appName: String)
}

public extension MeetingHost {
    func sessionSidecars() -> [String: EventSidecar] { [:] }
    func manualSessionForStart() -> String? { nil }
    func meetingDetectedDuringRun(appName: String) {}
}

/// A flag the detector's lookup closure (Sendable, off the main actor) can read.
final class CalendarGate: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    var isOn: Bool {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

/// A finished meeting run, as far as the summary prompt cares.
public struct FinishedRun: Sendable {
    public var code: Int32
    public var sessionName: String
    public var sessionDir: URL
    public var startedAt: Date
    /// Canned brain or a test audio file: the summary is not a real meeting's and is never offered for the vault.
    public var isTest: Bool

    public init(code: Int32, sessionName: String, sessionDir: URL, startedAt: Date, isTest: Bool) {
        self.code = code
        self.sessionName = sessionName
        self.sessionDir = sessionDir
        self.startedAt = startedAt
        self.isTest = isTest
    }
}

/// Wires the VerseMeet library into the app: offers "Meeting detected · Start Verse?" when a known meeting app starts
/// using the microphone (and, with the calendar on, a few minutes before a real meeting: someone else on the invite or a call
/// link), starts the session only on the click, and after a meeting offers "Save summary to vault?" (off by default; writes
/// only on the click). Start never waits for a prep: a meeting without a prepared session starts as an unprepared call.
@MainActor
public final class MeetingCoordinator: ObservableObject {
    public let settings: MeetingSettings
    @Published public private(set) var calendarStatus: String

    /// Called with the event and the new session's folder name once a session was prepared from an invite (the controller's
    /// background prep tells it when the home window has not set its own hook). The People model records the attendees from it
    /// (memory spec 2.5).
    public var onPreparedFromEvent: (@MainActor (MeetingEvent, String) -> Void)?

    private weak var host: (any MeetingHost)?
    private let detector: MeetingDetector
    private let calendar: CalendarSource
    private let gate: CalendarGate
    private let upcomingLookup: @Sendable (Date) async -> [MeetingEvent]
    private let eventMap: EventSessionMap
    private let now: () -> Date

    private struct StartOffer {
        var event: MeetingEvent?
        var appName: String?
        var plan: MeetingPrompt.SessionPlan
        var key: String
        var prompt: MeetingPrompt
    }
    private struct SaveOffer {
        var summary: URL
        var title: String
        var date: Date
    }

    private var startOffer: StartOffer?
    private var saveOffer: SaveOffer?
    private var dismissed: Set<String> = []
    /// App name → last time an event-less call there was answered or ended after being answered (S11).
    private var answeredApps: [String: Date] = [:]
    private var offered: Set<String> = []
    private var activeEventTitle: String?
    private var watchTask: Task<Void, Never>?
    private var upcomingTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    private var settingsSub: AnyCancellable?

    public init(host: any MeetingHost, settings: MeetingSettings = MeetingSettings(),
                calendar: CalendarSource = CalendarSource(), detector: MeetingDetector? = nil,
                upcoming: (@Sendable (Date) async -> [MeetingEvent])? = nil,
                eventMap: EventSessionMap = EventSessionMap(), now: @escaping () -> Date = { Date() }) {
        let gate = CalendarGate()
        gate.isOn = settings.useCalendar
        self.host = host
        self.settings = settings
        self.calendar = calendar
        self.gate = gate
        // A real meeting beats a focus block that overlaps the call (G13); with none, any event still names the call.
        self.detector = detector ?? MeetingDetector(eventLookup: { when in
            gate.isOn ? RealMeeting.preferReal(calendar.overlapping(now: when)) : []
        })
        self.upcomingLookup = upcoming ?? { when in
            guard gate.isOn, calendar.authorization() == .fullAccess else { return [] }
            return (try? await calendar.upcoming(within: Self.upcomingWindow, now: when)) ?? []
        }
        self.eventMap = eventMap
        self.now = now
        calendarStatus = Self.describe(calendar.authorization())
        host.overlay.promptActions = { [weak self] action in
            MainActor.assumeIsolated { self?.promptAction(action) }
        }
    }

    // MARK: lifecycle

    /// Meeting offered this long before it starts, at most; and no longer than this after it started.
    static let upcomingWindow: TimeInterval = 5 * 60
    static let upcomingGrace: TimeInterval = 10 * 60
    static let upcomingPollSeconds: Double = 30

    /// Starts watching (the app calls this once at launch). Follows the settings from then on.
    public func begin() {
        reconcile()
        let sub = settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.reconcile() } }
        }
        settingsSub = sub
    }

    /// Stops the watchers (Quit).
    public func end() {
        watchTask?.cancel(); watchTask = nil
        upcomingTask?.cancel(); upcomingTask = nil
        clearTask?.cancel(); clearTask = nil
        let d = detector
        Task { await d.stop() }
    }

    private func reconcile() {
        gate.isOn = settings.useCalendar
        if settings.detectMeetings {
            if watchTask == nil {
                let d = detector
                watchTask = Task { [weak self] in
                    for await signal in await d.signals() {
                        guard let self else { return }
                        self.handle(signal)
                    }
                }
            }
            if settings.useCalendar {
                recheckCalendarAccess()
                if upcomingTask == nil {
                    upcomingTask = Task { [weak self] in
                        while !Task.isCancelled {
                            guard let self else { return }
                            await self.pollUpcoming()
                            try? await Task.sleep(for: .seconds(Self.upcomingPollSeconds))
                        }
                    }
                }
            } else {
                upcomingTask?.cancel(); upcomingTask = nil
            }
        } else {
            watchTask?.cancel(); watchTask = nil
            upcomingTask?.cancel(); upcomingTask = nil
            let d = detector
            Task { await d.stop() }
            if let o = startOffer, isShowing(o) { withdraw() }
        }
    }

    /// The offer's prompt is the one under the notch. Compared by kind, so a prompt whose copy changed still counts (V4).
    private func isShowing(_ o: StartOffer) -> Bool {
        host?.overlay.state.meetingPrompt?.kind == o.prompt.kind
    }

    // MARK: Meeting detected / upcoming

    private var busy: Bool {
        guard let host else { return true }
        return host.running || host.stopping || host.overlay.state.running
    }

    /// One signal from the detector.
    public func handle(_ signal: MeetingSignal) {
        guard let host else { return }
        switch signal {
        case .started(let info):
            guard settings.detectMeetings else { return }
            // One occurrence of a recurring meeting is not the next one: answers are kept per occurrence (G10).
            let key = info.event?.occurrenceKey ?? "\(info.appName)@\(Int(info.since.timeIntervalSince1970))"
            guard !dismissed.contains(key) else { return }
            if info.event == nil, let last = answeredApps[info.appName], now().timeIntervalSince(last) <= Self.resumeWindow {
                // The same call after a pause in its microphone input (muted for more than the detector's 10 s): its
                // start time is new, but the question was already answered (S11).
                answeredApps[info.appName] = now()
                dismissed.insert(key)
                host.log("meeting in \(info.appName) resumed after a pause: no prompt (already answered)")
                return
            }
            guard !busy else {
                host.log("meeting detected in \(info.appName) while a session runs: no prompt")
                // A call that started on the room route before the meeting app took the microphone may move to the meeting route.
                if host.running, !host.stopping { host.meetingDetectedDuringRun(appName: info.appName) }
                return
            }
            let plan = startPlan(for: info.event, host: host)
            offer(StartOffer(event: info.event, appName: info.appName, plan: plan, key: key,
                             prompt: .detected(appName: info.appName, eventTitle: info.event?.title, plan: plan)))
            host.log("meeting detected in \(info.appName) event=\(info.event?.title ?? "none") plan=\(plan)")
        case .ended(let info):
            if answeredApps[info.appName] != nil { answeredApps[info.appName] = now() }
            // The call ended before anyone clicked: take the question back.
            if let o = startOffer, o.appName == info.appName, isShowing(o) { withdraw() }
        }
    }

    /// A call without a calendar event whose mic input comes back within this long after it ended is the same call.
    static let resumeWindow: TimeInterval = 10 * 60

    /// Remembers that the start question for an event-less call in `o`'s app was answered (Start or Not now).
    private func markAnswered(_ o: StartOffer) {
        if o.event == nil, let app = o.appName { answeredApps[app] = now() }
    }

    /// One look at the calendar: a real meeting (someone else on the invite, or a call link of any provider; G13) that starts
    /// within five minutes (or began less than ten minutes ago) is offered once, so Verse can be ready before the call is joined.
    public func pollUpcoming() async {
        guard let host, settings.detectMeetings, settings.useCalendar, !busy, host.overlay.state.meetingPrompt == nil else { return }
        let t = now()
        let events = await upcomingLookup(t)
        guard !busy, host.overlay.state.meetingPrompt == nil else { return }
        let hit = events.sorted { $0.start < $1.start }.first { e in
            RealMeeting.isReal(e) && !dismissed.contains(e.occurrenceKey) && !offered.contains(e.occurrenceKey)
                && e.start.timeIntervalSince(t) <= Self.upcomingWindow && t.timeIntervalSince(e.start) <= Self.upcomingGrace && e.end > t
        }
        guard let e = hit else { return }
        offered.insert(e.occurrenceKey)
        let plan = startPlan(for: e, host: host)
        let minutes = max(0, Int((e.start.timeIntervalSince(t) / 60).rounded(.up)))
        offer(StartOffer(event: e, appName: nil, plan: plan, key: e.occurrenceKey, prompt: .upcoming(eventTitle: e.title, minutes: minutes, plan: plan)))
        host.log("upcoming meeting offered: \(e.title) in \(minutes) min plan=\(plan)")
    }

    /// What Start will use: the event's prepared session (`MeetingSessionResolver`); for a meeting without one, the session he
    /// picked by hand while that pick holds, else an unprepared call; without an event, the selected session.
    private func startPlan(for event: MeetingEvent?, host: any MeetingHost) -> MeetingPrompt.SessionPlan {
        let plan = MeetingSessionResolver.plan(for: event, sessions: host.sessions, remembered: eventMap.load(),
                                               selected: host.settings.sessionName, sidecars: host.sessionSidecars())
        if plan == .unprepared, let manual = host.manualSessionForStart(), host.sessions.contains(manual) { return .selected(manual) }
        return plan
    }

    private func offer(_ o: StartOffer) {
        guard let host else { return }
        clearTask?.cancel()
        saveOffer = nil
        startOffer = o
        host.overlay.showPrompt(o.prompt)
        host.showOverlayPanel()
    }

    private func withdraw() {
        startOffer = nil
        host?.overlay.showPrompt(nil)
        host?.hideOverlayPanel()
    }

    // MARK: buttons

    public func promptAction(_ action: PromptAction) {
        guard let host, let shown = host.overlay.state.meetingPrompt else { return }
        switch shown.kind {
        case .detected, .upcoming:
            guard let o = startOffer, o.prompt.kind == shown.kind else { return }
            // A busy prompt answers only "Not now" (V4).
            if shown.busy && action == .accept { return }
            action == .accept ? accept(o) : dismissStart(o)
        case .saveSummary:
            guard let s = saveOffer else { return }
            action == .accept ? save(s) : closePrompt()
        case .saved:
            closePrompt()
        }
    }

    private func dismissStart(_ o: StartOffer) {
        dismissed.insert(o.key)
        markAnswered(o)
        startOffer = nil
        closePrompt()
    }

    private func closePrompt() {
        clearTask?.cancel()
        saveOffer = nil
        host?.overlay.showPrompt(nil)
        host?.hideOverlayPanel()
    }

    /// The Start button: the event's prepared session (or the selected one) through the menu's Start, which shows the Ready
    /// panel; a meeting without a prepared session starts as an unprepared call at once (owner decision 3: never a wait).
    private func accept(_ o: StartOffer) {
        guard let host else { return }
        dismissed.insert(o.key)
        markAnswered(o)
        switch o.plan {
        case .prepared(let name):
            begin(session: name, offer: o)
        case .selected(let name):
            begin(session: name, offer: o)
        case .unprepared:
            startOffer = nil
            activeEventTitle = o.event?.title
            host.overlay.showPrompt(nil)
            host.log("start from the prompt: no prepared session for \(o.event?.title ?? "the call"), unprepared call")
            host.startUnprepared()
        }
    }

    private func begin(session: String?, offer o: StartOffer) {
        guard let host else { return }
        startOffer = nil
        activeEventTitle = o.event?.title
        host.overlay.showPrompt(nil)
        host.refreshSessions()
        if let session, host.sessions.contains(session) { host.settings.sessionName = session }
        host.start()
    }

    // MARK: summary to the vault

    /// A meeting run ended. With the setting on, a real run (not a canned brain or a test file) that left a fresh
    /// `summary.md` gets the question; nothing is written here.
    public func runFinished(_ run: FinishedRun) {
        let title = activeEventTitle ?? run.sessionName
        activeEventTitle = nil
        guard let host, settings.offerSummaryToVault, run.code == 0, !run.isTest else { return }
        let summary = run.sessionDir.appendingPathComponent("summary.md")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: summary.path),
              let modified = attrs[.modificationDate] as? Date, modified >= run.startedAt.addingTimeInterval(-1),
              (attrs[.size] as? Int ?? 0) > 0 else {
            host.log("no fresh summary.md in \(run.sessionName): no vault prompt")
            return
        }
        let writer = VaultSummaryWriter(vaultRoot: settings.vaultURL)
        let folder = writer.destinationFolder()
        saveOffer = SaveOffer(summary: summary, title: title, date: run.startedAt)
        startOffer = nil
        host.overlay.showPrompt(.saveSummary(session: title, folder: Self.relative(folder, to: settings.vaultURL)))
        host.showOverlayPanel()
    }

    private func save(_ s: SaveOffer) {
        guard let host else { return }
        saveOffer = nil
        do {
            let url = try VaultSummaryWriter(vaultRoot: settings.vaultURL).write(summaryAt: s.summary, title: s.title, date: s.date)
            host.log("summary saved to the vault: \(url.lastPathComponent)")
            host.overlay.showPrompt(.saved(path: Self.relative(url, to: settings.vaultURL)))
            autoClose()
        } catch {
            host.log("summary not saved: \(error)")
            host.overlay.showPrompt(.saveFailed("\(error)"))
        }
        host.showOverlayPanel()
    }

    private func autoClose() {
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, self.host?.overlay.state.meetingPrompt?.kind == .saved else { return }
            self.closePrompt()
        }
    }

    private static func relative(_ url: URL, to root: URL) -> String {
        let p = url.standardizedFileURL.path, r = root.standardizedFileURL.path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : p
    }

    // MARK: calendar permission (Settings)

    /// The calendar setting is on but macOS no longer applies the permission (a new signature, a reset): ask again instead of
    /// matching every call to no event in silence (2 Nov: the prepared session was never picked). Logged either way.
    private var accessRechecked = false
    private func recheckCalendarAccess() {
        guard !accessRechecked else { return }
        accessRechecked = true
        let status = calendar.authorization()
        host?.log("calendar access: \(status)")
        guard status == .notDetermined else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.calendar.ensureAccess()
            self.host?.log("calendar access after asking: \(self.calendar.authorization())")
        }
    }

    /// Asks for Calendar access (the system prompt appears once) and reports the result. Turns the calendar setting on
    /// only when access was granted.
    public func requestCalendarAccess() async {
        do {
            try await calendar.ensureAccess()
            calendarStatus = Self.describe(calendar.authorization())
            settings.useCalendar = true
        } catch {
            calendarStatus = "\(error)"
            settings.useCalendar = false
        }
        gate.isOn = settings.useCalendar
    }

    private static func describe(_ a: CalendarAuthorization) -> String {
        switch a {
        case .fullAccess: return L10n.tr("Calendar access allowed")
        case .notDetermined: return L10n.tr("Calendar access not asked yet")
        case .denied: return L10n.tr("Calendar access denied (System Settings > Privacy & Security > Calendars)")
        case .restricted: return L10n.tr("Calendar access is restricted on this Mac")
        case .writeOnly: return L10n.tr("Write-only calendar access (Verse needs full access to read events)")
        }
    }
}

extension VerseController: MeetingHost {}
