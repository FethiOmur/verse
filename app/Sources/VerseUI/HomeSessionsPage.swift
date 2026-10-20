import AppKit
import SwiftUI
import VerseTurns

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

    @StateObject private var ask: AskSession
    @StateObject private var jump = TranscriptJump()
    @State private var askOpen = false
    /// The selected session's transcript, read once here: Ask's rows and the stamps its chips jump to come from this one document.
    @State private var document: TranscriptDocument?
    @State private var documentSession: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.askRender) private var askRender

    init(model: HomeSessionsModel, router: HomeRouter, controller: VerseController, settings: AppSettings) {
        self.model = model
        self.router = router
        self.controller = controller
        self.settings = settings
        let fake = { controller.fakeBrain }
        _ask = StateObject(wrappedValue: AskSession(model: settings.askModel, makeBrain: { try AskSession.makeBrainProcess(fake: fake()) }))
    }

    private var selected: HomeSession? { model.session(named: router.selectedSession) ?? model.sessions.first }

    private var availability: AskAvailability {
        guard let s = selected else { return .hidden }
        return AskAvailability.of(s, recordingSession: controller.recordingSessionName, rows: documentSession == s.name ? document?.rows.count : nil)
    }

    /// The list column's width with its 18 pt left margin; it animates to 0 while the panel is open.
    private static let listWidth: CGFloat = 254

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            HomeSessionsList(model: model, router: router, selectedName: selected?.name)
                .frame(width: askOpen ? 0 : Self.listWidth, alignment: .leading).clipped()
                .opacity(askOpen ? 0 : 1)
                .accessibilityHidden(askOpen)
                // Reduce Motion: the columns change place at once; only the panel fades.
                .transaction(value: askOpen) { if reduceMotion { $0.animation = nil } }
            if let s = selected {
                HomeSessionDetailView(session: s, controller: controller, settings: settings, jump: jump,
                                      askAvailability: availability, askOpen: askOpen, onAsk: toggleAsk)
                    .id(s.name)
                    .transaction(value: askOpen) { if reduceMotion { $0.animation = nil } }
                if askOpen {
                    // The panel enters from the trailing edge and leaves the same way; Reduce Motion crossfades it.
                    HStack(alignment: .top, spacing: 0) {
                        Rectangle().fill(ink.separator).frame(width: 1).padding(.vertical, 16)
                        AskPanel(session: ask, settings: settings, stamps: Set(document?.rows.map(\.stamp) ?? []), lines: citedLines,
                                 onCitation: { Self.reveal($0, in: document, jump: jump) }, onClose: closeAsk)
                    }
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            } else {
                Spacer()
            }
        }
        .onAppear { model.reload() }
        .task(id: selected?.name) { await loadDocument() }
        .onChange(of: selected?.name) { _, _ in closeAsk() }
        .onChange(of: availability) { _, a in if !a.isAvailable, askOpen, askRender == nil { closeAsk() } }
        .onDisappear { ask.close() }
        .background(WindowCloseObserver { ask.close(); askOpen = false })
        .background {
            // ⌘⇧A opens and closes the panel.
            Button("") { toggleAsk() }.keyboardShortcut("a", modifiers: [.command, .shift])
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .accessibilityIdentifier("verse.home.sessions")
    }

    @Environment(\.homeInk) private var ink

    // MARK: Ask

    private func toggleAsk() {
        if askOpen { closeAsk() } else { openAsk() }
    }

    private func openAsk() {
        guard availability.isAvailable || askRender != nil, let s = selected, let document else { return }
        ask.launchesBrain = askRender == nil
        ask.model = settings.askModel
        ask.open(AskContext(sessionDir: s.dir, ownerName: settings.ownerName, title: s.title, date: s.date,
                            meCore: Self.meCore(enabled: settings.useMeProfile), rows: document.askRows.map { AskRow(stamp: $0.stamp, speaker: $0.speaker, text: $0.text) }))
        if let askRender { ask.applyRender(askRender) }
        setOpen(true)
    }

    private func closeAsk() {
        ask.close()
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
        // A render opens the panel by itself once the transcript is read.
        if askRender?.open == true, !askOpen { openAsk() }
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

/// The window's text is English whatever the system region; dates follow it.
enum HomeFormat {
    static let locale = Locale(identifier: "en_GB")
    static var time: Date.FormatStyle { Date.FormatStyle().locale(locale).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits) }
    static var dayMonth: Date.FormatStyle { Date.FormatStyle().locale(locale).weekday(.abbreviated).day().month(.abbreviated) }

    /// "Today", "Yesterday", "Tue 14 Oct".
    static func day(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(dayMonth)
    }
}
