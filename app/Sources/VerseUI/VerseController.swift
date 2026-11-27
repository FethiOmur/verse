import AppKit
import Combine
import Foundation
import VerseMeet
import VerseTurns

/// Testing switches from the command line (`open Verse.app --args --fake-brain --file q.wav`). They override Settings.
public struct LaunchOptions: Sendable {
    public var fakeBrain = false
    public var file: String?
    public var session: String?
    public var autostart = false
    public var renderScreensDir: String?
    /// `--preview-overlay capsule-idle,card-question`: shows those sample states (ScreenRenderer names) in the real
    /// notch panel, `VERSE_PREVIEW_SECONDS` (default 2) each, then quits. For checking placement on the real screen.
    public var previewOverlay: [String]?
    /// Test only: `--cycles N` runs N Start → Ready → Stop cycles (Start right after Stop), logs each result to
    /// verse.log and quits.
    public var cycles: Int?
    /// `--no-hotkeys`: the app does not register ⌥⌘V (a second copy running for a test).
    public var noHotKeys = false

    public init(arguments: [String] = CommandLine.arguments) {
        var it = arguments.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--fake-brain": fakeBrain = true
            case "--file": file = it.next()
            case "--session": session = it.next()
            case "--autostart": autostart = true
            case "--no-hotkeys": noHotKeys = true
            case "--render-screens": renderScreensDir = it.next()
            case "--cycles": cycles = it.next().flatMap { Int($0) }
            case "--preview-overlay": previewOverlay = it.next()?.split(separator: ",").map(String.init)
            default: break
            }
        }
    }
}

/// Runs one meeting session: the `VerseRunner` wiring (the same one `verse-run` uses) with its sink feeding the
/// overlay. Start/Stop/Quit always shut the brain down.
@MainActor
public final class VerseController: ObservableObject {
    @Published public private(set) var running = false
    @Published public private(set) var stopping = false { didSet { overlay.setStopping(stopping) } }
    @Published public private(set) var sessions: [String] = []
    @Published public private(set) var sessionSpend = 0.0
    @Published public private(set) var monthSpend = 0.0
    @Published public private(set) var lastExitCode: Int32?
    /// The note of the last run that ended normally but with answers off for part of it (the brain was given up on mid-call);
    /// nil otherwise.
    @Published public private(set) var lastRunNote: String?
    /// Anytime calls: how the running (or last) session was started. UI hooks; the island and menu read them.
    @Published public private(set) var route: AudioRoute = .meeting
    @Published public private(set) var sessionMode: SessionMode = .prepared
    /// The language the running session listens in.
    /// The language the recognizers run in now ("en", "it" or "tr"; with `autoLanguage`, the one AUTO picked).
    @Published public private(set) var callLanguage = "en"
    /// The interim AUTO language mode is on for the running call (spec 2.5): the call follows the spoken language.
    @Published public private(set) var autoLanguage = false
    /// ⌥⌘V was pressed once while a session runs: the island shows "Press ⌥⌘V again to stop" for `StopConfirm.window`.
    @Published public private(set) var stopArmed = false
    /// False when ⌥⌘V is taken by another app.
    @Published public private(set) var startHotKeyAvailable = false
    /// False when ⌥⇧⌘V (Start unprepared) is taken by another app.
    @Published public private(set) var startUnpreparedHotKeyAvailable = false
    /// The earlier/newer answer keys (⌥⌘←, ⌥⌘→, ⇧<) another app holds in the running session; empty otherwise.
    @Published public private(set) var unavailableAnswerKeys: [String] = []
    /// The me layer, as the brain reported it for the running session: nil = no layer.
    @Published public private(set) var meLayer: MeLayerInfo?
    /// Where the me layer and the meeting pack disagree on a number (the brain's `notice`, once after start).
    @Published public private(set) var meConflicts: [MeConflict] = []
    /// `start.me` named files that do not exist: the session ran without the layer.
    @Published public private(set) var meLayerMissing = false
    /// The rehearsal running now ("Rehearse a line…"), nil during a real call and when idle. While it is set, `running` is true
    /// too: the rehearsal is a session of its own, on a temporary copy of the prepared folder, with no audio.
    @Published public private(set) var rehearsal: RehearsalRun?

    public let settings: AppSettings
    public let overlay: OverlayModel
    /// T-UI: the teleprompter (view model, settings, script editor).
    public let prompter = PrompterModel()
    public let launch: LaunchOptions
    private var panel: NotchPanelController?
    /// The meeting island's frame while it is on screen (the dictation island keeps clear of it).
    var meetingIslandFrame: NSRect? { panel?.visibleFrame }
    /// Called when the meeting island appears, moves, resizes or goes (set by `bindDictation`).
    var onMeetingIslandChange: (() -> Void)?
    private var runner: VerseRunner?
    private var runTask: Task<Void, Never>?
    private var runStartedAt = Date()
    /// When the runner gave the brain up in this run (`answers_off`), and the status message it showed for it.
    private var answersOff: (at: Date, message: String)?
    private var runSessionDir: URL?
    private var runWasFake = false
    private var cancellables: Set<AnyCancellable> = []
    /// Settings > Testing's "Play as remote…": the file is the remote channel and the microphone stays "me". Cleared when the run
    /// ends.
    private var remoteFileOverride: URL?
    /// Meeting detection ("Meeting detected · Start Verse?") and the summary-to-vault question.
    public lazy var meeting = MeetingCoordinator(host: self)
    /// Dictation (⌃⌥⌘D). Created on first use; registers nothing until `installDictation` at launch (VerseController+Dictation).
    public lazy var dictation = DictationController()

    // Anytime calls
    private var hotKeys: GlobalHotKeys?
    private var stopConfirm = StopConfirm()
    private var stopArmTask: Task<Void, Never>?
    /// The route picked by hand in the menu for the next Start; nil = the automatic pick. Used once.
    @Published public private(set) var routeChoice: AudioRoute?
    /// A route or language change of the running call is under way (one at a time).
    private(set) var switching = false
    /// Whether the running call may still move from an automatically picked room route to the meeting route when a meeting app
    /// takes the microphone (set by `launchSession`).
    private(set) var routeUpgrade = QuickStart.MeetingRouteUpgrade(autoPicked: false, rehearsal: false)
    /// The clock the double-press stop uses; tests replace it.
    public var clock: () -> Date = { Date() }
    /// The calendar the pickers' "Today 14:00" labels are made in; tests pin the time zone.
    public var calendar: Calendar = .current
    /// Calendar events around a time, for choosing the session a Start uses (and the menu's preview of it). Default: the calendar,
    /// while "Use my calendar" is on and its access was granted; empty otherwise. Tests replace it.
    public lazy var eventsAround: (Date) -> [MeetingEvent] = { [weak self] when in
        guard let self, self.meeting.settings.useCalendar else { return [] }
        // A real meeting beats a focus block that overlaps it (G13); with none, any event still counts.
        return RealMeeting.preferReal(self.calendarSource.overlapping(now: when, margin: QuickStart.eventMargin))
    }
    /// The facts the route is picked from. Default: Core Audio's per-process flags, never audio.
    public var routeFacts: () -> QuickStart.RouteFacts = {
        QuickStart.RouteFacts(phoneCallActive: false,
                              meetingAppHoldsMic: QuickStart.meetingAppHoldsMic(CoreAudioProcessTable().snapshot()))
    }
    /// Event id -> prepared session, as the calendar prep remembered it.
    public var eventSessions = EventSessionMap()
    /// Something else (the practice interview) owns the microphone: no Start of any kind runs (`bindPractice` sets it).
    public var startBlocked: () -> Bool = { false }
    /// What ⌥⌘V twice does while `startBlocked` holds: end the practice interview (`bindPractice` sets it). Nil: the key does nothing then.
    public var blockedStop: (() -> Void)?
    /// How the last run (or the last start attempt) was started, for the error panel's Retry (review U4).
    private(set) var retryPlan: RetryPlan?
    /// Tests only: replaces the runner, so a start can be seen without a brain or a microphone.
    var launchOverride: ((LaunchRequest) -> Void)?
    /// Where the unprepared session folders go. Tests point it at a temp folder.
    public var sessionsRoot: URL = SessionCatalog.root

