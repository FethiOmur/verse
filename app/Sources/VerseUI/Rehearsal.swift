import AppKit
import Combine
import SwiftUI
import VerseTurns

// "Rehearse a line…": type what the other side (or he) might say in tomorrow's call and see, live in the island, what Verse
// shows for it. The line runs through the real session pipeline (VerseTurns/Rehearsal.swift) on a temporary copy of the prepared
// session folder; no microphone or system audio is captured, and the prepared folder's transcript, events and summary are never
// written. Two ways in: the menu's panel, and the `verse-rehearse://` URL scheme for scripts (app/scripts/rehearse.sh).

/// The rehearsal running in the controller: which prepared session, where its temporary copy is, and the feed its lines go to.
public struct RehearsalRun: Sendable {
    public var session: String
    /// The prepared folder. Read only, except its `spend.json`, which records the rehearsal's real spend as its own kind.
    public var original: URL
    /// The temporary copy the run reads and writes (`RehearsalWorkspace`), removed when the rehearsal ends.
    public var workspace: URL
    public var feed: RehearsalFeed

    /// `SpendLedger` kind of a rehearsal's spend: counted in the month, never shown as a call run.
    public static let spendKind = "rehearsal"
}

/// Why a rehearsal request was not carried out. Every refusal is shown (the panel's message line); none touches a real call.
public enum RehearsalRefusal: Equatable, Sendable {
    case callRunning
    case practiceRunning
    case otherRehearsal(String)
    case noSuchSession(String)
    case notStarted
    case emptyLine
    case copyFailed(String)

    public var message: String {
        switch self {
        case .callRunning: return L10n.tr("A call is running. Rehearsing waits until it has ended.")
        case .practiceRunning: return L10n.tr("The practice interview is running. End it to rehearse.")
        case .otherRehearsal(let s): return L10n.tr("A rehearsal of \(s) is running. End it first.")
        case .noSuchSession(let s): return L10n.tr("No prepared session is called \(s).")
        case .notStarted: return L10n.tr("No rehearsal is running. Pick a session and send a line.")
        case .emptyLine: return L10n.tr("Type a line first.")
        case .copyFailed(let d): return L10n.tr("Could not copy the session folder: \(d)")
        }
    }
}

/// What a script asks for through the URL scheme:
///
///     verse-rehearse://start?session=<name>
///     verse-rehearse://say?speaker=them|me&text=<line>[&session=<name>]   (starts the rehearsal first when none runs)
///     verse-rehearse://end
///     verse-rehearse://open                                               (shows the panel)
///
/// Query values are percent-encoded (`app/scripts/rehearse.sh` does that).
public enum RehearsalCommand: Equatable, Sendable {
    case open
    case start(session: String)
    case say(speaker: RehearsalSpeaker, text: String, session: String?)
    case end

    public static let scheme = "verse-rehearse"

    /// The command a URL carries, or nil for a URL that is not one (wrong scheme, unknown action, missing or empty values).
    public static func parse(_ url: URL) -> RehearsalCommand? {
        guard url.scheme?.lowercased() == scheme, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // `verse-rehearse://say?...` puts the action in the host; `verse-rehearse:say?...` in the path.
        let action = (parts.host?.isEmpty == false ? parts.host! : parts.path).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        func value(_ name: String) -> String? {
            guard let v = parts.queryItems?.last(where: { $0.name.lowercased() == name })?.value else { return nil }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        switch action {
        case "open", "": return .open
        case "start":
            guard let s = value("session") else { return nil }
            return .start(session: s)
        case "say":
            guard let raw = value("speaker"), let speaker = speaker(raw), let text = value("text") else { return nil }
            let line = RehearsalFeed.clean(text)
            guard !line.isEmpty else { return nil }
            return .say(speaker: speaker, text: line, session: value("session"))
        case "end", "stop": return .end
        default: return nil
        }
    }

    static func speaker(_ raw: String) -> RehearsalSpeaker? {
        switch raw.lowercased() {
        case "them", "remote", "other": return .them
        case "me", "self": return .me
        default: return nil
        }
    }
}

/// The rehearsal's front end: the panel's state and the commands of both entry points, carried out on the controller.
@MainActor
public final class RehearsalDesk: ObservableObject {
    @Published public var session: String
    @Published public var speaker: RehearsalSpeaker = .them
    @Published public var text = ""
    /// The line under the field: a refusal, or nil.
    @Published public private(set) var message: String?

