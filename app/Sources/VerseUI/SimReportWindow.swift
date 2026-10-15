import AppKit
import WebKit

/// The practice report window: S5's `report.html` from the session folder in a `WKWebView`. The page is
/// self-contained (inline CSS, no script), so JavaScript is off and the view may read only that folder.
@MainActor
public enum SimReportWindow {
    private static var open: [NSWindow] = []

    public static func show(report url: URL) {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 880, height: 960), configuration: cfg)
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 960),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Practice report · " + url.deletingLastPathComponent().lastPathComponent
        w.isReleasedWhenClosed = false
        w.contentView = web
        w.setFrameAutosaveName("VerseSimReport")
        w.center()
        open.append(w)
        let id = ObjectIdentifier(w)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { open.removeAll { ObjectIdentifier($0) == id } }
        }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    /// Closes every report window (Quit).
    public static func closeAll() {
        for w in open { w.close() }
        open = []
    }
}
