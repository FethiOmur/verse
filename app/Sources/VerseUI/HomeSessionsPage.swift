import AppKit
import Combine
import SwiftUI
import VerseTurns

// MARK: - Ask scopes

/// `askMemoryScope` (memory spec 3.8): the memory scope used last from the Sessions page, `all` or an entity id.
@MainActor
struct AskMemoryScopeStore {
    var defaults = Bundle.main.bundleIdentifier == AppSettings.suiteName ? UserDefaults.standard
        : UserDefaults(suiteName: AppSettings.suiteName) ?? .standard
    static let key = "askMemoryScope"

    var scope: AskScope {
        get {
            guard let raw = defaults.string(forKey: Self.key), raw != "all", !raw.isEmpty else { return .all }
            return .entity(raw)
        }
        nonmutating set {
            switch newValue {
            case .all: defaults.set("all", forKey: Self.key)
            case .entity(let id): defaults.set(id, forKey: Self.key)
            case .session: break
            }
        }
    }
}

/// The Sessions page's Ask logic apart from its views: which scope the panel is in, the context each scope starts its process with,
/// the sync of the index before a memory scope opens, and the choices of the Scope menu (memory spec 2.3, 5.2).
@MainActor
final class AskScopeController: ObservableObject {
    let ask: AskSession
    /// The scope the open panel is in; nil while it is closed.
    @Published private(set) var scope: AskScope?
    /// The index's sync phase (the "Updating memory · 3 of 12" caption); idle without a memory service.
    @Published private(set) var phase: MemoryService.Phase = .idle

    var memory: MemoryService?
    var people: EntityStore?
    var ownerName: () -> String = { "" }
    var useMeProfile: () -> Bool = { false }
    var meCore: () -> URL? = { nil }
    var askModel: () -> AskModel = { .sonnet }
    var sessions: () -> [HomeSession] = { [] }
    var folders: () -> FoldersFile = { FoldersFile() }
    var store = AskMemoryScopeStore()
    /// How long opening a memory scope waits for the index to catch up (memory spec 2.1: questions are allowed meanwhile).
    var syncTimeout: Duration = .seconds(5)

    private var openToken = 0
    private var phaseWatch: AnyCancellable?

    init(ask: AskSession, memory: MemoryService? = nil, people: EntityStore? = nil) {
        self.ask = ask
        self.memory = memory
        self.people = people
        watchPhase()
    }

    func attach(memory: MemoryService?, people: EntityStore?) {
        guard self.memory !== memory else { self.people = people; return }
        self.memory = memory
        self.people = people
        watchPhase()
    }

    private func watchPhase() {
        phaseWatch = memory?.$phase.sink { [weak self] p in MainActor.assumeIsolated { self?.phase = p } }
        phase = memory?.phase ?? .idle
    }

    // MARK: open, change, close

    /// Opens Ask this meeting on `ctx`.
    func open(session ctx: AskContext) {
        openToken += 1
        ask.model = askModel()
        ask.open(ctx)
        scope = .session(ctx.sessionDir.lastPathComponent)
    }

    /// Opens a memory scope: the history shows at once, the index syncs (waiting at most `syncTimeout`), then the process starts.
    /// False when the scope has no context (an entity that is gone, no memory service).
    @discardableResult
    func openMemory(_ target: AskScope) -> Bool {
        guard let ctx = memoryContext(for: target) else { return false }
        openToken += 1
        let token = openToken
        ask.model = askModel()
        ask.open(ctx, launch: false)
        scope = target
        store.scope = target
        guard let memory else { ask.launchIfOpen(); return true }
        Task { @MainActor [weak self] in
            _ = await memory.syncNow(timeout: self?.syncTimeout ?? .seconds(5))
            guard let self, self.openToken == token, self.scope == target else { return }
            self.ask.launchIfOpen()
        }
        return true
    }

    /// Ends the process and opens `target`: its history, and for a memory scope a new process with the new first line.
    func change(to target: AskScope, sessionContext: AskContext?) {
        switch target {
        case .session:
            guard let sessionContext else { return }
            open(session: sessionContext)
        default:
            openMemory(target)
        }
    }