    // Calendar-aware session selection
    /// One calendar source for the selector and the watcher (one EventKit store, so its change notices arrive).
    public lazy var calendarSource = CalendarSource()
    /// Calendar events from an hour before `now` to the auto-select's lookahead, real meetings only. Empty while "Use my calendar"
    /// is off or full access is missing (never prompts). Tests replace it.
    public lazy var selectionEvents: (Date) -> [MeetingEvent] = { [weak self] now in
        guard let self, self.meeting.settings.useCalendar else { return [] }
        return self.calendarSource.events(overlapping: now.addingTimeInterval(-3600), now.addingTimeInterval(SessionAutoSelect.lookahead),
                                          realMeetingsOnly: true)
    }
    /// Picks the Start session from the calendar (G1). Its published state is what the pickers and the status line show.
    public lazy var selector: SessionSelector = {
        let s = SessionSelector(
            settings: settings,
            busy: { [weak self] in self?.selectionBusy ?? true },
            sessions: { [weak self] in self?.sessions ?? [] },
            readEvents: { [weak self] now in self?.selectionEvents(now) ?? [] },
            loadMatcher: { [weak self] names in
                guard let self else { return SessionMatcher(sessions: names) }
                return SessionMatcher.load(sessions: names, root: self.sessionsRoot, eventMap: self.eventSessions)
            },
            createdAt: { [weak self] names in
                guard let self else { return [:] }
                return SessionAutoSelect.createdAt(sessions: names, root: self.sessionsRoot)
            },
            clock: { [weak self] in self?.clock() ?? Date() },
            log: { [weak self] in self?.log($0) })
        s.autoSelectEnabled = launch.session == nil
        return s
    }()
    /// Calendar changes, wake, a new day and a 60 s tick (G11); `beginSessionSelection` starts it.
    public lazy var calendarWatcher = CalendarWatcher(authorization: { [weak self] in self?.calendarSource.authorization() ?? .notDetermined })
    private var selectionSubs: Set<AnyCancellable> = []
    /// The prep from an invite (the brain's calendar prep). Read once, when `autoPrep` is made; tests set it before that.
    public lazy var eventPrepare: @Sendable (MeetingEvent, String) async throws -> URL = EventPrep.prepare(brainDir: Self.brainDir())
    /// The background prep of upcoming meetings without a session (owner decision 3); the pickers show its "Preparing…".
    public lazy var autoPrep = MeetingAutoPrep(
        settings: meeting.settings, prepare: eventPrepare,
        language: { [weak self] in self?.settings.language ?? "en" },
        onPrepared: { [weak self] event, dir in self?.eventPrepared(event, dir: dir) },
        log: { [weak self] in self?.log($0) })
    /// After a prep from an event that the controller ran (the background prep, Prepare in the picker): who was in the meeting
    /// and the automatic brief. The home window sets it; without it the meeting coordinator's attendee hook is told.
    public var onEventPrepared: (@MainActor (MeetingEvent, String) -> Void)?
    /// Every run that ended, after the meeting coordinator heard of it (the persona queues its session here).
    var onRunFinished: (@MainActor (FinishedRun) -> Void)?
    /// Created times and `event.json` files of the sessions, read once per session list (the pickers render often).
    private var sessionInfoCache: (names: [String], createdAt: [String: Date], sidecars: [String: EventSidecar])?

    /// Something is under way that the selection must not change under: a run, a stop, a route or language switch, the practice
    /// interview or a meeting prompt.
    var selectionBusy: Bool {
        running || stopping || switching || startBlocked() || overlay.state.running || overlay.state.meetingPrompt != nil
    }

