import AppKit
import Combine
import Foundation
import SwiftUI
import VersePosting

/// The "New session from a conversation…" window's model: the paste box, the posting (link + Fetch, or pasted text),
/// the company URL and a note go to prep; when prep finishes the new session is selected as the current one.
@MainActor
public final class ConversationController: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case setup
        case preparing
        case done
    }

    // inputs
    @Published public var thread = ""
    @Published public var postingLink = ""
    @Published public var postingPaste = ""
    @Published public var companyURL = ""
    @Published public var note = ""
    // posting fetch
    @Published public private(set) var posting: Posting?
    @Published public private(set) var fetching = false
    @Published public private(set) var fetchMessage: String?
    // prep
    @Published public private(set) var phase = Phase.setup
    @Published public private(set) var lines: [String] = []
    @Published public private(set) var warnings: [String] = []
    @Published public private(set) var error: String?
    @Published public private(set) var startedAt: Date?
    @Published public private(set) var sessionDir: URL?
    @Published public private(set) var summary: ConversationSummary?

    private let owner: () -> String
    private let fake: () -> Bool
    private let brainDir: () -> URL?
    private let root: URL
    private let makeRunner: () -> any ConversationRunning
    private let fetcher: @Sendable (URL) async throws -> Posting
    /// Selects the new session as the current one (the menu's Session picker) and tells how it went.
    private let selectSession: @MainActor (String) -> Bool
    private let recordSpend: (URL, Date, Double) -> Void
    private var runner: (any ConversationRunning)?

    public init(
        owner: @escaping () -> String, fake: @escaping () -> Bool, brainDir: @escaping () -> URL?,
        root: URL = SessionCatalog.root,
        makeRunner: @escaping () -> any ConversationRunning = { ConversationPrep() },
        fetcher: @escaping @Sendable (URL) async throws -> Posting = { try await PostingFetcher.fetch($0) },
        selectSession: @escaping @MainActor (String) -> Bool,
        recordSpend: @escaping (URL, Date, Double) -> Void = { SpendLedger.record(sessionDir: $0, startedAt: $1, costUSD: $2) }
    ) {
        self.owner = owner
        self.fake = fake
        self.brainDir = brainDir
        self.root = root
        self.makeRunner = makeRunner
        self.fetcher = fetcher
        self.selectSession = selectSession
        self.recordSpend = recordSpend
    }

    /// The app wiring: the settings' owner name and fake switch, and the meeting controller's session list.
    public convenience init(settings: AppSettings, meeting: VerseController) {
        self.init(
            owner: { settings.ownerName }, fake: { meeting.fakeBrain }, brainDir: { VerseController.brainDir() },
            selectSession: { name in
                meeting.refreshSessions()
                // A running meeting keeps its session; the new one is picked from the menu afterwards.
                guard !meeting.running, meeting.sessions.contains(name) else { return false }
                settings.sessionName = name
                return true
            })
    }

    private func log(_ s: String) { FileLog.shared.write("conversation: " + s) }

    // MARK: posting

    public func fetchPosting() {
        let raw = postingLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw.contains("://") ? raw : "https://" + raw), url.host != nil else {
            fetchMessage = L10n.tr("That is not a link. Paste the posting text below instead.")
            return
        }
        fetching = true
        fetchMessage = nil
        let fetch = fetcher
        Task { @MainActor in
            defer { fetching = false }
            do {
                let p = try await fetch(url)
                posting = p
                postingPaste = ""
                fetchMessage = L10n.tr("Using: \(p.title.isEmpty ? url.host ?? L10n.tr("posting") : p.title) · \(p.text.count.formatted()) characters")
            } catch PostingError.network {
                fetchMessage = L10n.tr("Could not reach the page. Check the link, or paste the posting text below.")
            } catch {
                fetchMessage = L10n.tr("No job posting found on that page. Paste the posting text below instead.")
            }
        }
    }

    public func clearPosting() {
        posting = nil
        fetchMessage = nil
    }

    /// The posting prep gets: the fetched one, else the pasted text, else none.
    var postingForPrep: (text: String, url: URL?) {
        if let p = posting { return (p.text, p.url) }
        let t = postingPaste.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t, nil)
    }

    // MARK: prep

    public var canPrepare: Bool {
        phase != .preparing && !thread.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !fetching
    }

    public func prepare() {
        guard canPrepare else { return }
        guard let brain = brainDir() else {
            error = L10n.tr("The brain folder was not found (set VERSE_BRAIN_DIR).")
            return
        }
        var s = ConversationSetup(thread: thread)
        let p = postingForPrep
        s.postingText = p.text
        s.postingURL = p.url
        s.companyURL = companyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        s.note = note
        s.owner = owner()
        s.fake = fake()
        let run = makeRunner()
        runner = run
        phase = .preparing
        lines = []
        warnings = []
        error = nil
        summary = nil
        sessionDir = nil
        let t0 = Date()
        startedAt = t0
        log("prep start thread=\(s.thread.count) chars posting=\(!s.postingText.isEmpty) companyURL=\(!s.companyURL.isEmpty) note=\(!s.note.isEmpty) fake=\(s.fake)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let root = self.root
            let outcome = await run.run(s, brainDir: brain, root: root, onLine: { [weak self] l in
                FileLog.shared.write("[conversation prep] " + l)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.take(l) } }
            })
            // The line handler hops to the main queue; let the last lines land before reading the state.
            await Task.yield()
            runner = nil
            switch outcome {
            case .done(let dir):
                sessionDir = dir
                summary = ConversationSummary.load(sessionDir: dir)
                if let sm = summary { warnings = sm.warnings }
                if !s.fake, let c = summary?.costUSD, c > 0 { recordSpend(dir, t0, c) }
                let selected = selectSession(dir.lastPathComponent)
                phase = .done
                if !selected { warnings.append(L10n.tr("The session is ready: \(dir.lastPathComponent). Pick it in the menu when the meeting ends.")) }
                log("prep done \(dir.lastPathComponent) selected=\(selected)")
            case .failed(let m):
                error = m
                phase = .setup
                log("prep failed: \(m)")
            case .cancelled:
                phase = .setup
                log("prep cancelled")
            }
        }
    }

    private func take(_ l: String) {
        lines.append(l)
        if l.hasPrefix("warning: ") { warnings.append(String(l.dropFirst(9))) }
    }

    public func cancelPrep() { runner?.cancel() }

    /// Back to an empty form for the next conversation.
    public func another() {
        guard phase == .done else { return }
        thread = ""
        note = ""
        companyURL = ""
        postingPaste = ""
        postingLink = ""
        posting = nil
        fetchMessage = nil
        phase = .setup
        sessionDir = nil
        summary = nil
        lines = []
        warnings = []
    }

    public func revealSession() {
        if let d = sessionDir { NSWorkspace.shared.activateFileViewerSelecting([d]) }
    }
}