    /// Another session selected: Ask this meeting closes (the 5F rule); the memory scopes stay open (memory spec 5.2).
    var closesOnSelectionChange: Bool { if case .session? = scope { true } else { false } }

    func close() {
        openToken += 1
        ask.close()
        scope = nil
    }

    // MARK: contexts

    func memoryContext(for target: AskScope) -> MemoryAskContext? {
        guard let memory else { return nil }
        let me = useMeProfile() ? meCore() : nil
        switch target {
        case .session:
            return nil
        case .all:
            return MemoryAskContext(scope: .all, scopeName: "", ownerName: ownerName(), db: memory.paths.db, chat: memory.paths.chat(named: "all"),
                                    spendDir: memory.paths.spendDir, meCore: me)
        case .entity(let id):
            guard let people, let e = people.resolve(id: id) else { return nil }
            let names = EntityResolver.sessions(of: e.id, file: people.file, folders: folders(), sessions: sessions()).map(\.name)
            return MemoryAskContext(scope: .entity(e.id), scopeName: e.name, ownerName: ownerName(), db: memory.paths.db,
                                    chat: memory.paths.chat(named: e.id), spendDir: memory.paths.spendDir, meCore: me, sessions: names)
        }
    }

    // MARK: what the panel shows

    /// This meeting (when the selected session offers Ask), the selected session's people and companies, All meetings.
    func choices(selected: HomeSession?, availability: AskAvailability) -> [AskPanelScope.Choice] {
        var out: [AskPanelScope.Choice] = []
        if let selected, availability.isAvailable { out.append(.init(scope: .session(selected.name), title: L10n.tr("This meeting"))) }
        var entities = selected.map { people?.entities(of: $0.name, folders: folders()) ?? [] } ?? []
        // The scope the panel is in is always in the menu, so its checkmark has an item.
        if case .entity(let id)? = scope, let current = people?.resolve(id: id), !entities.contains(where: { $0.id == current.id }) {
            entities.insert(current, at: 0)
        }
        for e in entities { out.append(.init(scope: .entity(e.id), title: e.name)) }
        out.append(.init(scope: .all, title: L10n.tr("All meetings")))
        return out
    }

    /// The meetings of a scope that were held: none means the empty state (memory spec 2.3).
    func emptyText(for target: AskScope) -> String? {
        switch target {
        case .session:
            return nil
        case .all:
            return sessions().contains(where: EntityResolver.wasHeld) ? nil : L10n.tr("Verse has no past meetings to search yet.")
        case .entity(let id):
            guard let people, let e = people.resolve(id: id) else { return L10n.tr("Verse has no past meetings to search yet.") }
            let past = EntityResolver.pastSessions(of: e.id, excluding: nil, file: people.file, folders: folders(), sessions: sessions())
            return past.isEmpty ? L10n.tr("No meetings with \(e.name) are in Verse yet.") : nil
        }
    }

    func panelScope(selected: HomeSession?, availability: AskAvailability, available: Set<String>, onChange: @escaping (AskScope) -> Void,
                    onSource: @escaping (AskSource) -> Void) -> AskPanelScope? {
        guard let current = scope else { return nil }
        var p = AskPanelScope(current: current, choices: choices(selected: selected, availability: availability))
        if case .entity(let id) = current, let e = people?.resolve(id: id) {
            p.entityName = e.name
            p.shortName = e.kind == .person ? (e.name.split(separator: " ").first.map(String.init) ?? e.name) : e.name
        }
        if case .indexing(let done, let total) = phase { p.updating = (done, total) }
        p.emptyText = emptyText(for: current)
        p.available = available
        p.onChange = onChange
        p.onSource = onSource
        return p
    }

    /// Where a click on `source` opens its session.
    static func reveal(for source: AskSource) -> SessionReveal {
        switch source.kind {
        case "turn": source.stamp.map { .stamp($0) } ?? .none
        case "summary": .summary
        default: .none
        }
    }
}

