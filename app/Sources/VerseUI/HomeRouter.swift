import AppKit
import SwiftUI

/// The home window's pages (UI redesign spec 4.2).
public enum HomePage: String, CaseIterable, Identifiable, Sendable {
    case prepare, sessions, practice, scripts, settings

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .prepare: "checklist"
        case .sessions: "clock.arrow.circlepath"
        case .practice: "person.wave.2"
        case .scripts: "text.alignleft"
        case .settings: "gearshape"
        }
    }
}

/// Which page the home window shows, and the way to open the window from anywhere (menu items, the practice report).
/// There is one home window (`Window("Verse", id: "home")`); `show` selects the page and opens or raises it.
@MainActor
public final class HomeRouter: ObservableObject {
    public static let shared = HomeRouter()
    public nonisolated static let windowID = "home"
    static let windowIdentifier = NSUserInterfaceItemIdentifier("dev.fethiverse.verse.home")

    @Published public var page: HomePage = .prepare
    /// The session folder name the Sessions page has selected.
    @Published public var selectedSession: String?

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
