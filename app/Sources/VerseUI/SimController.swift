import AppKit
import Combine
import Foundation
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
                meProfile: URL = MeProfilePaths.defaultDirectory) {
        self.settings = settings
        self.simSettings = simSettings
        self.meeting = meeting
        self.meProfile = meProfile
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
        if meetingName == nil || !meetings.contains(where: { $0.name == meetingName }) {
            meetingName = PracticeMeetings.defaultPick(upNext: upNext, among: meetings)
        }
        updatePreview()
        if meetings.isEmpty {
            setup.source = .posting
        } else if !sourceChosen {
            setup.source = .meeting
        }
    }

    /// The user's choice in the "Practise for" control.
    public func chooseSource(_ s: SimSetup.Source) {
        sourceChosen = true
        guard s != setup.source else { return }
        setup.source = s
        if phase == .prepared || phase == .finished { newInterview() }
    }

    /// The popup's choice (also what Up next's Practise sets).
    public func selectMeeting(_ name: String?) {
        guard phase != .preparing, phase != .running else { return }
        meetingName = name
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
            return selectedMeeting.map { SimSessionFolder.name(company: $0.name) }
        }
        guard let p = posting else { return nil }
        let company = setup.company.isEmpty ? (p.company ?? "company") : setup.company
        return SimSessionFolder.name(company: company)
    }

    // MARK: prep

    public var canPrepare: Bool {
        let ready = setup.source == .meeting ? selectedMeeting != nil : postingConfirmed
        return ready && phase != .preparing && phase != .running && !meeting.running
    }

    public func prepare() {
        guard canPrepare, let brainDir = VerseController.brainDir() else {
            if VerseController.brainDir() == nil { prepError = "The brain folder was not found (set VERSE_BRAIN_DIR)." }
            return
        }
        var s = setup
        s.fake = fake
        if s.source == .meeting {
            guard let m = selectedMeeting else { return }
            s.meetingSession = m.dir
            // The profile joins the pack when "Use my profile in every session" is on and it has been built.
            let me = meProfile.appendingPathComponent("me.md")
            s.meFile = settings.useMeProfile && FileManager.default.fileExists(atPath: me.path) ? me : nil
        }
        let p = SimPrep()
        prep = p
        phase = .preparing
        prepLines = []
        prepError = nil
        summary = nil
        sessionDir = nil
        prepStartedAt = Date()
        log("prep start source=\(s.source.rawValue) me=\(s.meFile != nil) type=\(s.type.rawValue) difficulty=\(s.difficulty.rawValue) length=\(s.lengthMin) cv=\(s.cv != nil) note=\(!s.note.isEmpty) vault=\(s.useVault) repos=\(s.repos.count) fake=\(s.fake)")
        Task { @MainActor in
            let outcome = await p.run(s, brainDir: brainDir, root: sessionsRoot, onLine: { [weak self] l in
                FileLog.shared.write("[sim prep] " + l)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.prepLines.append(l) } }
            })
            prep = nil
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
    }

    public func cancelPrep() { prep?.cancel() }

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