/// What opening a session at a place did to its detail.
enum SessionRevealOutcome: Equatable {
    /// The transcript scrolled to the row and flashed it.
    case revealed
    /// The Summary tab was asked for.
    case summary
    /// Nothing to do: the session is selected.
    case none
    /// The transcript has no row with that stamp: the detail opens on the transcript's top and says so.
    case missing

    @MainActor
    static func perform(_ reveal: SessionReveal, document: TranscriptDocument?, jump: TranscriptJump) -> SessionRevealOutcome {
        switch reveal {
        case .none: .none
        case .summary: .summary
        case .stamp(let stamp): HomeSessionsPage.reveal(stamp, in: document, jump: jump) ? .revealed : .missing
        }
    }
}

/// Where the Sessions page asks a session's detail to be, and the note it shows when a line is gone.
struct SessionDetailPlace: Equatable {
    var tab: SessionsDetailTab
    var serial: Int
}

/// The home window's Sessions page: every session folder (meetings, practice runs, prepared packs) on the left, the
/// selected one on a reading plate: Summary, Follow up (checkable), what is still open, the questions heard, and for a
/// practice run its report. It replaces the practice report window and shows the vault summary before saving it.
/// This file is the container: list | detail | the Ask panel (spec 2.2). The list column is `HomeSessionsList.swift`, the detail
/// `HomeSessionDetailView.swift`, the panel `AskPanel.swift`.
struct HomeSessionsPage: View {
    @ObservedObject var model: HomeSessionsModel
    @ObservedObject var router: HomeRouter
    @ObservedObject var controller: VerseController
    @ObservedObject var settings: AppSettings
    var memory: MemoryService?
    var people: EntityStore?
    var briefs: AutoBriefCenter?

