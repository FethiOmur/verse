import AppKit
import Combine
import Foundation
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

    public init(arguments: [String] = CommandLine.arguments) {
        var it = arguments.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--fake-brain": fakeBrain = true
            case "--file": file = it.next()
            case "--session": session = it.next()
            case "--autostart": autostart = true
            case "--render-screens": renderScreensDir = it.next()
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
    @Published public private(set) var stopping = false
    @Published public private(set) var sessions: [String] = []
    @Published public private(set) var sessionSpend = 0.0
    @Published public private(set) var monthSpend = 0.0
    @Published public private(set) var lastExitCode: Int32?

    public let settings: AppSettings
    public let overlay: OverlayModel
    public let launch: LaunchOptions
    private var panel: NotchPanelController?
    private var runner: VerseRunner?
    private var runTask: Task<Void, Never>?
    private var runStartedAt = Date()
    private var runSessionDir: URL?
    private var runWasFake = false
    private var cancellables: Set<AnyCancellable> = []

    public init(settings: AppSettings, launch: LaunchOptions = LaunchOptions()) {
        self.settings = settings
        self.launch = launch
        overlay = OverlayModel(config: settings.overlayConfig)
        if let s = launch.session { settings.sessionName = s }
        refreshSessions()
        monthSpend = SpendLedger.thisMonth()
        settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.overlay.config = self?.settings.overlayConfig ?? OverlayConfig() } }
        }.store(in: &cancellables)
    }

    public var fakeBrain: Bool { launch.fakeBrain || settings.fakeBrain }
    public var testFile: String? {
        if let f = launch.file, !f.isEmpty { return f }
        let p = settings.testAudioPath.trimmingCharacters(in: .whitespaces)
        return p.isEmpty ? nil : p
    }

    public func refreshSessions() {
        sessions = SessionCatalog.list()
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

    public func start() {
        guard !running, !stopping else { return }
        refreshSessions()
        guard !settings.sessionName.isEmpty else { return }
        let dir = SessionCatalog.url(settings.sessionName)
        var o = RunOptions(sessionDir: dir)
        o.lang = settings.language
        o.turn = settings.turnConfig
        o.fakeBrain = fakeBrain
        o.budgetUSD = settings.budgetUSD
        o.brainDir = Self.brainDir()
        if let f = testFile { o.file = URL(fileURLWithPath: (f as NSString).expandingTildeInPath) }
        o.transcriptURL = dir.appendingPathComponent("transcript.jsonl")
        o.sink = { [weak self] e in
            // One FIFO hop to the main thread keeps the runner's order.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(e) } }
        }
        let r = VerseRunner(options: o, log: { line in
            // Brain and runner logs go to the unified log under the app's name; they never contain the key.
            NSLog("Verse: %@", line)
        })
        overlay.bank = BankOpener.load(sessionDir: dir)
        overlay.config = settings.overlayConfig
        overlay.sessionStarting(lang: settings.language)
        overlay.startClock()
        runner = r
        runSessionDir = dir
        runWasFake = fakeBrain
        runStartedAt = Date()
        sessionSpend = 0
        running = true
        lastExitCode = nil
        showPanel()
        runTask = Task.detached { [weak self] in
            let code = await r.run()
            await self?.runEnded(code)
        }
    }

    /// Stops listening; the runner shuts the brain down. Returns when the run is over.
    public func stop() async {
        guard running, let r = runner else { return }
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
        panel?.close()
        panel = nil
    }

    private func runEnded(_ code: Int32) {
        running = false
        stopping = false
        lastExitCode = code
        runner = nil
        runTask = nil
        overlay.stopClock()
        persistSpend()
        monthSpend = SpendLedger.thisMonth()
        // Keep the overlay up only for a message that needs reading (permission, credit, error).
        if overlay.state.status?.needsPanel != true { panel?.hide() }
    }

    private func handle(_ e: RunnerEvent) {
        overlay.apply(e)
        if case .brain(let o) = e, o.type == "metric", let c = o[double: "cost_usd"], c > 0 {
            sessionSpend += c
            persistSpend()
        }
        if case .ended = e, overlay.state.status?.needsPanel != true { panel?.hide() }
    }

    private func persistSpend() {
        // The fake brain reports made-up costs; they never reach the ledger.
        guard let dir = runSessionDir, sessionSpend > 0, !runWasFake else { return }
        SpendLedger.record(sessionDir: dir, startedAt: runStartedAt, costUSD: sessionSpend)
    }

    private func showPanel() {
        if panel == nil {
            panel = NotchPanelController(model: overlay, settings: settings, onOpenSettings: { kind in
                SystemSettingsLink.open(permission: kind)
            })
        }
        panel?.show()
    }

    /// The overlay message's Dismiss: hide the panel when nothing is running.
    public func overlayDismissed() {
        if !running { panel?.hide() }
    }

    public var overlayWindowNumber: Int? { panel?.windowNumber }
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
