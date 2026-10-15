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
    func showOverlayPanel()
    func hideOverlayPanel()
    func log(_ line: String)
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
/// using the microphone (and, with the calendar on, a few minutes before a meeting with a video link), starts the
/// session only on the click, and after a meeting offers "Save summary to vault?" (off by default; writes only on the
/// click).
@MainActor
public final class MeetingCoordinator: ObservableObject {
    public let settings: MeetingSettings
    @Published public private(set) var calendarStatus: String

    private weak var host: (any MeetingHost)?
    private let detector: MeetingDetector
    private let calendar: CalendarSource
    private let gate: CalendarGate
    private let prepare: @Sendable (MeetingEvent, String) async throws -> URL
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
    private var offered: Set<String> = []
    private var activeEventTitle: String?
    private var watchTask: Task<Void, Never>?
    private var upcomingTask: Task<Void, Never>?
    private var prepTask: Task<Void, Never>?
    private var prepToken = 0
    private var clearTask: Task<Void, Never>?
    private var settingsSub: AnyCancellable?

    public init(host: any MeetingHost, settings: MeetingSettings = MeetingSettings(),
                calendar: CalendarSource = CalendarSource(), detector: MeetingDetector? = nil,
                prepare: (@Sendable (MeetingEvent, String) async throws -> URL)? = nil,
                upcoming: (@Sendable (Date) async -> [MeetingEvent])? = nil,
                eventMap: EventSessionMap = EventSessionMap(), now: @escaping () -> Date = { Date() }) {
        let gate = CalendarGate()
        gate.isOn = settings.useCalendar
        self.host = host
        self.settings = settings
        self.calendar = calendar
        self.gate = gate
        self.detector = detector ?? MeetingDetector(eventLookup: { when in gate.isOn ? calendar.overlapping(now: when) : [] })
        let brainDir = VerseController.brainDir()
        self.prepare = prepare ?? { event, lang in
            guard let brain = brainDir else { throw CalendarPrepError.brainDirNotFound("(not found)") }
            return try await CalendarPrep(brainDir: brain).makeSession(for: event, lang: lang)
        }
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
        prepTask?.cancel(); prepTask = nil
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
            if let o = startOffer, host?.overlay.state.meetingPrompt == o.prompt { withdraw() }
        }
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
            let key = info.event?.id ?? "\(info.appName)@\(Int(info.since.timeIntervalSince1970))"
            guard !dismissed.contains(key) else { return }
            guard !busy else {
                host.log("meeting detected in \(info.appName) while a session runs: no prompt")
                return
            }
            let plan = MeetingSessionResolver.plan(for: info.event, sessions: host.sessions, remembered: eventMap.load(),
                                                   selected: host.settings.sessionName)
            offer(StartOffer(event: info.event, appName: info.appName, plan: plan, key: key,
                             prompt: .detected(appName: info.appName, eventTitle: info.event?.title, plan: plan)))
            host.log("meeting detected in \(info.appName) event=\(info.event?.title ?? "none") plan=\(plan)")
        case .ended(let info):
            // The call ended before anyone clicked: take the question back.
            if let o = startOffer, o.appName == info.appName, !o.prompt.busy, host.overlay.state.meetingPrompt == o.prompt { withdraw() }
        }
    }

    /// One look at the calendar: an event with a video link that starts within five minutes (or began less than ten
    /// minutes ago) is offered once, so Verse can be ready before the call is joined.
    public func pollUpcoming() async {
        guard let host, settings.detectMeetings, settings.useCalendar, !busy, host.overlay.state.meetingPrompt == nil else { return }
        let t = now()
        let events = await upcomingLookup(t)
        guard !busy, host.overlay.state.meetingPrompt == nil else { return }
        let hit = events.sorted { $0.start < $1.start }.first { e in
            e.provider != .other && !dismissed.contains(e.id) && !offered.contains(e.id)
                && e.start.timeIntervalSince(t) <= Self.upcomingWindow && t.timeIntervalSince(e.start) <= Self.upcomingGrace && e.end > t
        }
        guard let e = hit else { return }
        offered.insert(e.id)
        let plan = MeetingSessionResolver.plan(for: e, sessions: host.sessions, remembered: eventMap.load(), selected: host.settings.sessionName)
        let minutes = max(0, Int((e.start.timeIntervalSince(t) / 60).rounded(.up)))
        offer(StartOffer(event: e, appName: nil, plan: plan, key: e.id, prompt: .upcoming(eventTitle: e.title, minutes: minutes, plan: plan)))
        host.log("upcoming meeting offered: \(e.title) in \(minutes) min plan=\(plan)")
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
        prepToken += 1
        prepTask?.cancel(); prepTask = nil
        startOffer = nil
        closePrompt()
    }

    private func closePrompt() {
        clearTask?.cancel()
        saveOffer = nil
        host?.overlay.showPrompt(nil)
        host?.hideOverlayPanel()
    }

    /// The Start button: the session is prepared from the invite first when none exists for the event, then the same
    /// path as the menu's Start runs, which shows the Ready panel.
    private func accept(_ o: StartOffer) {
        guard let host else { return }
        dismissed.insert(o.key)
        switch o.plan {
        case .prepared(let name):
            begin(session: name, offer: o)
        case .selected:
            begin(session: nil, offer: o)
        case .fromInvite:
            guard let event = o.event else { begin(session: nil, offer: o); return }
            host.overlay.showPrompt(o.prompt.preparing())
            prepToken += 1
            let token = prepToken
            let lang = host.settings.language
            let prepare = self.prepare
            prepTask = Task { [weak self] in
                let result: Result<URL, any Error>
                do { result = .success(try await prepare(event, lang)) } catch { result = .failure(error) }
                guard let self, token == self.prepToken, !Task.isCancelled else { return }
                self.prepTask = nil
                switch result {
                case .success(let dir):
                    let name = dir.lastPathComponent
                    self.eventMap.remember(eventID: event.id, session: name)
                    self.begin(session: name, offer: o)
                case .failure(let error):
                    // Do not leave him with nothing: the session chosen in the menu is the fallback.
                    host.log("prepare from the invite failed: \(error)")
                    if host.sessions.isEmpty {
                        self.startOffer = nil
                        host.overlay.showPrompt(nil)
                        host.overlay.showError("Could not prepare a session from the invite (\(error)). Prepare one for this meeting, then press Start.")
                        host.showOverlayPanel()
                    } else {
                        self.begin(session: nil, offer: o)
                    }
                }
            }
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
        case .fullAccess: return "Calendar access allowed"
        case .notDetermined: return "Calendar access not asked yet"
        case .denied: return "Calendar access denied (System Settings > Privacy & Security > Calendars)"
        case .restricted: return "Calendar access is restricted on this Mac"
        case .writeOnly: return "Write-only calendar access (Verse needs full access to read events)"
        }
    }
}

extension VerseController: MeetingHost {}