    @StateObject private var scopes: AskScopeController
    @StateObject private var jump = TranscriptJump()
    @State private var askOpen = false
    /// The selected session's transcript, read once here: Ask's rows and the stamps its chips jump to come from this one document.
    @State private var document: TranscriptDocument?
    @State private var documentSession: String?
    /// A citation or a timeline row asked for a place in a session; it waits here until that session's transcript is read.
    @State private var pendingReveal: SessionRevealRequest?
    @State private var handledReveal = 0
    @State private var place: SessionDetailPlace?
    @State private var revealNote: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.askRender) private var askRender
    @Environment(\.undoManager) private var undoManager
    @Environment(\.sessionsTrashRender) private var trashRender

    init(model: HomeSessionsModel, router: HomeRouter, controller: VerseController, settings: AppSettings,
         memory: MemoryService? = nil, people: EntityStore? = nil, briefs: AutoBriefCenter? = nil) {
        self.model = model
        self.router = router
        self.controller = controller
        self.settings = settings
        self.memory = memory
        self.people = people
        self.briefs = briefs
        let fake = { controller.fakeBrain }
        let ask = AskSession(model: settings.askModel, makeBrain: { try AskSession.makeBrainProcess(fake: fake()) })
        _scopes = StateObject(wrappedValue: AskScopeController(ask: ask, memory: memory, people: people))
    }

    private var ask: AskSession { scopes.ask }
    private var selected: HomeSession? { model.session(named: router.selectedSession) ?? model.sessions.first }

    private var availability: AskAvailability {
        guard let s = selected else { return .hidden }
        return AskAvailability.of(s, recordingSession: controller.recordingSessionName, rows: documentSession == s.name ? document?.rows.count : nil)
    }

    /// True while the panel is open on one meeting (today's Ask this meeting).
    private var inSessionScope: Bool { if case .session? = scopes.scope { true } else { false } }

    /// The list column's width with its 18 pt left margin; it animates to 0 while the panel is open.
    private static let listWidth: CGFloat = 254

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            HomeSessionsList(model: model, router: router, selectedName: selected?.name, onTrash: performTrash)
                .frame(width: askOpen ? 0 : Self.listWidth, alignment: .leading).clipped()
                .opacity(askOpen ? 0 : 1)
                .accessibilityHidden(askOpen)
                // Reduce Motion: the columns change place at once; only the panel fades.
                .transaction(value: askOpen) { if reduceMotion { $0.animation = nil } }
            if let s = selected {
                HomeSessionDetailView(session: s, controller: controller, settings: settings, jump: jump,
                                      askAvailability: availability, askOpen: askOpen, onAsk: askButton,
                                      onPractice: { router.showPractice(session: s.name) }, trash: trashControl(for: s),
                                      memory: memoryEnvironment, place: place, note: revealNote)
                    .id(s.name)
                    .transaction(value: askOpen) { if reduceMotion { $0.animation = nil } }
                if askOpen {
                    // The panel enters from the trailing edge and leaves the same way; Reduce Motion crossfades it.
                    HStack(alignment: .top, spacing: 0) {
                        Rectangle().fill(ink.separator).frame(width: 1).padding(.vertical, 16)
                        AskPanel(session: ask, settings: settings, stamps: Set(document?.rows.map(\.stamp) ?? []), lines: citedLines,
                                 onCitation: { Self.reveal($0, in: document, jump: jump) }, onClose: closeAsk, scope: panelScope)
                    }
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            } else {
                Spacer()
            }
        }
        .onAppear {
            model.reload()
            adoptRequests()
        }
        .task(id: selected?.name) { await loadDocument() }
        .onChange(of: selected?.name) { _, _ in
            revealNote = nil
            // Another session closes Ask this meeting; the memory scopes stay open (memory spec 5.2).
            if scopes.closesOnSelectionChange { closeAsk() }
        }
        .onChange(of: availability) { _, a in if !a.isAvailable, inSessionScope, askRender == nil { closeAsk() } }
        .onChange(of: router.askRequest) { _, _ in adoptRequests() }
        .onChange(of: router.revealRequest) { _, _ in adoptRequests() }
        .onDisappear { scopes.close() }
        .background(WindowCloseObserver { scopes.close(); askOpen = false })
        .background {
            // ⌘⇧A opens and closes the panel.
            Button("") { toggleAsk() }.keyboardShortcut("a", modifiers: [.command, .shift])
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) { toastBar }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.28), value: model.toast)
        .onChange(of: model.toast) { _, t in
            if let t { AccessibilityNotification.Announcement(t.message).post() }
        }
        .accessibilityIdentifier("verse.home.sessions")
    }

    @Environment(\.homeInk) private var ink

    // MARK: Move to Trash

    /// The single Move to Trash of the page: the swipe, the context menu, ⌫ and ⌘⌫, the detail's Trash button and its More menu
    /// all call it. No confirmation: the toast and ⌘Z undo it (`HomeSessionsModel.trash`, `restore`).
    private func performTrash(_ names: [String]) {
        let targets = model.deletable(names)
        guard !targets.isEmpty else { return }
        // The Ask panel (and its brain process) of a session ends before the session leaves.
        if let shown = selected?.name, targets.contains(shown) { closeAsk() }
        _ = withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            model.trash(targets, undoManager: undoManager)
        }
    }

    private func trashControl(for s: HomeSession) -> SessionTrashControl {
        let targets = model.trashTargets(shown: s.name)
        let enabled = !model.deletable(targets).isEmpty
        let help = model.blockReason(for: s.name)?.help ?? L10n.tr("Move to Trash")
        return SessionTrashControl(enabled: enabled, help: help, action: { performTrash(targets) })
    }

    @ViewBuilder private var toastBar: some View {
        let shown = model.toast ?? (trashRender?.toast == true ? SessionToast(message: L10n.tr("Moved to Trash"), undoable: true) : nil)
        if let shown {
            SessionToastView(toast: shown, onUndo: { model.undoFromToast() })
                .padding(.bottom, 20)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Ask

    /// What the people and brief parts of a session's detail need.
    private var memoryEnvironment: SessionMemoryEnvironment? {
        guard let memory, let people, let briefs else { return nil }
        return SessionMemoryEnvironment(memory: memory, people: people, sessions: model, router: router, briefs: briefs)
    }

    /// ⌘⇧A: closes an open panel; otherwise opens it in the scope used last (this meeting when it offers Ask, else the last memory scope).
    private func toggleAsk() {
        if askOpen { closeAsk() } else { openAsk(lastScope) }
    }

    /// The Ask button of a session's detail: this meeting. With a memory scope open it switches to this meeting.
    private func askButton() {
        guard let s = selected else { return }
        if askOpen, inSessionScope { closeAsk(); return }
        if askOpen { changeScope(.session(s.name)); return }
        openAsk(.session(s.name))
    }

    private var lastScope: AskScope {
        if availability.isAvailable, let s = selected { return .session(s.name) }
        let remembered = scopes.store.scope
        if case .entity(let id) = remembered, people?.resolve(id: id) == nil { return .all }
        return remembered
    }

    private func sessionContext(_ name: String) -> AskContext? {
        guard let s = selected, s.name == name, let document else { return nil }
        return AskContext(sessionDir: s.dir, ownerName: settings.ownerName, title: s.title, date: s.date,
                          meCore: Self.meCore(enabled: settings.useMeProfile),
                          rows: document.askRows.map { AskRow(stamp: $0.stamp, speaker: $0.speaker, text: $0.text) })
    }

    private func configureScopes() {
        scopes.attach(memory: memory, people: people)
        scopes.ownerName = { settings.ownerName }
        scopes.useMeProfile = { settings.useMeProfile }
        scopes.meCore = { Self.meCore(enabled: true) }
        scopes.askModel = { settings.askModel }
        scopes.sessions = { model.sessions }
        scopes.folders = { model.folders.file }
        ask.launchesBrain = askRender == nil
    }

    private func openAsk(_ scope: AskScope) {
        configureScopes()
        switch scope {
        case .session(let name):
            guard availability.isAvailable || askRender != nil, let ctx = sessionContext(name) else { return }
            scopes.open(session: ctx)
        default:
            // Ask about <name> selects the entity's newest session first (memory spec 5.2).
            if case .entity(let id) = scope, let people, let e = people.resolve(id: id) {
                let theirs = EntityResolver.sessions(of: e.id, file: people.file, folders: model.folders.file, sessions: model.sessions)
                if !theirs.contains(where: { $0.name == selected?.name }), let newest = theirs.first { router.selectedSession = newest.name }
            }
            guard scopes.openMemory(scope) else { return }
        }
        if let askRender { ask.applyRender(askRender) }
        setOpen(true)
    }

    private func changeScope(_ scope: AskScope) {
        configureScopes()
        scopes.change(to: scope, sessionContext: { if case .session(let n) = scope { sessionContext(n) } else { nil } }())
    }

    private func closeAsk() {
        scopes.close()
        guard askOpen else { return }
        setOpen(false)
    }

    /// The panel slides in and the list collapses on one spring (response 0.34 s opening, 0.26 s closing, damping 1.0: no overshoot, and
    /// interruptible, so a second ⌘⇧A turns it round from where it is). Reduce Motion: a 150 ms crossfade of the panel, the columns snap.
    private func setOpen(_ on: Bool) {
        if reduceMotion {
            withAnimation(AskMotion.crossfade) { askOpen = on }
        } else {
            withAnimation(on ? AskMotion.settle : .spring(response: 0.26, dampingFraction: 1)) { askOpen = on }
        }
    }

    private var panelScope: AskPanelScope? {
        scopes.panelScope(selected: selected, availability: availability, available: Set(model.sessions.map(\.name)),
                          onChange: { changeScope($0) },
                          onSource: { src in router.showSession(src.session, reveal: AskScopeController.reveal(for: src)) })
    }

    // MARK: requests from other pages

    /// Takes what other pages asked for: Ask in a scope ("Ask about Marta", the Ask all meetings button) and a session opened at a place.
    private func adoptRequests() {
        if let scope = router.askRequest {
            router.askRequest = nil
            if askOpen { closeAsk() }
            openAsk(scope)
        }
        if let r = router.revealRequest, r.serial > handledReveal, pendingReveal?.serial != r.serial {
            pendingReveal = r
            performPendingReveal()
        }
    }

    /// Opens the requested place once that session's transcript has been read (a request for a session not shown yet waits for it).
    private func performPendingReveal() {
        guard let r = pendingReveal else { return }
        guard model.session(named: r.session) != nil else {
            pendingReveal = nil
            handledReveal = r.serial
            return
        }
        guard selected?.name == r.session, documentSession == r.session else { return }
        pendingReveal = nil
        handledReveal = r.serial
        revealNote = nil
        switch SessionRevealOutcome.perform(r.reveal, document: document, jump: jump) {
        case .revealed, .none:
            break
        case .summary:
            place = SessionDetailPlace(tab: .summary, serial: (place?.serial ?? 0) + 1)
        case .missing:
            revealNote = L10n.tr("That line is no longer in this transcript.")
            place = SessionDetailPlace(tab: .transcript, serial: (place?.serial ?? 0) + 1)
        }
    }

    /// The transcript line of every stamp, for the card under a hovered citation (the first row wins when a stamp repeats).
    private var citedLines: [String: AskCitedLine] {
        var out: [String: AskCitedLine] = [:]
        for r in document?.askRows ?? [] where out[r.stamp] == nil { out[r.stamp] = AskCitedLine(speaker: r.speaker, text: r.text) }
        return out
    }

    private func loadDocument() async {
        guard let s = selected else { document = nil; documentSession = nil; return }
        let dir = s.dir, owner = settings.ownerName
        let doc = await Task.detached { TranscriptDocument.load(sessionDir: dir, ownerName: owner) }.value
        guard !Task.isCancelled else { return }
        document = doc
        documentSession = s.name
        performPendingReveal()
        // A render opens the panel by itself once the transcript is read.
        if let r = askRender, r.open, !askOpen { openAsk(r.scope.map { $0 } ?? .session(s.name)) }
    }

    /// A citation chip: shows the transcript tab and scrolls to the row stamped `stamp`. False when the transcript has no such row.
    @discardableResult
    static func reveal(_ stamp: String, in document: TranscriptDocument?, jump: TranscriptJump) -> Bool {
        guard let document else { return false }
        return jump.reveal(stamp: stamp, in: document)
    }

    /// `profile/me.md`, only when the profile toggle is on and the file exists.
    static func meCore(enabled: Bool, directory: URL = MeProfilePaths.defaultDirectory) -> URL? {
        let url = directory.appendingPathComponent("me.md")
        return enabled && FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

extension AskSession {
    /// The real brain: `python -u -m verse_brain.runtime` (`--fake` for Settings → Testing → Fake brain), logs to `verse.log`.
    static func makeBrainProcess(fake: Bool) throws -> any SimBrainTransport {
        guard let dir = VerseController.brainDir() else { throw BrainError.brainDirNotFound("set VERSE_BRAIN_DIR") }
        let b = try BrainProcess(brainDir: dir, extraArgs: fake ? ["--fake"] : [], onStderr: { FileLog.shared.write("[ask brain] " + $0) })
        try b.start()
        return b
    }
}

/// Tells the page when its window closes: the Ask process ends with it.
private struct WindowCloseObserver: NSViewRepresentable {
    var onClose: () -> Void

    func makeNSView(context: Context) -> NSView { Probe(onClose: onClose) }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.onClose = onClose }

    private final class Probe: NSView {
        var onClose: () -> Void
        private var token: NSObjectProtocol?

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            token.map(NotificationCenter.default.removeObserver)
            token = nil
            guard let window else { return }
            token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onClose() }
            }
        }
    }
}

/// Dates and times follow the interface language (`L10n.formatLocale`): English keeps 24-hour time (`en_GB`), Italian and Turkish
/// use their own. Tests pin the language through `L10nState` / `L10n.tr(locale:)`.
enum HomeFormat {
    static var locale: Locale { L10n.formatLocale }
    static var time: Date.FormatStyle { Date.FormatStyle().locale(locale).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits) }
    static var dayMonth: Date.FormatStyle { Date.FormatStyle().locale(locale).weekday(.abbreviated).day().month(.abbreviated) }

    /// "Today", "Yesterday", "Tue 14 Oct".
    static func day(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return L10n.tr("Today") }
        if cal.isDateInYesterday(d) { return L10n.tr("Yesterday") }
        return d.formatted(dayMonth)
    }
}
