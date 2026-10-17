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
    /// The me layer, as the brain reported it for the running session: nil = no layer.
    @Published public private(set) var meLayer: MeLayerInfo?
    /// Where the me layer and the meeting pack disagree on a number (the brain's `notice`, once after start).
    @Published public private(set) var meConflicts: [MeConflict] = []
    /// `start.me` named files that do not exist: the session ran without the layer.
    @Published public private(set) var meLayerMissing = false

    public let settings: AppSettings
    public let overlay: OverlayModel
    /// T-UI: the teleprompter (view model, settings, script editor).
    public let prompter = PrompterModel()
    public let launch: LaunchOptions
    private var panel: NotchPanelController?
    private var runner: VerseRunner?
    private var runTask: Task<Void, Never>?
    private var runStartedAt = Date()
    private var runSessionDir: URL?
    private var runWasFake = false
    private var cancellables: Set<AnyCancellable> = []
    /// "Play test file as remote…": the file is the remote channel and the microphone stays "me". Cleared when the run ends.
    private var remoteFileOverride: URL?
    /// Meeting detection ("Meeting detected · Start Verse?") and the summary-to-vault question.
    public lazy var meeting = MeetingCoordinator(host: self)

    // Anytime calls
    private var hotKeys: GlobalHotKeys?
    private var stopConfirm = StopConfirm()
    private var stopArmTask: Task<Void, Never>?
    /// The route picked by hand in the menu for the next Start; nil = the automatic pick. Used once.
    @Published public private(set) var routeChoice: AudioRoute?
    /// A route or language change of the running call is under way (one at a time).
    private var switching = false
    /// The clock the double-press stop uses; tests replace it.
    public var clock: () -> Date = { Date() }
    /// Calendar events around a time, for choosing a prepared session. Default: the calendar, when its access was granted.
    public var eventsAround: (Date) -> [MeetingEvent] = { when in
        CalendarSource().overlapping(now: when, margin: QuickStart.eventWindow)
    }
    /// The facts the route is picked from. Default: Core Audio's per-process flags, never audio.
    public var routeFacts: () -> QuickStart.RouteFacts = {
        QuickStart.RouteFacts(phoneCallActive: false,
                              meetingAppHoldsMic: QuickStart.meetingAppHoldsMic(CoreAudioProcessTable().snapshot()))
    }
    /// Event id -> prepared session, as the calendar prep remembered it.
    public var eventSessions = EventSessionMap()
    /// Something else (the practice interview) owns the microphone: a hot key Start does nothing.
    public var startBlocked: () -> Bool = { false }
    /// Where the unprepared session folders go. Tests point it at a temp folder.
    public var sessionsRoot: URL = SessionCatalog.root

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
        if !sessions.contains(settings.sessionName) { settings.sessionName = sessions.first ?? "" }
    }

    /// The brain folder: `VERSE_BRAIN_DIR`, then the repo path written into Info.plist at bundle time, then the
    /// upward search from the executable (a `swift run` from the repo).
    static func brainDir() -> URL? {
        if let env = ProcessInfo.processInfo.environment["VERSE_BRAIN_DIR"], !env.isEmpty { return URL(fileURLWithPath: env) }
        if let p = Bundle.main.object(forInfoDictionaryKey: "VerseBrainDir") as? String, !p.isEmpty { return URL(fileURLWithPath: p) }
        return try? BrainProcess.locateBrainDir()
    }

    public var statusLine: String {
        if stopping { return "Stopping…" }
        if running {
            var s = "Listening · \(settings.sessionName)"
            if testFile != nil { s += " (test file)" }
            if fakeBrain { s += " · fake brain" }
            return s
        }
        if sessions.isEmpty { return "No session prepared" }
        return "Ready · \(settings.sessionName)"
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
        refreshSessions()
        guard !settings.sessionName.isEmpty else {
            log("start ignored: no session")
            overlay.showError("No session prepared. Run the prep for this meeting first.")
            showPanel()
            return
        }
        launchSession(name: settings.sessionName, mode: .prepared, route: .meeting, lang: settings.language)
    }

    // MARK: start anytime

    /// Starts now, with or without a prepared session (⌥⌘V, the menu, the island): a prepared session linked to a calendar
    /// event around now when there is one, otherwise an unprepared folder. The audio route is picked from what the Mac is
    /// doing. Nothing waits for a preparation.
    public func startNow() {
        guard !running, !stopping, !switching else {
            log("start now ignored: running=\(running) stopping=\(stopping) switching=\(switching)")
            return
        }
        guard !startBlocked() else {
            log("start now ignored: the microphone is in use by the practice interview")
            return
        }
        refreshSessions()
        let now = clock()
        let events = meeting.settings.useCalendar ? eventsAround(now) : []
        do {
            let plan = try QuickStart.plan(now: now, facts: routeFacts(), events: events, remembered: eventSessions.load(),
                                           sessions: sessions, lang: settings.defaultCallLanguage, root: sessionsRoot,
                                           routeOverride: routeChoice, useGeneralPrep: settings.useGeneralPrep)
            routeChoice = nil
            refreshSessions()
            if plan.mode == .prepared { settings.sessionName = plan.session }
            log("start now route=\(plan.route.rawValue) mode=\(plan.mode.rawValue) session=\(plan.session)")
            launchSession(name: plan.session, mode: plan.mode, route: plan.route, lang: plan.lang, anytimeStart: true)
        } catch {
            log("start now failed: \(error)")
            overlay.showError("Could not create a session folder: \(error.localizedDescription)")
            showPanel()
        }
    }

    /// `anytimeStart`: the session came from Start now (or a route/language change of one), so the island shows the start
    /// card with its route and language chips.
    private func launchSession(name: String, mode: SessionMode, route: AudioRoute, lang requested: String, anytimeStart: Bool = false) {
        let dir = SessionCatalog.url(name, root: sessionsRoot)
        // "auto" starts in English (the fastest engine) and lets the call's own speech pick the language.
        let auto = requested == AppSettings.autoLanguage
        let lang = auto ? "en" : requested
        var o = Self.runOptions(sessionDir: dir, settings: settings, fakeBrain: fakeBrain, testFile: testFile,
                                micWithFile: remoteFileOverride != nil, follow: meeting.settings.followMyAnswer,
                                mode: mode, route: route, lang: lang)
        o.autoLanguage = auto
        o.onAutoLanguage = { [weak self] picked in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.autoSwitched(to: picked) } }
        }
        log("start session=\(name) lang=\(lang) mode=\(mode.rawValue) route=\(route.rawValue) me=\(o.me != nil) fake=\(fakeBrain) file=\(testFile ?? "-") live_seconds=\(o.seconds.map { String(Int($0)) } ?? "file")")
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
        overlay.sessionStarting(lang: lang, session: name, app: route == .meeting ? Self.meetingAppName() : nil,
                                route: anytimeStart ? route : nil, unprepared: mode == .unprepared, auto: auto)
        overlay.startClock()
        runner = r
        runSessionDir = dir
        runWasFake = fakeBrain
        runStartedAt = Date()
        sessionSpend = 0
        self.route = route
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
        showPanel()
        runTask = Task.detached { [weak self] in
            let code = await r.run()
            await self?.runEnded(code)
        }
    }

    // MARK: hot keys

    /// Registers ⌥⌘V. Called at launch by the controller itself inside the app.
    public func installGlobalHotKeys() {
        guard hotKeys == nil else { return }
        let keys = GlobalHotKeys(onStartStop: { [weak self] in self?.startStopKeyPressed() },
                                 onCardNow: { [weak self] in self?.cardNow() })
        hotKeys = keys
        startHotKeyAvailable = keys.registerStartStop()
        if !startHotKeyAvailable { log("⌥⌘V is taken by another app; Start now stays in the menu") }
        keys.setSessionRunning(running)
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

    public func startStopKeyPressed() {
        if stopping { return }
        switch startStopKeyAction() {
        case .start: startNow()
        case .arm: break
        case .stop:
            log("stop by ⌥⌘V twice")
            Task { await stop() }
        }
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
            Task { await switchListening(route: r) }
        } else {
            routeChoice = r.map(QuickStart.runnableRoute)
        }
    }

    /// The Language submenu / the language chips: before a call it is the default call language; during one the call
    /// listens and answers in that language from now on (and the default stays what it was).
    ///
    /// "auto" turns the interim AUTO mode on (the call follows the spoken language); "en", "it" and "tr" pin that language and
    /// turn AUTO off, so a pinned call never switches by itself.
    public func chooseLanguage(_ lang: String) {
        guard AppSettings.callLanguages.contains(lang) else { return }
        guard running else {
            settings.defaultCallLanguage = lang
            return
        }
        guard let r = runner, !stopping else { return }
        let auto = lang == AppSettings.autoLanguage
        r.setAutoLanguage(auto)
        autoLanguage = auto
        overlay.listeningChanged(route: route, lang: callLanguage, app: route == .meeting ? Self.meetingAppName() : nil, auto: auto)
        log("language \(auto ? "auto" : "pinned " + lang)")
        if !auto { Task { await switchListening(lang: lang) } }
    }

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
        case .setLanguage(let l): chooseLanguage(l)
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

    /// ⌥⌘↩: answer the latest remote/room turn at once.
    public func cardNow() {
        guard running, !stopping, let r = runner else { return }
        log("card now")
        r.cardNow()
    }

    /// The menu's "Play test file as remote…": runs the selected session with `url` as the remote channel (the same file
    /// path as `--file`) while the real microphone stays "me", so the app can be tested without a meeting app.
    public func start(remoteFile url: URL) {
        guard !running, !stopping else { return }
        remoteFileOverride = url
        start()
        if !running { remoteFileOverride = nil }
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
    func setRunningForPreview(_ on: Bool) { running = on }

    private func runEnded(_ code: Int32) {
        running = false
        stopping = false
        hotKeys?.setSessionRunning(false)
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
        if let dir = runSessionDir {
            meeting.runFinished(FinishedRun(code: code, sessionName: dir.lastPathComponent, sessionDir: dir, startedAt: runStartedAt,
                                            isTest: runWasFake || remoteFileOverride != nil || testFile != nil))
        }
        remoteFileOverride = nil
        // Never fail silently: a failed run without a status of its own says what the log said last.
        if code != 0 {
            let detail = lastLogLine.map { "The session ended: \($0)" } ?? "The session ended with an error (code \(code))."
            if overlay.state.status == nil || overlay.state.status == .error("The session ended with an error.") {
                overlay.showError(detail)
            }
            showPanel()
        }
        // Keep the overlay up only for a message that needs reading (permission, credit, error) or a question to answer.
        if overlay.state.status?.needsPanel != true, overlay.state.meetingPrompt == nil { panel?.hide() }
    }

    private func handle(_ e: RunnerEvent) {
        if case .status(let st, let m) = e { log("status \(st) \(m)") }
        if case .brain(let o) = e, o.type == "status" { log("brain status \(o[string: "state"] ?? "") \(o[string: "message"] ?? "")") }
        if case .metric(let o) = e, o[string: "stage"] == "session_t0" {
            log(String(format: "ready after %.1f s", Date().timeIntervalSince(runStartedAt)))
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
        SpendLedger.record(sessionDir: dir, startedAt: runStartedAt, costUSD: sessionSpend)
    }

    /// The error panel's Retry: clears the message and starts again.
    public func retry() {
        overlay.dismissStatus()
        start()
    }

    private func showPanel() {
        if panel == nil {
            panel = NotchPanelController(model: overlay, settings: settings, prompter: prompter, onOpenSettings: { kind in
                SystemSettingsLink.open(permission: kind)
            }, onRetry: { [weak self] in self?.retry() })
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
        let anchor = permission == "microphone" ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    @MainActor public static func open(permission: String) {
        NSWorkspace.shared.open(url(permission: permission))
    }
}
