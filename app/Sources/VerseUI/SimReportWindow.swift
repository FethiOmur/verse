import AppKit
import SwiftUI
import WebKit

/// The practice report: S5's `report.html` from the session folder in a `WKWebView`. The page is self-contained
/// (inline CSS, no script), so JavaScript is off and the view may read only that folder. It no longer has a window of its
/// own: the report shows on the home window's Sessions page, and `show` takes you there.
@MainActor
public enum SimReportWindow {
    /// Opens Sessions on the practice run that wrote `url`.
    public static func show(report url: URL) {
        HomeRouter.shared.showReport(url)
    }

    /// The report windows are gone with the home window; kept so Quit code stays as it was.
    public static func closeAll() {}
}

/// The report page inside the Sessions detail.
struct HomeReportView: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        context.coordinator.loaded = url
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        guard context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var loaded: URL? }
}
