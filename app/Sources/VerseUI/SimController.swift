import AppKit
import Combine
import Foundation
import VerseMeet
import VersePosting
import VerseTurns
import VerseVoice

/// One practice interview (S4): the setup window's state, S1 prep, the run (`SimRunner` over a sim brain), the
/// overlay and the report window. Meetings and practice never run at the same time.
@MainActor
public final class SimController: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case setup
        case preparing
        /// Prep is done; Start is enabled.
        case prepared
        case running
        case finished
    }

    // posting
    @Published public var postingLink = ""
    @Published public var pasteText = ""
    @Published public private(set) var posting: Posting?
    @Published public private(set) var postingConfirmed = false
    @Published public private(set) var fetching = false
    @Published public private(set) var fetchMessage: String?
    // everything else the setup window collects
    @Published public var setup = SimSetup(postingText: "")
    // prep
    @Published public private(set) var phase = Phase.setup
    @Published public private(set) var prepLines: [String] = []
    @Published public private(set) var prepError: String?
    @Published public private(set) var prepStartedAt: Date?
    @Published public private(set) var sessionDir: URL?
    @Published public private(set) var summary: SimPackSummary?
    @Published public private(set) var lastReport: URL?
    // practice from a meeting
    /// Prepared meeting sessions, newest first (`refreshMeetings`).
    @Published public private(set) var meetings: [PreparedMeeting] = []
    /// The session folder name chosen in the Meeting popup.
    @Published public var meetingName: String?
    /// What the chosen meeting's prep holds (the preview row).
    @Published public private(set) var meetingPreview: PracticeMeetings.Preview?
    /// The `tts_gap_ms` measurements of the last run (the runner logs them too).
    @Published public private(set) var lastTTSGaps: [SimRunner.TTSGap] = []
    /// The user picked the source himself; a refresh then keeps it.
    private var sourceChosen = false
    // practice from an upcoming calendar event
    /// Calendar events in the next 14 days, as the last `refreshUpcoming` read them (empty without calendar access).
    @Published public private(set) var calendarEvents: [MeetingEvent] = []
    /// The calendar event chosen in the Meeting popup (one with no prepared session); exclusive with `meetingName`.
    @Published public private(set) var upcomingEventID: String?
    /// The two steps of "Build interview" for an upcoming event; nil for a prepared meeting or a posting (one step).
    public enum PrepStep: Equatable, Sendable {
        /// Step 1 of 2: the meeting's own prep, from the calendar invite.
        case invite
        /// Step 2 of 2: the practice interview, from that session.
        case interview
    }
    @Published public private(set) var prepStep: PrepStep?
    /// Event id -> session folder name, read with the calendar events.
    private var remembered: [String: String] = [:]
    /// Where the events and the event prep come from (the Prepare page's Up next model).
    private var upcomingSource: HomeUpNextModel?
    /// Bumped when a prep flow starts or is cancelled; a flow whose token is stale stops quietly.
    private var flowToken = 0
    private let now: @Sendable () -> Date

    public let settings: AppSettings
    public let simSettings: SimSettings
    private let meeting: VerseController
    private var overlay: OverlayModel { meeting.overlay }
    private var prep: SimPrep?
    private var runner: SimRunner?
    private var hints: SimHints?
    private let hotKey = SimHotKey()
    private var runStartedAt = Date()
    private var runWasFake = false
    /// Interviewer lines being assembled for the hint card (sentences of one id).
    private var lineText: [String: String] = [:]

    /// Where the session folders are (the meeting's, so a test or a render that points it elsewhere moves both) and the
    /// profile folder (`me.md`).
    public var sessionsRoot: URL { meeting.sessionsRoot }
    private let meProfile: URL

    public init(settings: AppSettings, simSettings: SimSettings, meeting: VerseController,
                meProfile: URL = MeProfilePaths.defaultDirectory, now: @escaping @Sendable () -> Date = { Date() }) {
        self.settings = settings
        self.simSettings = simSettings
        self.meeting = meeting
        self.meProfile = meProfile
        self.now = now
        setup.voice = simSettings.voiceKind
        lastReport = SimSessionFolder.reports().first
    }

    public var running: Bool { phase == .running }
    public var fake: Bool { meeting.fakeBrain }

    private func log(_ s: String) { FileLog.shared.write("sim: " + s) }

    // MARK: meeting source

    /// Reads the prepared sessions again (the Practice page does this each time it appears) and keeps or picks the
    /// selection. `upNext`: the Up next items' session names in calendar order. Until the user picks a source, "A
    /// meeting" is the default when a prepared session exists, else "A job posting"; with none, a chosen meeting falls back.
    public func refreshMeetings(upNext: [String?] = []) {
        guard phase != .preparing, phase != .running else { return }
        meetings = PracticeMeetings.list(root: sessionsRoot)
        // An upcoming event that is prepared now (or fell out of the window) is no longer an upcoming choice.
        if upcomingEventID != nil, selectedUpcoming == nil { upcomingEventID = nil }
        if upcomingEventID == nil, meetingName == nil || !meetings.contains(where: { $0.name == meetingName }) {
            meetingName = PracticeMeetings.defaultPick(upNext: upNext, among: meetings)
        }
        settleSelection()
        updatePreview()
        if meetings.isEmpty, groups.upcoming.isEmpty {
            setup.source = .posting
        } else if !sourceChosen, !meetings.isEmpty {
            setup.source = .meeting
        }
    }

    /// With "A meeting" chosen and nothing selected (no prepared meeting, but calendar events), the soonest event is selected.
    private func settleSelection() {
        guard setup.source == .meeting, meetingName == nil, upcomingEventID == nil, let first = groups.upcoming.first else { return }
        upcomingEventID = first.id
    }

    // MARK: upcoming calendar events

    /// The Meeting popup's rows: prepared sessions (with the date of their calendar event, when one is in the next 14 days) and
    /// the calendar events that have no prepared session.
    public var groups: PracticeMeetings.Groups {
        PracticeMeetings.groups(prepared: meetings, events: calendarEvents, remembered: remembered, now: now())
    }

    public var selectedUpcoming: UpcomingMeeting? { upcomingEventID.flatMap { id in groups.upcoming.first { $0.id == id } } }

    /// The popup's current choice.
    public var choice: MeetingChoice? {
        if let id = upcomingEventID { return .upcoming(id) }
        return meetingName.map { .prepared($0) }
    }

    public func choose(_ c: MeetingChoice?) {
        switch c {
        case .prepared(let name)?: selectMeeting(name)
        case .upcoming(let id)?: selectUpcoming(id)
        case nil: selectMeeting(nil)
        }
    }

    /// Where the calendar events and the event prep come from: the same Up next model the Prepare page uses.
    public func attachUpcoming(_ model: HomeUpNextModel?) { upcomingSource = model }

    /// Reads the next 14 days of the calendar. Without access (or with the calendar off) the list is empty and the popup shows
    /// only the prepared group. Skipped while a prep or a practice is running.
    public func refreshUpcoming() async {
        guard let source = upcomingSource else { return }
        let events = await source.upcomingEvents(within: PracticeMeetings.upcomingWindow, now: now())
        let map = source.rememberedSessions
        guard phase != .preparing, phase != .running else { return }
        calendarEvents = events
        remembered = map
        if upcomingEventID != nil, selectedUpcoming == nil { upcomingEventID = nil }
        if upcomingEventID == nil, meetingName == nil { meetingName = PracticeMeetings.defaultPick(upNext: [], among: meetings) }
        settleSelection()
        updatePreview()
        if !sourceChosen, !meetings.isEmpty { setup.source = .meeting }
    }

    /// The popup's choice of a calendar event that has no prepared session.
    public func selectUpcoming(_ id: String) {
        guard phase != .preparing, phase != .running, groups.upcoming.contains(where: { $0.id == id }) else { return }
        upcomingEventID = id
        meetingName = nil
        updatePreview()
        if phase == .prepared || phase == .finished { newInterview() }
    }

    /// The user's choice in the "Practise for" control.
    public func chooseSource(_ s: SimSetup.Source) {
        sourceChosen = true
        guard s != setup.source else { return }
        setup.source = s
        settleSelection()
        updatePreview()
        if phase == .prepared || phase == .finished { newInterview() }
    }

    /// The popup's choice (also what Up next's Practise sets).
    public func selectMeeting(_ name: String?) {
        guard phase != .preparing, phase != .running else { return }
        meetingName = name
        upcomingEventID = nil
        updatePreview()
        if phase == .prepared || phase == .finished { newInterview() }
    }

    /// Up next → Practise: "A meeting" with `name` selected. Ignored while a prep or a practice is running, or when
    /// `name` is not a prepared meeting.
    @discardableResult
    public func practise(session name: String) -> Bool {
        guard phase != .preparing, phase != .running else { return false }
        meetings = PracticeMeetings.list(root: sessionsRoot)
        guard meetings.contains(where: { $0.name == name }) else {
            updatePreview()
            return false
        }
        sourceChosen = true
        setup.source = .meeting
        selectMeeting(name)
        return true
    }

    private func updatePreview() {
        meetingPreview = meetings.first { $0.name == meetingName }.map { PracticeMeetings.preview(sessionDir: $0.dir) }
    }

    public var selectedMeeting: PreparedMeeting? { meetings.first { $0.name == meetingName } }

    // MARK: posting

    public func fetchPosting() {
        let raw = postingLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw.contains("://") ? raw : "https://" + raw), url.host != nil else {
            fetchMessage = "That is not a link. Paste the posting text below instead."
            return
        }
        fetching = true
        fetchMessage = nil
        Task { @MainActor in
            defer { fetching = false }
            do {
                let p = try await PostingFetcher.fetch(url)
                usePosting(p)
            } catch PostingError.network {
                fetchMessage = "Could not reach the page. Check the link, or paste the posting text below."
            } catch {
                fetchMessage = "No job posting found on that page. Paste the posting text below instead."
            }
        }
    }

    public func usePastedText() {
        let p = PostingFetcher.pasted(pasteText)
        guard !p.text.isEmpty else {
            fetchMessage = "The paste box is empty."
            return
        }
        fetchMessage = nil
        usePosting(p)
    }

    private func usePosting(_ p: Posting) {
        posting = p
        postingConfirmed = false
        if let c = p.company, !c.isEmpty { setup.company = c }
        if phase == .prepared || phase == .finished { phase = .setup }
    }

    /// The user read the preview and it is the right posting.
    public func confirmPosting() {
        guard let p = posting else { return }
        setup.postingText = p.text
        setup.postingURL = p.url
        postingConfirmed = true
    }

    public func clearPosting() {
        posting = nil
        postingConfirmed = false
    }

    /// Where the session folder will be created (prep may add `-2` when that name is taken).
    public var expectedFolderName: String? {
        if setup.source == .meeting {
            // An upcoming event has no session folder yet (prep names it), so there is nothing to predict for it.
            return selectedMeeting.map { SimSessionFolder.name(company: $0.name) }
        }
        guard let p = posting else { return nil }
        let company = setup.company.isEmpty ? (p.company ?? "company") : setup.company
        return SimSessionFolder.name(company: company)
    }

    // MARK: prep

    public var canPrepare: Bool {
        let ready = setup.source == .meeting ? selectedMeeting != nil || (selectedUpcoming != nil && upcomingSource != nil) : postingConfirmed
        return ready && phase != .preparing && phase != .running && !meeting.running
    }

    public func prepare() {
        guard canPrepare, let brainDir = VerseController.brainDir() else {
            if VerseController.brainDir() == nil { prepError = "The brain folder was not found (set VERSE_BRAIN_DIR)." }
            return
        }
        var s = setup
        s.fake = fake
        flowToken += 1
        let token = flowToken
        if s.source == .meeting {
            // The profile joins the pack when "Use my profile in every session" is on and it has been built.
            let me = meProfile.appendingPathComponent("me.md")
            s.meFile = settings.useMeProfile && FileManager.default.fileExists(atPath: me.path) ? me : nil
            if let m = selectedMeeting {
                s.meetingSession = m.dir
            } else if let u = selectedUpcoming, let source = upcomingSource {
                prepareFromInvite(u, source: source, setup: s, brainDir: brainDir, token: token)
                return
            } else {
                return
            }
        }
        beginPrep(step: nil)
        logPrepStart(s)
        Task { @MainActor in await runInterviewPrep(s, brainDir: brainDir, token: token) }
    }

    private func beginPrep(step: PrepStep?) {
        phase = .preparing
        prepStep = step
        prepLines = []
        prepError = nil
        summary = nil
        sessionDir = nil
        prepStartedAt = Date()
    }

    private func logPrepStart(_ s: SimSetup) {
        log("prep start source=\(s.source.rawValue) me=\(s.meFile != nil) type=\(s.type.rawValue) difficulty=\(s.difficulty.rawValue) length=\(s.lengthMin) cv=\(s.cv != nil) note=\(!s.note.isEmpty) vault=\(s.useVault) repos=\(s.repos.count) fake=\(s.fake)")
    }

    /// The practice interview itself (S1 prep over a session or a posting).
    private func runInterviewPrep(_ s: SimSetup, brainDir: URL, token: Int) async {
        let p = SimPrep()
        prep = p
        let outcome = await p.run(s, brainDir: brainDir, root: sessionsRoot, onLine: { [weak self] l in
            FileLog.shared.write("[sim prep] " + l)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.prepLines.append(l) } }
        })
        prep = nil
        guard token == flowToken else { return }
        prepStep = nil
        switch outcome {
        case .done(let dir):
            sessionDir = dir
            summary = SimPackSummary.load(sessionDir: dir)
            phase = .prepared
            log("prep done \(dir.lastPathComponent)")
        case .failed(let m):
            prepError = m
            phase = .setup
            log("prep failed: \(m)")
        case .cancelled:
            phase = .setup
            log("prep cancelled")
        }
    }

    /// "Build interview" for a calendar event with no prepared session, in one flow: the event prep first (the Prepare page's
    /// call, which also remembers the session for the event), then the practice interview from the session it made.
    private func prepareFromInvite(_ u: UpcomingMeeting, source: HomeUpNextModel, setup start: SimSetup, brainDir: URL, token: Int) {
        beginPrep(step: .invite)
        log("prep start source=invite fake=\(start.fake)")
        Task { @MainActor in
            let dir: URL
            do {
                dir = try await source.prepareSession(for: u.event)
                let pack = dir.appendingPathComponent("pack.md")
                let size = (try? FileManager.default.attributesOfItem(atPath: pack.path))?[.size] as? Int ?? 0
                guard size > 0 else { throw InvitePrepError.noPack(dir.lastPathComponent) }
            } catch {
                guard token == flowToken else { return }
                prepError = L10n.tr("Could not prepare “\(u.title)” from its invite: \(String(describing: error))")
                prepStep = nil
                phase = .setup
                log("invite prep failed: \(error)")
                return
            }
            // The new session is a prepared meeting now, whether or not this flow goes on.
            meetings = PracticeMeetings.list(root: sessionsRoot)
            remembered = source.rememberedSessions
            guard token == flowToken else {
                log("invite prep finished after cancel \(dir.lastPathComponent)")
                return
            }
            log("invite prep done \(dir.lastPathComponent)")
            meetingName = dir.lastPathComponent
            upcomingEventID = nil
            prepStep = .interview
            var s = start
            s.meetingSession = dir
            logPrepStart(s)
            await runInterviewPrep(s, brainDir: brainDir, token: token)
        }
    }

    enum InvitePrepError: Error, CustomStringConvertible {
        case noPack(String)
        var description: String {
            switch self {
            case .noPack(let n): return "prep wrote no pack for \(n)"
            }
        }
    }

    public func cancelPrep() {
        if let p = prep {
            p.cancel()
        } else if phase == .preparing, prepStep == .invite {
            // The invite prep is a child process without a handle: let it finish, but stop the flow here.
            flowToken += 1
            prepStep = nil
            phase = .setup
            log("prep cancelled (invite)")
        }
    }

    // MARK: run

    public var canStart: Bool {
        phase == .prepared && sessionDir != nil && !meeting.running && SimSettings.isAvailable(setup.voice)
    }

    public func start() {
        guard canStart, let dir = sessionDir, let brainDir = VerseController.brainDir() else { return }
        let kind = setup.voice
        let fakeRun = fake
        // The interview language (`sim.json`): the mic recognizes it and the system voice speaks it. A saved Apple voice
        // is an English choice, so another language takes the best installed voice for it instead.
        let lang = SimPackSummary.lang(sessionDir: dir)
        let appleID = lang == "en" ? simSettings.voiceID(for: .apple) : nil
        let voice: any VoiceEngine
        if kind == .text {
            voice = TextVoice()
        } else {
            let primary: any VoiceEngine = kind == .apple ? AppleVoice(voiceID: appleID, lang: lang)
                : VoiceFactory.make(kind, voiceID: simSettings.voiceID(for: kind))
            let fallback = AppleVoice(voiceID: appleID, lang: lang)
            voice = FallbackVoice(primary: primary, fallback: fallback, onFallback: { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.overlay.simApply(.voiceFallback(kind)) } }
            })
        }
        let brain: BrainProcess
        do {
            brain = try BrainProcess(brainDir: brainDir, extraArgs: fakeRun ? ["--fake"] : [],
                                     onStderr: { l in FileLog.shared.write("[sim brain] " + l) })
            try brain.start()
        } catch {
            overlay.showError("Could not start the interview: \(error)")
            meeting.showOverlayPanel()
            return
        }
        var config = SimRunner.Config()
        config.lang = lang
        let r = SimRunner(transport: brain, voice: voice, mic: ListenSimMic(lang: lang), config: config, sink: { [weak self] e in
            // One FIFO hop to the main thread keeps the runner's order.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(e) } }
        })
        runner = r
        runStartedAt = Date()
        runWasFake = fakeRun
        lineText = [:]
        phase = .running
        log("start \(dir.lastPathComponent) lang=\(lang) mode=\(setup.mode.rawValue) voice=\(kind.rawValue) hints=\(setup.hints) fake=\(fakeRun)")
        overlay.simStarting(voice: kind.rawValue, showCaption: simSettings.showCaption)
        overlay.simActions = { [weak self] a in self?.action(a) }
        meeting.showOverlayPanel()
        if !hotKey.register({ [weak self] in self?.action(.doneAnswering) }) { log("⌥Space is taken by another app; use Done") }
        if setup.hints {
            let h = SimHints(overlay: overlay, log: { [weak self] in self?.log($0) })
            h.start(sessionDir: dir, brainDir: brainDir, fake: fakeRun)
            hints = h
        }
        let mode = setup.mode
        Task { await r.start(sessionDir: dir, mode: mode, voice: kind) }
    }

    /// The overlay buttons and ⌥Space.
    func action(_ a: SimUIAction) {
        guard let r = runner else { return }
        switch a {
        case .skip: Task { await r.control(.skip) }
        case .repeat: Task { await r.control(.repeat) }
        case .end: Task { await r.control(.end) }
        case .doneAnswering: Task { await r.doneAnswering() }
        case .toggleCaption: simSettings.showCaption = overlay.state.sim?.showCaption ?? simSettings.showCaption
        }
    }

    /// Ends the interview now; the brain closes it and writes the report.
    public func endInterview() { action(.end) }

    /// Stops at once without a report (Quit). The transcript so far stays in `sim_results.json`.
    public func shutdown() async {
        if let r = runner { await r.stop() }
        await hints?.stop()
        hints = nil
        hotKey.unregister()
    }

    private func handle(_ e: SimEvent) {
        overlay.simApply(e)
        switch e {
        case .status(let st, let m):
            if st != "ready", st != "warming" { log("status \(st) \(m)") }
        case .say(let id, let text, let final):
            lineText[id] = [lineText[id], text].compactMap { $0 }.joined(separator: " ")
            if final, let full = lineText.removeValue(forKey: id) { hints?.interviewerLine(id: id, text: full) }
        case .report(let path):
            log("report \(path)")
            let u = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: u.path) {
                lastReport = u
                SimReportWindow.show(report: u)
            }
        case .ended(let code):
            log("ended code=\(code)")
            runEnded()
        default:
            break
        }
    }

    private func runEnded() {
        let ended = runner
        runner = nil
        phase = .finished
        overlay.simActions = nil
        hotKey.unregister()
        let h = hints
        hints = nil
        Task { await h?.stop() }
        recordSpend()
        meeting.hideOverlayPanel()
        if let ended { Task { @MainActor in await self.recordTTSGaps(ended) } }
    }

    /// The runner's `tts_gap_ms` measurements (line gaps: the wait after JUDGE; sentence gaps: silence inside a line) go
    /// to the log, one line each, and to `lastTTSGaps`. Numbers and line ids only: no text, no audio.
    private func recordTTSGaps(_ r: SimRunner) async {
        let gaps = await r.ttsGaps
        lastTTSGaps = gaps
        for g in gaps { log("tts_gap_ms \(g.ms) kind=\(g.kind.rawValue) line=\(g.lineID) prefetched=\(g.prefetched)") }
        let lines = gaps.filter { $0.kind == .line }
        if !lines.isEmpty {
            let prefetched = lines.filter(\.prefetched).map(\.ms)
            log("tts_gap_ms summary lines=\(lines.count) prefetched=\(prefetched.count) prefetched_ms=\(prefetched)")
        }
    }

    /// The sim brain writes its spend into `sim_results.json` (`usage_usd`); it joins the month's total like meetings.
    private func recordSpend() {
        guard !runWasFake, let dir = sessionDir,
              let d = try? Data(contentsOf: dir.appendingPathComponent("sim_results.json")),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let usd = o["usage_usd"] as? Double, usd > 0 else { return }
        SpendLedger.record(sessionDir: dir, startedAt: runStartedAt, costUSD: usd)
    }

    public func openLastReport() {
        if let u = lastReport { SimReportWindow.show(report: u) }
    }

    /// Back to the setup form for another interview with the same posting.
    public func newInterview() {
        guard phase == .finished || phase == .prepared else { return }
        phase = .setup
        sessionDir = nil
        summary = nil
    }
}
