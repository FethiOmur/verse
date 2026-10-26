import AppKit
import SwiftUI
import VerseAudio

/// The home window's pages (UI redesign spec 4.2).
public enum HomePage: String, CaseIterable, Identifiable, Sendable {
    case prepare, me, sessions, people, practice, scripts, settings

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .prepare: L10n.tr("Prepare")
        case .me: L10n.tr("Me")
        case .sessions: L10n.tr("Sessions")
        case .people: L10n.tr("People")
        case .practice: L10n.tr("Practice")
        case .scripts: L10n.tr("Scripts")
        case .settings: L10n.tr("Settings")
        }
    }
    var symbol: String {
        switch self {
        case .prepare: "checklist"
        case .me: "person.text.rectangle"
        case .sessions: "clock.arrow.circlepath"
        case .people: "person.2"
        case .practice: "person.wave.2"
        case .scripts: "text.alignleft"
        case .settings: "gearshape"
        }
    }
}

/// What the Ask panel is about (memory spec 2.3): one session, one person or company, or every indexed session.
public enum AskScope: Hashable, Sendable {
    case session(String), entity(String), all
}

/// Where a session opens when something cites it (memory spec 5.2): at the top, on its Summary, or at a transcript line.
public enum SessionReveal: Equatable, Sendable {
    case none, summary, stamp(String)
}

/// One request to open a session at a place. `serial` grows with every request, so asking for the same place twice is two requests.
public struct SessionRevealRequest: Equatable, Sendable {
    public var session: String
    public var reveal: SessionReveal
    public var serial: Int

    public init(session: String, reveal: SessionReveal, serial: Int) {
        self.session = session
        self.reveal = reveal
        self.serial = serial
    }
}

/// Which page the home window shows, and the way to open the window from anywhere (menu items, the practice report).
/// There is one home window (`Window("Verse", id: "home")`); `show` selects the page and opens or raises it.
@MainActor
public final class HomeRouter: ObservableObject {
    public static let shared = HomeRouter()
    public nonisolated static let windowID = "home"
    static let windowIdentifier = NSUserInterfaceItemIdentifier("\(AppIdentity.bundleID).home")

    @Published public var page: HomePage = .prepare
    /// The session folder name the Sessions page has selected.
    @Published public var selectedSession: String?
    /// A prepared session Up next asked Practice to select ("Practise"); the Practice page takes it and clears it.
    @Published public var practiceSession: String?
    /// The person or company the People page has selected (an entity id; it may be an old id that `merged` redirects).
    @Published public var selectedEntity: String?
    /// "Ask about <name>" and the other memory entry points ask the Sessions page to open its panel in a scope; the page takes the
    /// request and clears it.
    @Published public var askRequest: AskScope?
    /// The last request to open a session at a line, its Summary or its top (a citation click, a timeline row).
    @Published public private(set) var revealRequest: SessionRevealRequest?
    private var revealSerial = 0

    private var openAction: (@MainActor (String) -> Void)?

    public init() {}

    /// The scene's `openWindow`, captured by a view that is always alive (the menu-bar label).
    public func register(openWindow: OpenWindowAction) {
        openAction = { id in openWindow(id: id) }
    }

    /// Selects `page` and opens or raises the home window.
    public func show(_ page: HomePage) {
        self.page = page
        raise()
    }

    /// Opens Practice with `session` chosen as "A meeting" (the page selects it when it appears). From inside the home
    /// window, like the other Up next buttons: it changes the page and does not raise the window.
    public func showPractice(session: String) {
        practiceSession = session
        page = .practice
    }

    /// Opens Sessions with the Ask panel asked to open in `scope`.
    public func showAsk(_ scope: AskScope) {
        askRequest = scope
        page = .sessions
    }

    /// Opens Sessions on `name` and asks it to open at `reveal`.
    public func showSession(_ name: String, reveal: SessionReveal) {
        selectedSession = name
        revealSerial += 1
        revealRequest = SessionRevealRequest(session: name, reveal: reveal, serial: revealSerial)
        page = .sessions
    }

    /// Opens People on the person or company `id`.
    public func showEntity(_ id: String) {
        selectedEntity = id
        page = .people
    }

    /// Opens Sessions on the practice run whose `report.html` is `url`.
    public func showReport(_ url: URL) {
        selectedSession = url.deletingLastPathComponent().lastPathComponent
        show(.sessions)
    }

    /// Menu items call this with the environment's action, so the window opens even before the label registered.
    public func show(_ page: HomePage, openWindow: OpenWindowAction) {
        register(openWindow: openWindow)
        show(page)
    }

    /// Testing: `VERSE_HOME_NOACTIVATE=1` shows the window without taking the keyboard focus.
    private static let noActivate = ProcessInfo.processInfo.environment["VERSE_HOME_NOACTIVATE"] != nil

    /// The home window; before its content has laid out (and set the identifier) it is found by its title.
    private static func homeWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier == windowIdentifier } ?? NSApp.windows.first { $0.title == "Verse" && $0.contentView != nil }
    }

    private func raise() {
        if !Self.noActivate { NSApp.activate() }
        if let w = Self.homeWindow() {
            if w.isMiniaturized { w.deminiaturize(nil) }
            if Self.noActivate { w.orderFrontRegardless() } else { w.makeKeyAndOrderFront(nil) }
        } else {
            openAction?(Self.windowID)
            if Self.noActivate {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated {
                        Self.homeWindow()?.orderFrontRegardless()
                    }
                }
            }
        }
    }
}