    public let controller: VerseController
    /// Tests: false keeps refusals off the screen (the message is still set).
    var presentsPanel = true
    private var panel: NSPanel?
    private var panelDelegate: PanelDelegate?
    private var subs: Set<AnyCancellable> = []

    public init(controller: VerseController) {
        self.controller = controller
        session = controller.settings.sessionName
        // The panel follows the controller (a rehearsal that ended by ⌥⌘V or an error frees the session picker).
        controller.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.objectWillChange.send() } }
        }.store(in: &subs)
    }

    /// Whether a rehearsal runs now.
    public var rehearsing: Bool { controller.rehearsal != nil }

    /// A URL from the scheme: carried out when it is a rehearsal command. False: not one of ours.
    @discardableResult
    public func handle(url: URL) -> Bool {
        guard url.scheme?.lowercased() == RehearsalCommand.scheme else { return false }
        guard let cmd = RehearsalCommand.parse(url) else {
            controller.log("rehearsal: unreadable command \(url.host ?? url.path)")
            return true
        }
        Task { @MainActor in _ = await self.perform(cmd) }
        return true
    }

    /// Carries out a command. A refusal is shown on the panel (opened without taking the keyboard) and returned.
    @discardableResult
    public func perform(_ cmd: RehearsalCommand) async -> RehearsalRefusal? {
        let refusal: RehearsalRefusal?
        switch cmd {
        case .open:
            if presentsPanel { showPanel() }
            refusal = nil
        case .start(let s):
            refusal = controller.startRehearsal(session: s)
            if refusal == nil { session = s; message = nil }
        case .say(let sp, let line, let s):
            refusal = startIfNeeded(s) ?? controller.rehearse(sp, line)
        case .end:
            await controller.endRehearsal()
            refusal = nil
        }
        if let refusal { show(refusal) }
        return refusal
    }

    /// The panel's Return: starts the picked session's rehearsal when none runs, then says the line. The field empties when it
    /// was sent; the panel stays for the next line.
    public func send() {
        let line = RehearsalFeed.clean(text)
        guard !line.isEmpty else { message = RehearsalRefusal.emptyLine.message; return }
        if let refusal = startIfNeeded(session) ?? controller.rehearse(speaker, line) {
            message = refusal.message
            return
        }
        message = nil
        text = ""
    }

    /// The panel's "End rehearsal".
    public func end() {
        Task { @MainActor in await controller.endRehearsal() }
    }

    private func startIfNeeded(_ s: String?) -> RehearsalRefusal? {
        if let running = controller.rehearsal {
            guard let s, s != running.session else { return nil }
            return .otherRehearsal(running.session)
        }
        guard let s, !s.isEmpty else { return .notStarted }
        let refusal = controller.startRehearsal(session: s)
        if refusal == nil { session = s }
        return refusal
    }

    private func show(_ refusal: RehearsalRefusal) {
        controller.log("rehearsal refused: \(refusal)")
        message = refusal.message
        if presentsPanel { showPanel(activate: false) }
    }

    // MARK: panel

    /// Shows the panel. `activate`: take the keyboard (the menu item); a script's refusal shows it without.
    public func showPanel(activate: Bool = true) {
        if session.isEmpty || !controller.sessions.contains(session) { session = controller.rehearsal?.session ?? controller.settings.sessionName }
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 210),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            p.title = L10n.tr("Rehearse a line")
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: RehearsalPanelView(desk: self))
            let d = PanelDelegate { [weak self] in self?.panelClosed() }
            p.delegate = d
            panelDelegate = d
            p.center()
            panel = p
        }
        if activate {
            NSApp.activate()
            panel?.makeKeyAndOrderFront(nil)
        } else {
            panel?.orderFrontRegardless()
        }
    }

    /// Closing the panel ends the rehearsal.
    private func panelClosed() {
        message = nil
        end()
    }

    private final class PanelDelegate: NSObject, NSWindowDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        func windowWillClose(_ notification: Notification) { onClose() }
    }
}

