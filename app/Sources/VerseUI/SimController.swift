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

    public init(settings: AppSettings, simSettings: SimSettings, meeting: VerseController) {
        self.settings = settings
        self.simSettings = simSettings
        self.meeting = meeting
        setup.voice = simSettings.voiceKind
        lastReport = SimSessionFolder.reports().first
    }

    public var running: Bool { phase == .running }
    public var fake: Bool { meeting.fakeBrain }

    private func log(_ s: String) { FileLog.shared.write("sim: " + s) }

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
        guard let p = posting else { return nil }
        let company = setup.company.isEmpty ? (p.company ?? "company") : setup.company
        return SimSessionFolder.name(company: company)
    }

    // MARK: prep

    public var canPrepare: Bool { postingConfirmed && phase != .preparing && phase != .running && !meeting.running }

    public func prepare() {
        guard canPrepare, let brainDir = VerseController.brainDir() else {
            if VerseController.brainDir() == nil { prepError = "The brain folder was not found (set VERSE_BRAIN_DIR)." }
            return
        }
        var s = setup
        s.fake = fake
        let p = SimPrep()
        prep = p
        phase = .preparing
        prepLines = []
        prepError = nil
        summary = nil
        sessionDir = nil
        prepStartedAt = Date()
        log("prep start type=\(s.type.rawValue) difficulty=\(s.difficulty.rawValue) length=\(s.lengthMin) cv=\(s.cv != nil) note=\(!s.note.isEmpty) vault=\(s.useVault) repos=\(s.repos.count) fake=\(s.fake)")
        Task { @MainActor in
            let outcome = await p.run(s, brainDir: brainDir, onLine: { [weak self] l in
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
        let voice: any VoiceEngine
        if kind == .text {
            voice = TextVoice()
        } else {
            let primary = VoiceFactory.make(kind, voiceID: simSettings.voiceID(for: kind))
            let fallback = AppleVoice(voiceID: simSettings.voiceID(for: .apple))
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
        let r = SimRunner(transport: brain, voice: voice, mic: ListenSimMic(lang: "en"), sink: { [weak self] e in
            // One FIFO hop to the main thread keeps the runner's order.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(e) } }
        })
        runner = r
        runStartedAt = Date()
        runWasFake = fakeRun
        lineText = [:]
        phase = .running
        log("start \(dir.lastPathComponent) mode=\(setup.mode.rawValue) voice=\(kind.rawValue) hints=\(setup.hints) fake=\(fakeRun)")
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
        runner = nil
        phase = .finished
        overlay.simActions = nil
        hotKey.unregister()
        let h = hints
        hints = nil
        Task { await h?.stop() }
        recordSpend()
        meeting.hideOverlayPanel()
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