    /// The app calls this once at launch, after the session list is read and before meeting detection starts: picks the session
    /// for the next meeting now and again on every calendar change, wake, new day, 60 s tick, session list change and run end.
    public func beginSessionSelection() {
        guard !calendarWatcher.isWatching else { return }
        calendarWatcher.changes.sink { [weak self] _ in
            self?.selector.reevaluate()
            self?.considerAutoPrep()
        }.store(in: &selectionSubs)
        $sessions.removeDuplicates().dropFirst().sink { [weak self] _ in
            // After the change has landed, and never inside a Start (the run is then under way and the selector does nothing).
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.selector.reevaluate() } }
        }.store(in: &selectionSubs)
        meeting.settings.$useCalendar.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.calendarWatcher.fire(.settings) } }
        }.store(in: &selectionSubs)
        calendarWatcher.start()
        calendarWatcher.fire(.launch)
    }

    /// The folders' `event.json` files, for the meeting prompt's match.
    public func sessionSidecars() -> [String: EventSidecar] {
        sessionInfo().sidecars
    }

    /// Created times and sidecars of the current sessions, read again only when the list changed.
    func sessionInfo() -> (createdAt: [String: Date], sidecars: [String: EventSidecar]) {
        if let c = sessionInfoCache, c.names == sessions { return (c.createdAt, c.sidecars) }
        let info = (names: sessions, createdAt: SessionAutoSelect.createdAt(sessions: sessions, root: sessionsRoot),
                    sidecars: EventSidecar.loadAll(sessions: sessions, root: sessionsRoot))
        sessionInfoCache = info
        return (info.createdAt, info.sidecars)
    }

    /// What the Session pickers show (G5): Next meetings, Other sessions, the marks and the "not prepared" line.
    public func pickerModel() -> SessionPickerModel {
        let info = sessionInfo()
        return SessionPickerModel.build(now: clock(), sessions: sessions, upcoming: selector.upcoming, matches: selector.matches,
                                        target: selector.target, selected: settings.sessionName, manual: selector.manual,
                                        sidecars: info.sidecars, createdAt: info.createdAt, preparing: autoPrep.inFlight,
                                        calendar: calendar)
    }

    /// The calendar row of the menu and Home (G2): Turn on, or permission missing.
    public var calendarNudge: CalendarNudge? {
        CalendarNudge.state(hasSessions: !sessions.isEmpty, useCalendar: meeting.settings.useCalendar,
                            authorization: calendarWatcher.authorization, running: running || stopping || startBlocked(),
                            done: meeting.settings.calendarNudgeDone)
    }

    /// The one-time Turn on (owner decision 4): asks for calendar access through the Settings path, never during a run.
    public func turnOnCalendar() {
        guard !running, !stopping, !startBlocked() else { return }
        meeting.settings.calendarNudgeDone = true
        Task { [weak self] in
            await self?.meeting.requestCalendarAccess()
            self?.calendarWatcher.fire(.settings)
        }
    }

    /// One look for the background prep (owner decision 3): only while nothing is under way and auto-select is on.
    func considerAutoPrep() {
        guard selector.autoSelectEnabled else { return }
        let now = clock()
        // A meeting he picked a session for by hand counts as prepared while the pick holds (design 4).
        var matched = Set(selector.matches.keys)
        if let key = selector.manualTargetKey(now: now) { matched.insert(key) }
        autoPrep.consider(now: now, busy: selectionBusy, upcoming: selector.upcoming, matched: matched)
    }

    /// "Use for this meeting": links `session` to the next meeting's occurrence and selects it (G3, G5).
    public func useForNextMeeting(_ session: String) {
        guard let t = selector.target, sessions.contains(session), !running, !stopping else { return }
        eventSessions.link(t, session: session)
        log("session \(session) linked by hand to \(t.occurrenceKey)")
        selector.choose(session)
        selector.reevaluate()
    }

    /// Prepare in the picker: the next meeting's session is prepared now, in the background (nothing waits for it).
    public func prepareNextMeeting() {
        guard let t = selector.target, !selectionBusy else { return }
        preparingByHand.insert(t.occurrenceKey)
        autoPrep.prepareNow(t, now: clock())
    }

    /// Occurrence keys of preps he started from the picker; their session may end a manual pick when done.
    private var preparingByHand: Set<String> = []

    /// A prep from an event finished: the occurrence is linked, the folder gets its `event.json` (G14), the people and the brief
    /// are told, and the session is selected when it is for the next meeting (G6).
    func eventPrepared(_ event: MeetingEvent, dir: URL) {
        let name = dir.lastPathComponent
        eventSessions.recordPrep(event, sessionDir: dir)
        sessionInfoCache = nil
        refreshSessions()
        if let hook = onEventPrepared { hook(event, name) } else { meeting.onPreparedFromEvent?(event, name) }
        let byHand = preparingByHand.remove(event.occurrenceKey) != nil
        selector.didPrepare(name, event: event, byHand: byHand)
    }

    public init(settings: AppSettings, launch: LaunchOptions = LaunchOptions()) {
        self.settings = settings
        self.launch = launch
        overlay = OverlayModel(config: settings.overlayConfig)
        overlay.stopActions = { [weak self] in
            MainActor.assumeIsolated { guard let c = self else { return }; Task { await c.stop() } }
        }
        overlay.startChipActions = { [weak self] action in
            MainActor.assumeIsolated { self?.startChip(action) }
        }
        overlay.regenerateActions = { [weak self] req in
            MainActor.assumeIsolated { self?.sendRegenerate(req) ?? false }
        }
        overlay.markActions = { [weak self] e in
            MainActor.assumeIsolated { self?.sendMark(e) }
        }
        prompter.language = { [weak self] in self?.settings.language ?? "en" }
        if let s = launch.session { settings.sessionName = s }
        refreshSessions()
        monthSpend = SpendLedger.thisMonth()
        settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.overlay.config = self?.settings.overlayConfig ?? OverlayConfig() } }
        }.store(in: &cancellables)
        // Inside the app (not a test process, not a test copy) ⌥⌘V is on from launch.
        if Bundle.main.bundleIdentifier == AppSettings.suiteName, !launch.noHotKeys { installGlobalHotKeys() }
    }

    public var fakeBrain: Bool { launch.fakeBrain || settings.fakeBrain }
    public var testFile: String? {
        if let r = remoteFileOverride { return r.path }
        if let f = launch.file, !f.isEmpty { return f }
        let p = settings.testAudioPath.trimmingCharacters(in: .whitespaces)
        return p.isEmpty ? nil : p
    }

    public func refreshSessions() {
        // Unprepared (adhoc) folders are not sessions to pick: Start would run them as prepared ones.
        // The standing general prep is a source for unprepared calls, not a session to pick or map to an event.
        sessions = SessionCatalog.list(root: sessionsRoot).filter { !SessionCatalog.isAdhoc($0) && !GeneralPrep.isGeneral($0) }
        // The selection is gone (or was never set): the next meeting's session, else the newest one (G7). Never reads the calendar.
        if !sessions.contains(settings.sessionName) { selector.selectionMissing() }
    }

    /// The brain folder: `VERSE_BRAIN_DIR`, then the repo path written into Info.plist at bundle time, then the
    /// upward search from the executable (a `swift run` from the repo).
    static func brainDir() -> URL? {
        if let env = ProcessInfo.processInfo.environment["VERSE_BRAIN_DIR"], !env.isEmpty { return URL(fileURLWithPath: env) }
        if let p = Bundle.main.object(forInfoDictionaryKey: "VerseBrainDir") as? String, !p.isEmpty { return URL(fileURLWithPath: p) }
        return try? BrainProcess.locateBrainDir()
    }

    /// The folder name of the session being recorded right now, nil when none is (Ask this meeting waits for the call to end).
    public var recordingSessionName: String? { running && rehearsal == nil ? runSessionDir?.lastPathComponent : nil }

    /// What the running call records into (G12): the run's own folder, "Unprepared call" for an adhoc one. Not running: the
    /// selected session.
    public var runLabel: String {
        guard running || stopping, let name = runSessionDir?.lastPathComponent else { return settings.sessionName }
        return SessionCatalog.isAdhoc(name) ? L10n.tr("Unprepared call") : name
    }

    /// The selected session as the pickers label it ("Today 14:00 · <meeting>", or the folder name).
    public var selectedLabel: String {
        pickerModel().label(of: settings.sessionName) ?? settings.sessionName
    }

    public var statusLine: String {
        if stopping { return L10n.tr("Stopping…") }
        if running {
            var s = L10n.tr("Listening · \(runLabel)")
            if rehearsal != nil { s += L10n.tr(" (rehearsal)") } else if testFile != nil { s += L10n.tr(" (test file)") }
            if fakeBrain { s += L10n.tr(" · fake brain") }
            return s
        }
        if sessions.isEmpty { return L10n.tr("No session prepared") }
        return L10n.tr("Ready · \(selectedLabel)")
    }

    // MARK: start / stop

    /// A live meeting runs until Stop. Without this the runner's `defaultLiveSeconds` (60 s, meant for CLI smoke
    /// runs) ended every live session one minute after listening started.
    public static let liveSessionSeconds = 12.0 * 3600

    /// The runner options for one Start. A test file plays to its end; live listens until Stop.
    public static func runOptions(sessionDir dir: URL, settings: AppSettings, fakeBrain: Bool, testFile: String?,
                                  micWithFile: Bool = false, follow: Bool = false, mode: SessionMode = .prepared,
                                  route: AudioRoute = .meeting, lang: String? = nil,
                                  meProfile: URL = MeProfilePaths.defaultDirectory) -> RunOptions {
        var o = RunOptions(sessionDir: dir)
        o.micWithFile = micWithFile
        o.follow = follow     // the room route follows by text too (brain: runtime/own.py); Swift emits no `me` partials there
        o.mode = mode
        o.route = route
        o.roomAuto = settings.roomAuto
        // The me layer goes into every session when it is on and has been built; without its file nothing is sent.
        if settings.useMeProfile, FileManager.default.fileExists(atPath: meProfile.appendingPathComponent("me.md").path) {
            o.me = MeProfilePaths(directory: meProfile)
        }
        o.lang = lang ?? settings.language
        o.turn = settings.turnConfig
        o.fakeBrain = fakeBrain
        o.brainDir = Self.brainDir()
        if let f = testFile {
            o.file = URL(fileURLWithPath: (f as NSString).expandingTildeInPath)
        } else {
            o.seconds = liveSessionSeconds
        }
        o.transcriptURL = dir.appendingPathComponent("transcript.jsonl")
        return o
    }

    /// The first known meeting app that is running ("Comet"), for the ready panel.
    static func meetingAppName(bundleIDs: [String] = defaultMeetingApps) -> String? {
        for id in bundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                return app.localizedName ?? id
            }
        }
        return nil
    }
    static let defaultMeetingApps = ["ai.perplexity.comet", "com.brave.Browser", "us.zoom.xos", "com.microsoft.teams2"]

    /// The last log line of the run, shown when a run fails without a status of its own.
    private var lastLogLine: String?

    public func log(_ line: String) {
        FileLog.shared.write(line)
    }

    public func start() {
        guard !running, !stopping else {
            log("start ignored: running=\(running) stopping=\(stopping)")
            return
        }
        guard !startBlocked() else {
            log("start ignored: the microphone is in use by the practice interview")
            return
        }
        retryPlan = .prepared
        refreshSessions()
        guard !settings.sessionName.isEmpty else {
            log("start ignored: no session")
            overlay.showError(L10n.tr("No session prepared. Run the prep for this meeting first."))
            showPanel()
            return
        }
        // Owner decision 7: every start path runs in Settings' call language, Auto by default (never the Meeting language).
        launchSession(name: settings.sessionName, mode: .prepared, route: .meeting, lang: settings.defaultCallLanguage)
    }

    // MARK: start anytime

    /// Starts now, with or without a prepared session (⌥⌘V, the menu's Start row, the island): `startChoice` (the next meeting's
    /// session from 60 minutes before it starts, else the session he picked by hand while that pick holds, otherwise an unprepared
    /// folder). The audio route is picked from what the Mac is doing. Nothing waits for a preparation.
    public func startNow() { startNow(unpreparedOnly: false) }

    /// Start unprepared (⌥⇧⌘V, the menu row under Start, the meeting prompt when no prepared session matches): an unprepared call
    /// at once, fed by the persona or the general prep when that is on. The selected session and the manual pick are left as
    /// they are (owner decision 5).
    public func startUnprepared() { startNow(unpreparedOnly: true) }

    /// The session he picked by hand that a start may use (`SessionSelector.manualSession`).
    public func manualSessionForStart() -> String? { selector.manualSession(now: clock()) }

    /// What ⌥⌘V starts at `now`: the one decision both `startNow` and the menu's Start row use, from the same inputs (the calendar
    /// around now, the session list with its links and `event.json` files, the manual pick).
    public func startChoice(now: Date? = nil) -> QuickStart.SessionChoice {
        let now = now ?? clock()
        let matcher = SessionMatcher(sessions: sessions, links: eventSessions.load(), sidecars: sessionInfo().sidecars)
        return QuickStart.pickSession(now: now, events: eventsAround(now), matcher: matcher, manualSession: selector.manualSession(now: now))
    }

    /// The menu's Start row: a pure preview of `startNow` (owner decision 3).
    public func startPreview(now: Date? = nil) -> StartRowPreview {
        let choice = startChoice(now: now)
        return StartRowPreview(choice: choice, sessionLabel: { name in self.pickerModel().label(of: name) ?? name })
    }

    private func startNow(unpreparedOnly: Bool) {
        guard !running, !stopping, !switching else {
            log("start now ignored: running=\(running) stopping=\(stopping) switching=\(switching)")
            return
        }
        guard !startBlocked() else {
            log("start now ignored: the microphone is in use by the practice interview")
            return
        }
        retryPlan = unpreparedOnly ? .unprepared : .now
        refreshSessions()
        let now = clock()
        let choice: QuickStart.SessionChoice = unpreparedOnly ? .adhoc : startChoice(now: now)
        // No Audio source override: the route is the automatic pick, which a meeting app joining later may correct.
        let autoRoute = routeChoice == nil
        do {
            let plan = try QuickStart.plan(choice: choice, now: now, facts: routeFacts(), lang: settings.defaultCallLanguage,
                                           root: sessionsRoot, routeOverride: routeChoice, useGeneralPrep: settings.useGeneralPrep)
            routeChoice = nil
            refreshSessions()
            if plan.mode == .prepared { settings.sessionName = plan.session }
            log("start now route=\(plan.route.rawValue) auto_route=\(autoRoute) mode=\(plan.mode.rawValue) session=\(plan.session)")
            launchSession(name: plan.session, mode: plan.mode, route: plan.route, lang: plan.lang, anytimeStart: true,
                          autoRoute: autoRoute)
        } catch {
            log("start now failed: \(error)")
            overlay.showError(L10n.tr("Could not create a session folder: \(error.localizedDescription)"))
            showPanel()
        }
    }

    /// `anytimeStart`: the session came from Start now (or a route/language change of one), so the island shows the start
    /// card with its route chip.
    /// `rehearsal`: "Rehearse a line…" runs the session from its temporary copy with typed lines instead of audio (no
    /// microphone, no process tap, no test file); everything after the recognizer is the same as a real call's.
    /// `autoRoute`: `route` is the automatic pick (no override by hand); see `QuickStart.MeetingRouteUpgrade`.
    private func launchSession(name: String, mode: SessionMode, route: AudioRoute, lang requested: String, anytimeStart: Bool = false,
                               autoRoute: Bool = false, rehearsal rehearsalRun: RehearsalRun? = nil) {
        if let rehearsalRun {
            retryPlan = .rehearsal(rehearsalRun.session)
        } else {
            let request = LaunchRequest(name: name, mode: mode, route: route, lang: requested, anytimeStart: anytimeStart,
                                        remoteFile: remoteFileOverride, autoRoute: autoRoute)
            retryPlan = .launch(request)
            if let launchOverride { launchOverride(request); return }
        }
        let dir = rehearsalRun?.workspace ?? SessionCatalog.url(name, root: sessionsRoot)
        // Auto starts in the session's prepared language (else English) and lets the call's own speech pick it from then on; the
        // cards follow the call's dominant language, which starts there too (owner decisions 7 and 8).
        let start = CallLanguage.start(requested: requested, prepared: CallLanguage.prepared(sessionDir: dir))
        // A rehearsal has no audio for AUTO to judge: it runs in the language Auto would start in.
        let auto = rehearsalRun == nil && start.auto
        let lang = start.engine
        var o = Self.runOptions(sessionDir: dir, settings: settings, fakeBrain: fakeBrain, testFile: rehearsalRun == nil ? testFile : nil,
                                micWithFile: rehearsalRun == nil && remoteFileOverride != nil, follow: meeting.settings.followMyAnswer,
                                mode: mode, route: route, lang: lang)
        o.autoLanguage = auto
        o.answerLangHint = start.hint
        o.onAutoLanguage = { [weak self] picked in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.autoSwitched(to: picked) } }
        }
        rehearsalRun?.feed.apply(to: &o)
        rehearsal = rehearsalRun
        log("start session=\(name) lang=\(lang) mode=\(mode.rawValue) route=\(route.rawValue) me=\(o.me != nil) fake=\(fakeBrain) file=\(rehearsalRun == nil ? testFile ?? "-" : "-") rehearsal=\(rehearsalRun != nil) live_seconds=\(o.seconds.map { String(Int($0)) } ?? "file")")
        lastLogLine = nil
        o.sink = { [weak self] e in
            // One FIFO hop to the main thread keeps the runner's order.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(e) } }
        }
        let micTap = prompter.meetingStarted(room: route == .room)
        o.transcriptTap = { micTap.ingest($0) }
        let r = VerseRunner(options: o, log: { [weak self] line in
            // Brain and runner logs go to ~/Library/Logs/Verse/verse.log; they never contain the key or audio.
            FileLog.shared.write(line)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.lastLogLine = line } }
        })
        overlay.bank = BankOpener.load(sessionDir: dir)
        overlay.config = settings.overlayConfig
        overlay.sessionStarting(lang: lang, session: name, app: route == .meeting && rehearsalRun == nil ? Self.meetingAppName() : nil,
                                route: anytimeStart ? route : nil, unprepared: mode == .unprepared, auto: auto)
        overlay.setCallCue(CallCue.load(sessionDir: dir))
        overlay.startClock()
        runner = r
        runSessionDir = dir
        runWasFake = fakeBrain
        runStartedAt = Date()
        sessionSpend = 0
        answersOff = nil
        lastRunNote = nil
        self.route = route
        routeUpgrade = QuickStart.MeetingRouteUpgrade(autoPicked: autoRoute, rehearsal: rehearsalRun != nil)
        sessionMode = mode
        callLanguage = lang
        autoLanguage = auto
        meLayer = nil
        meConflicts = []
        meLayerMissing = false
        stopConfirm.reset()
        setStopArmed(false)
        running = true
        lastExitCode = nil
        hotKeys?.setSessionRunning(true)
        reportAnswerKeys()
        showPanel()
        runTask = Task.detached { [weak self] in
            let code = await r.run()
            await self?.runEnded(code)
        }
    }

    // MARK: hot keys

    /// Registers ⌥⌘V and ⌥⇧⌘V. Called at launch by the controller itself inside the app.
    public func installGlobalHotKeys() {
        guard hotKeys == nil else { return }
        let keys = GlobalHotKeys(onStartStop: { [weak self] in self?.startStopKeyPressed() },
                                 onCardNow: { [weak self] in self?.cardNow() },
                                 onEarlierAnswer: { [weak self] in self?.showEarlierAnswer() },
                                 onNewerAnswer: { [weak self] in self?.showNewerAnswer() },
                                 onStartUnprepared: { [weak self] in self?.startUnpreparedKeyPressed() },
                                 onRegenerate: { [weak self] in self?.regenerate() },
                                 onMarkBad: { [weak self] in self?.markAnswer(.bad) })
        hotKeys = keys
        startHotKeyAvailable = keys.registerStartStop()
        if !startHotKeyAvailable { log("⌥⌘V is taken by another app; Start stays in the menu") }
        startUnpreparedHotKeyAvailable = keys.registerStartUnprepared()
        if !startUnpreparedHotKeyAvailable { log("⌥⇧⌘V is taken by another app; Start unprepared stays in the menu") }
        keys.setSessionRunning(running)
        reportAnswerKeys()
    }

    /// ⌥⌘← / ⌥⌘→ / ⇧< / ⌥⌘R / ⌥⌘↓ another app holds in this session: logged, and published for Settings. The island's
    /// buttons still work.
    private func reportAnswerKeys() {
        let taken = (hotKeys?.unavailableAnswerKeys ?? []).map(Self.keyLabel)
        if taken != unavailableAnswerKeys { unavailableAnswerKeys = taken }
        for k in taken { log("\(k) is taken by another app; the island's buttons still work") }
        if let shift = hotKeys?.earlierAnswerShiftSpec, hotKeys?.earlierAnswerShiftRegistered == true {
            log("⇧< is key code \(shift.keyCode) in this keyboard layout")
        }
    }

    static func keyLabel(_ spec: HotKeySpec) -> String {
        switch spec {
        case .earlierAnswer: return "⌥⌘←"
        case .newerAnswer: return "⌥⌘→"
        case .cardNow: return "⌥⌘↩"
        case .startStop: return "⌥⌘V"
        case .startUnprepared: return "⌥⇧⌘V"
        case .regenerate: return "⌥⌘R"
        case .markBad: return "⌥⌘↓"
        case _ where spec.isShiftLessThan: return "⇧<"
        default: return "?"
        }
    }

    /// Back to the earlier answer in the notch (⌥⌘←, ⇧<). The session itself is not touched. Ignored while the prompter
    /// covers the card, so a pin never happens out of sight.
    public func showEarlierAnswer() {
        guard running, !stopping, !prompter.isOpen else { return }
        overlay.showEarlierAnswer()
    }

    /// Regenerate (⌥⌘R, the island's button, the menu): a new answer to the question on screen, at once. Ignored while the prompter
    /// covers the card (the press would act on a card out of sight) and while one is in flight.
    public func regenerate() {
        guard running, !stopping, !prompter.isOpen else { return }
        if overlay.regenerate() == nil { log("regenerate ignored: no answer on screen, or one is already on its way") }
    }

    /// BAD on the answer on screen (⌥⌘↓, the island's button, the menu); the same mark again clears it.
    public func markAnswer(_ m: CardMark) {
        guard running, !stopping, !prompter.isOpen else { return }
        overlay.mark(m)
    }

    /// What the overlay's Regenerate sends: the brain's `control regenerate`. When the answer on screen was not in the dominant
    /// language, the brain resets the dominant language and the recognizers go back to it too (AUTO stays on).
    private func sendRegenerate(_ req: RegenerateRequest) -> Bool {
        guard running, !stopping, let r = runner else { return false }
        guard r.regenerate(turn: req.turn, question: req.question, lang: req.lang, reset: req.reset, avoid: req.avoid) else {
            log("regenerate not sent: the brain is not running")
            return false
        }
        log("regenerate turn=\(req.turn) lang=\(req.lang ?? "-") reset=\(req.reset)")
        if let lang = Self.recognizerReset(req, auto: autoLanguage, listening: callLanguage) {
            Task { await switchListening(lang: lang) }
        }
        return true
    }

    /// The language the recognizers go back to after a regenerate that reset the automatic language: the regenerated answer's
    /// language, when AUTO is on and the recognizers run in another one. nil: nothing to swap.
    nonisolated static func recognizerReset(_ req: RegenerateRequest, auto: Bool, listening: String) -> String? {
        guard req.reset, auto, let lang = req.lang, lang != listening else { return nil }
        return lang
    }

    private func sendMark(_ e: CardMarkEvent) {
        guard let r = runner, r.markCard(card: e.card, mark: e.mark, turn: e.turn, question: e.question) else {
            log("mark not recorded: the brain is not running")
            return
        }
        log("mark \(e.mark) card=\(e.card)")
    }

    /// Forward to the newer answer, then live (⌥⌘→).
    public func showNewerAnswer() {
        guard running, !stopping else { return }
        overlay.showNewerAnswer()
    }

    /// What ⌥⌘V means right now. Not running: start. Running: the first press arms the stop, a second one inside
    /// `StopConfirm.window` stops. Returns the decision (the side effect is done by `startStopKeyPressed`).
    func startStopKeyAction(running isRunning: Bool? = nil) -> StopConfirm.Action {
        let action = stopConfirm.press(running: isRunning ?? (running && !stopping), now: clock())
        switch action {
        case .arm: setStopArmed(true)
        case .start, .stop: setStopArmed(false)
        }
        return action
    }

    /// ⌥⇧⌘V: an unprepared call at once. It never stops a call; during one, and while a practice interview runs, it does nothing.
    public func startUnpreparedKeyPressed() {
        guard !running, !stopping else {
            log("⌥⇧⌘V ignored: a call is running")
            return
        }
        startUnprepared()
    }

    public func startStopKeyPressed() {
        if stopping { return }
        // A practice interview owns the microphone (review V1): ⌥⌘V never starts a meeting on top of it. Twice ends the
        // practice, as it stops a meeting; without a practice stop the key does nothing.
        if !running, startBlocked() {
            guard let endPractice = blockedStop else {
                log("⌥⌘V ignored: the microphone is in use by the practice interview")
                return
            }
            if startStopKeyAction(running: true) == .stop {
                log("practice ended by ⌥⌘V twice")
                endPractice()
            }
            return
        }
        switch startStopKeyAction() {
        case .start: startNow()
        case .arm: break
        case .stop:
            log("stop by ⌥⌘V twice")
            Task { await stop() }
        }
    }

    /// Wires the practice interview in (the app does it once at launch): no Start runs while it does, and ⌥⌘V twice ends it.
    public func bindPractice(_ sim: SimController) {
        startBlocked = { [weak sim] in sim?.running ?? false }
        blockedStop = { [weak sim] in sim?.endInterview() }
    }

    private func setStopArmed(_ on: Bool) {
        stopArmTask?.cancel()
        stopArmTask = nil
        stopArmed = on
        // The island says "Press ⌥⌘V again to stop" for as long as the confirmation lasts.
        overlay.setStopConfirm(on)
        if on { showPanel() }
        guard on else { return }
        stopArmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(StopConfirm.window))
            guard !Task.isCancelled else { return }
            self?.stopArmed = false
            self?.overlay.setStopConfirm(false)
        }
    }

    /// Renders only: Settings → Spend shows these (fictional) figures instead of the ledger in the user's sessions folder.
    func setSpendForPreview(session: Double, month: Double) {
        sessionSpend = session
        monthSpend = month
    }

    /// Renders and tests: what the Me page shows of the last session.
    func setMeForPreview(layer: MeLayerInfo?, conflicts: [MeConflict]) {
        meLayer = layer
        meConflicts = conflicts
    }

    // MARK: route and language

    /// The Route submenu / the route chip before a call: `nil` is the automatic pick. During a call the route changes at once
    /// (see `switchListening`). Phone is not a runnable route yet (phase B): it is heard through the room route.
    public func chooseRoute(_ r: AudioRoute?) {
        if running {
            guard let r else { return }
            // A route he picks during the call is his: a meeting app joining later never changes it.
            routeUpgrade.routeChosenByHand()
            Task { await switchListening(route: r) }
        } else {
            routeChoice = r.map(QuickStart.runnableRoute)
        }
    }

    /// AUTO language (owner decision 8): the call's dominant language, the one new answers are written in, as the brain reported
    /// it; nil when AUTO is off, no call runs or the brain has not said yet.
    public var dominantLanguage: String? { running ? overlay.state.dominantLang : nil }

    /// The language of the answer on screen (the live card, or the earlier one shown with Back); nil when unknown. A later
    /// regenerate compares it with `dominantLanguage`.
    public var answerLanguageOnScreen: String? { running ? overlay.displayState.card?.answerLang : nil }

    /// AUTO swapped the recognizers to the language it heard: the labels follow (the runner already told the brain).
    private func autoSwitched(to lang: String) {
        guard running, autoLanguage else { return }
        log("auto language → \(lang)")
        callLanguage = lang
        overlay.listeningChanged(route: route, lang: lang, app: route == .meeting ? Self.meetingAppName() : nil, auto: true)
    }

    private func startChip(_ action: StartChipAction) {
        switch action {
        case .cycleRoute: chooseRoute(StartRoutes.next(after: route))
        }
    }

    /// Changes the route and/or language of the running call in place. The runner swaps its listen pipeline (audio sources and
    /// recognizers) and tells the brain; the brain process, the session folder, the overlay's card, the turn numbering and the
    /// end-of-meeting summary are the ones of the same call, so the call goes on and `summary.md` covers all of it. What is lost
    /// is the audio of the swap itself (about a second). If the new pipeline cannot be prepared, the call keeps listening as it was.
    public func switchListening(route newRoute: AudioRoute? = nil, lang newLang: String? = nil) async {
        guard running, !stopping, !switching, let r = runner else { return }
        let route = QuickStart.runnableRoute(newRoute ?? self.route)
        let lang = newLang ?? callLanguage
        guard route != self.route || lang != callLanguage else { return }
        log("switch listening route \(self.route.rawValue)→\(route.rawValue) lang \(callLanguage)→\(lang)")
        switching = true
        let applied = await r.switchListening(route: route, lang: lang)
        switching = false
        // The call may have ended while the swap was under way: the controller's view of it is then already reset.
        guard running, runner === r else { return }
        guard applied else {
            log("switch listening not applied")
            return
        }
        self.route = route
        callLanguage = lang
        prompter.meetingRoute(room: route == .room)
        overlay.listeningChanged(route: route, lang: lang, app: route == .meeting ? Self.meetingAppName() : nil, auto: autoLanguage)
    }

    /// A meeting app took the microphone while this call runs (the meeting coordinator tells it; no prompt is shown then). A call
    /// that the automatic pick started on the room route moves to the meeting route in place: same session folder, brain and
    /// transcript (`switchListening`; the brain gets `control route`). See `QuickStart.MeetingRouteUpgrade` for what stays put.
    public func meetingDetectedDuringRun(appName: String) {
        guard running, !stopping else { return }
        guard routeUpgrade.meetingDetected(route: route, switching: switching) else { return }
        log("meeting detected in \(appName) while the call runs on the automatically picked room route: switching to the meeting route")
        Task { await switchListening(route: .meeting) }
    }

    /// ⌥⌘↩: answer the latest remote/room turn at once.
    public func cardNow() {
        guard running, !stopping, let r = runner else { return }
        log("card now")
        r.cardNow()
    }

    /// Settings > Testing's "Play as remote…": runs the selected session with `url` as the remote channel (the same file
    /// path as `--file`) while the real microphone stays "me", so the app can be tested without a meeting app.
    public func start(remoteFile url: URL) {
        guard !running, !stopping else { return }
        guard !startBlocked() else {
            log("start ignored: the microphone is in use by the practice interview")
            return
        }
        remoteFileOverride = url
        start()
        if !running { remoteFileOverride = nil }
    }

    // MARK: rehearse a line

    /// Starts a rehearsal of the prepared session `session`: the real session pipeline and brain on a temporary copy of its
    /// folder, fed by typed lines (`rehearse`) instead of audio. nil when it started (or this session's rehearsal already runs);
    /// otherwise why not. A real call, a practice interview or another session's rehearsal is never touched.
    @discardableResult
    public func startRehearsal(session: String) -> RehearsalRefusal? {
        if let r = rehearsal {
            return r.session == session && !stopping ? nil : .otherRehearsal(r.session)
        }
        guard !running, !stopping, !switching else {
            log("rehearsal refused: a call is running (running=\(running) stopping=\(stopping) switching=\(switching))")
            return .callRunning
        }
        guard !startBlocked() else {
            log("rehearsal refused: the practice interview is running")
            return .practiceRunning
        }
        refreshSessions()
        guard sessions.contains(session) else { return .noSuchSession(session) }
        let original = SessionCatalog.url(session, root: sessionsRoot)
        // Copies a killed app left behind go first; one rehearsal runs at a time.
        let swept = RehearsalWorkspace.sweep()
        if swept > 0 { log("rehearsal: removed \(swept) leftover temporary copies") }
        let workspace: URL
        do {
            workspace = try RehearsalWorkspace.make(copying: original)
        } catch {
            log("rehearsal: cannot copy the session folder: \(error)")
            return .copyFailed(error.localizedDescription)
        }
        log("rehearsal of \(session) in a temporary copy")
        launchSession(name: session, mode: .prepared, route: .meeting, lang: settings.defaultCallLanguage,
                      rehearsal: RehearsalRun(session: session, original: original, workspace: workspace, feed: RehearsalFeed()))
        return nil
    }

    /// Says `text` as `speaker` in the running rehearsal, where recognised speech would enter. nil when it was sent.
    @discardableResult
    public func rehearse(_ speaker: RehearsalSpeaker, _ text: String) -> RehearsalRefusal? {
        guard let r = rehearsal, running, !stopping else { return running ? .callRunning : .notStarted }
        let line = RehearsalFeed.clean(text)
        guard !line.isEmpty else { return .emptyLine }
        log("rehearsal line as \(speaker.rawValue): \(line.split(separator: " ").count) words")
        r.feed.say(speaker, line)
        return nil
    }

    /// Ends the running rehearsal (the brain writes its summary into the temporary copy, which is then removed). A real call is
    /// never stopped from here.
    public func endRehearsal() async {
        guard rehearsal != nil, running else { return }
        await stop()
    }

    /// Stops listening; the runner shuts the brain down. Returns when the run is over.
    public func stop() async {
        guard running, let r = runner else { return }
        log("stop requested")
        stopping = true
        r.requestStop()
        await runTask?.value
    }

    /// For Quit: stop, wait at most `timeout`, then kill any brain left.
    public func shutdown(timeout: TimeInterval = 6) async {
        if running, let r = runner {
            stopping = true
            r.requestStop()
            let task = runTask
            let finished = await withTaskGroup(of: Bool.self) { g in
                g.addTask { await task?.value; return true }
                g.addTask { try? await Task.sleep(for: .seconds(timeout)); return false }
                let first = await g.next() ?? false
                g.cancelAll()
                return first
            }
            if !finished { NSLog("Verse: the run did not end in %.0f s; killing the brain", timeout) }
        }
        BrainProcess.killAll()
        hotKeys?.unregisterAll()
        hotKeys = nil
        panel?.close()
        panel = nil
    }

    /// Renders only: shows the running state without a runner.
    func setRunningForPreview(_ on: Bool, session: URL? = nil) {
        running = on
        runSessionDir = on ? session : nil
    }

    private func runEnded(_ code: Int32) {
        running = false
        stopping = false
        hotKeys?.setSessionRunning(false)
        reportAnswerKeys()
        stopConfirm.reset()
        setStopArmed(false)
        lastExitCode = code
        runner = nil
        runTask = nil
        overlay.stopClock()
        prompter.meetingEnded()
        persistSpend()
        monthSpend = SpendLedger.thisMonth()
        log("run ended code=\(code)")
        // A rehearsal is not a call: no vault offer, no after-call work, no answers-off note. Its temporary copy goes now (the
        // brain has exited: `run()` returns after it).
        let rehearsed = rehearsal
        rehearsal = nil
        if let rehearsed {
            let removed = RehearsalWorkspace.remove(rehearsed.workspace)
            log("rehearsal of \(rehearsed.session) ended; temporary copy removed: \(removed)")
        }
        if rehearsed == nil, let dir = runSessionDir {
            let finished = FinishedRun(code: code, sessionName: dir.lastPathComponent, sessionDir: dir, startedAt: runStartedAt,
                                       isTest: runWasFake || remoteFileOverride != nil || testFile != nil)
            meeting.runFinished(finished)
            onRunFinished?(finished)
        }
        remoteFileOverride = nil
        // A brain given up on mid-call is a normal end (the runner exits 0): the transcript is complete, answers were off for the
        // rest of the call. The error it showed then goes; a note says what happened instead.
        if code == 0, rehearsed == nil, let off = answersOff, let dir = runSessionDir {
            if overlay.state.status == .error(off.message) { overlay.dismissStatus() }
            let note = RunEndNote.answersOff(since: off.at, summaryWritten: RunEndNote.summaryWritten(sessionDir: dir, since: runStartedAt))
            lastRunNote = note.title + " " + note.detail
            log("run ended normally with answers off since \(off.at)")
            if overlay.state.meetingPrompt == nil {
                overlay.showPrompt(MeetingPrompt(kind: .saved, title: note.title, subtitle: note.detail, acceptLabel: L10n.tr("OK")))
                showPanel()
            }
        }
        // Never fail silently: a failed run without a status of its own says what the log said last.
        if code != 0 {
            let detail = lastLogLine.map { L10n.tr("The session ended: \($0)") } ?? L10n.tr("The session ended with an error (code \(code)).")
            if overlay.state.status == nil || overlay.state.status == .error(L10n.tr("The session ended with an error.")) {
                overlay.showError(detail)
            }
            showPanel()
        }
        // Keep the overlay up only for a message that needs reading (permission, credit, error) or a question to answer.
        if overlay.state.status?.needsPanel != true, overlay.state.meetingPrompt == nil { panel?.hide() }
        // The next meeting's session, now that the call is over (a no-op while a prompt is still up; the next tick catches up).
        if calendarWatcher.isWatching {
            selector.reevaluate()
            considerAutoPrep()
        }
    }

    private func handle(_ e: RunnerEvent) {
        if case .status(let st, let m) = e { log("status \(st) \(m)") }
        if case .brain(let o) = e, o.type == "status" { log("brain status \(o[string: "state"] ?? "") \(o[string: "message"] ?? "")") }
        if case .metric(let o) = e, o[string: "stage"] == "session_t0" {
            log(String(format: "listening after %.1f s", Date().timeIntervalSince(runStartedAt)))
        }
        if case .metric(let o) = e, o[string: "stage"] == VerseRunner.answersOffStage, answersOff == nil {
            answersOff = (Date(), o[string: "message"] ?? "")
        }
        feedOverlay(e)
        prompter.meetingCard(overlay.state.card)
        if case .brain(let o) = e, o.type == "metric", let c = o[double: "cost_usd"], c > 0 {
            sessionSpend += c
            persistSpend()
        }
        if case .ended = e, overlay.state.status?.needsPanel != true, overlay.state.meetingPrompt == nil { panel?.hide() }
    }

    /// Gives the event to the overlay (which handles the room speaker and card-now turns itself) and keeps what the Me page
    /// shows from the brain's notices and its `ready` status.
    private func feedOverlay(_ e: RunnerEvent) {
        if case .brain(let o) = e {
            if let notice = BrainNotice(o) {
                switch notice {
                case .meConflicts(let items): meConflicts = items
                case .meMissing: meLayerMissing = true
                }
            }
            if let info = MeLayerInfo(readyStatus: o) { meLayer = info }
        }
        overlay.apply(e)
    }

    private func persistSpend() {
        // The fake brain reports made-up costs; they never reach the ledger.
        guard let dir = runSessionDir, sessionSpend > 0, !runWasFake else { return }
        // A rehearsal's real spend counts in the month under the prepared session, as its own kind (not a call run); its
        // temporary copy would take the record away with it.
        if let r = rehearsal {
            SpendLedger.record(sessionDir: r.original, startedAt: runStartedAt, costUSD: sessionSpend, kind: RehearsalRun.spendKind)
            return
        }
        SpendLedger.record(sessionDir: dir, startedAt: runStartedAt, costUSD: sessionSpend)
    }

    /// The error panel's Retry: clears the message and starts again the way the failed run was started (review U4): the same
    /// session folder, route, language and remote test file; a Start now that failed before it had a folder plans again.
    public func retry() {
        overlay.dismissStatus()
        guard !running, !stopping, !switching else {
            log("retry ignored: running=\(running) stopping=\(stopping) switching=\(switching)")
            return
        }
        guard !startBlocked() else {
            log("retry ignored: the microphone is in use by the practice interview")
            return
        }
        switch retryPlan {
        case nil, .prepared?: start()
        case .now?: startNow()
        case .unprepared?: startUnprepared()
        case .rehearsal(let name)?:
            log("retry rehearsal session=\(name)")
            if let refusal = startRehearsal(session: name) { overlay.showError(refusal.message) }
        case .launch(let r)?:
            log("retry session=\(r.name) mode=\(r.mode.rawValue) route=\(r.route.rawValue)")
            remoteFileOverride = r.remoteFile
            if r.mode == .prepared { settings.sessionName = r.name }
            launchSession(name: r.name, mode: r.mode, route: r.route, lang: r.lang, anytimeStart: r.anytimeStart,
                          autoRoute: r.autoRoute)
            if !running { remoteFileOverride = nil }
        }
    }

    private func showPanel() {
        if panel == nil {
            panel = NotchPanelController(model: overlay, settings: settings, prompter: prompter, onOpenSettings: { kind in
                SystemSettingsLink.open(permission: kind)
            }, onRetry: { [weak self] in self?.retry() })
            panel?.onFrameChange = { [weak self] in self?.onMeetingIslandChange?() }
        }
        panel?.show()
    }

    /// The practice interview (S4) shares this overlay and its panel; meetings and practice never run together.
    public func showOverlayPanel() { showPanel() }

    /// Hides the panel unless a meeting runs or a message needs reading.
    public func hideOverlayPanel() {
        if !running, overlay.state.status?.needsPanel != true, overlay.state.meetingPrompt == nil { panel?.hide() }
    }

    /// The overlay message's Dismiss: hide the panel when nothing is running.
    public func overlayDismissed() {
        if !running { panel?.hide() }
    }

    public var overlayWindowNumber: Int? { panel?.windowNumber }

    /// Test only (`--cycles N`): Start, wait for Ready (session_t0), Stop, and again at once. Returns the results.
    public func runCycles(_ n: Int, readyTimeout: TimeInterval = 90) async -> [Bool] {
        var results: [Bool] = []
        for i in 1...max(n, 1) {
            let t0 = Date()
            start()
            var ok = false
            while Date().timeIntervalSince(t0) < readyTimeout {
                if overlay.state.startup?.phase == .ready || overlay.state.startup?.phase == .listening { ok = true; break }
                if !running { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            log(String(format: "cycle %d: %@ after %.1f s", i, ok ? "READY" : "NOT READY", Date().timeIntervalSince(t0)))
            results.append(ok)
            await stop()
        }
        return results
    }
}

/// Deep links into System Settings > Privacy & Security.
public enum SystemSettingsLink {
    public static func url(permission: String) -> URL {
        // Microphone has its own pane; process taps (system audio recording) sit under
        // "Screen & System Audio Recording".
        let anchor: String
        switch permission {
        case "microphone": anchor = "Privacy_Microphone"
        case "calendar": anchor = "Privacy_Calendars"
        default: anchor = "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    @MainActor public static func open(permission: String) {
        NSWorkspace.shared.open(url(permission: permission))
    }
}

/// One session launch, as `VerseController.launchSession` got it: what Retry repeats.
struct LaunchRequest: Equatable, Sendable {
    var name: String
    var mode: SessionMode
    var route: AudioRoute
    /// As requested ("auto" stays "auto").
    var lang: String
    var anytimeStart: Bool
    /// "Play as remote…": the file that was the remote channel.
    var remoteFile: URL?
    /// The route was the automatic pick (no Audio source override).
    var autoRoute = false
}

/// What the error panel's Retry does (review U4).
enum RetryPlan: Equatable, Sendable {
    /// `start()` failed before it launched anything (no session): start it again.
    case prepared
    /// Start now failed before it launched anything (no session folder): plan again.
    case now
    /// Start unprepared failed before it had a folder: an unprepared call again.
    case unprepared
    /// A launched run failed: launch the same one again.
    case launch(LaunchRequest)
    /// A rehearsal failed: rehearse the same session again (never a real call, which would open the microphone).
    case rehearsal(String)
}