/// The panel: session, who speaks, the line. Return sends.
struct RehearsalPanelView: View {
    @ObservedObject var desk: RehearsalDesk
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var fieldFocused: Bool

    private var ink: VT.Window {
        VT.Window(dark: scheme == .dark, increaseContrast: contrast == .increased, reduceTransparency: reduceTransparency)
    }

    var body: some View {
        let ink = ink
        let controller = desk.controller
        let picker = controller.pickerModel()
        VStack(alignment: .leading, spacing: 0) {
            HomeGroup {
                HomeRow("Session") {
                    HomePopup(selection: $desk.session, sections: Self.sections(picker),
                              current: picker.label(of: desk.session), fallback: "No session prepared")
                    .disabled(desk.rehearsing)
                }
                HomeRowDivider()
                HomeRow("Who says it") {
                    HomeSegmented([(label: "Them", value: RehearsalSpeaker.them), (label: "Me", value: RehearsalSpeaker.me)],
                                  selection: $desk.speaker)
                }
                HomeRowDivider()
                TextField("", text: $desk.text, prompt: prompt.foregroundStyle(ink.tertiary))
                    .textFieldStyle(.plain).font(VT.Font.body).foregroundStyle(ink.primary)
                    .focused($fieldFocused)
                    .onSubmit { desk.send() }
                    .padding(.horizontal, 14).frame(minHeight: 40)
            }
            HStack(alignment: .firstTextBaseline, spacing: VT.Space.s) {
                status.font(VT.Font.callout).foregroundStyle(desk.message == nil ? ink.tertiary : ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: VT.Space.s)
                if desk.rehearsing {
                    HomeSecondaryButton("End rehearsal") { desk.end() }
                        .disabled(controller.stopping)
                }
            }
            .padding(.leading, 4).padding(.top, VT.Space.s)
        }
        .padding(.horizontal, VT.Space.l).padding(.top, 36).padding(.bottom, VT.Space.l)
        .frame(width: 440)
        .background(ink.background)
        .environment(\.homeInk, ink)
        .tint(VT.mint)
        .interfaceLocale()
        .onAppear { fieldFocused = true }
    }

    /// The prepared sessions as the menu's Session submenu groups them: next meetings first, then the others.
    static func sections(_ picker: SessionPickerModel) -> [HomeOptionSection<String>] {
        let others = picker.others.map { HomeOption(verbatim: $0.label, $0.session) }
        guard !picker.nextMeetings.isEmpty else { return [HomeOptionSection(nil, id: 1, options: others)] }
        let next = HomeOptionSection("Next meetings", id: 0, options: picker.nextMeetings.map { HomeOption(verbatim: $0.label, $0.session) })
        return others.isEmpty ? [next] : [next, HomeOptionSection("Other sessions", id: 1, options: others)]
    }

    private var prompt: Text {
        desk.speaker == .them ? Text("What they say, then Return", bundle: .module) : Text("What you say, then Return", bundle: .module)
    }

    private var status: Text {
        if let m = desk.message { return Text(verbatim: m) }
        if desk.controller.stopping, desk.rehearsing { return Text("Ending the rehearsal…", bundle: .module) }
        if let r = desk.controller.rehearsal {
            return Text("Rehearsing \(desk.controller.pickerModel().label(of: r.session) ?? r.session). No audio, nothing saved to the session.", bundle: .module)
        }
        return Text("Lines run through the real session on a copy of its folder. Closing this window ends the rehearsal.", bundle: .module)
    }
}
