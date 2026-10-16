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

/// The report page inside the Sessions detail, on a reading plate. The page's own stylesheet is dark with its own
/// background; a style block appended to it maps its colour variables to the window's text colours and makes the page
/// transparent, so the plate shows through in light and dark. The page's content is unchanged.
struct HomeReportView: NSViewRepresentable {
    var url: URL
    var ink: VT.Window

    /// The overrides: the report's `--bg/--ink/--mute/--faint/--rule/--panel/--accent` become the window's
    /// background-less text strengths, separator, fill and mint text colour.
    static func stylesheet(ink: VT.Window) -> String {
        """
        :root{--bg:transparent;--ink:\(css(ink.primary));--mute:\(css(ink.secondary));--faint:\(css(ink.tertiary));\
        --rule:\(css(ink.separator));--panel:\(css(ink.fill));--accent:\(css(ink.mintText))}
        html,body{background:transparent;color-scheme:\(ink.dark ? "dark" : "light")}
        main{max-width:none;padding:28px 28px 40px}
        h1{font-size:26px;font-weight:700;letter-spacing:-.02em}
        section{margin-top:40px}
        .answer{color:var(--ink)}
        """
    }

    /// `rgba(...)` for a SwiftUI colour in sRGB.
    static func css(_ c: Color) -> String {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .labelColor
        return String(format: "rgba(%d,%d,%d,%.3f)", Int((n.redComponent * 255).rounded()), Int((n.greenComponent * 255).rounded()),
                      Int((n.blueComponent * 255).rounded()), n.alphaComponent)
    }

    /// The report's HTML with the overrides as the last thing in `<head>`.
    static func html(of url: URL, ink: VT.Window) -> String? {
        guard var page = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let block = "<style>\n\(stylesheet(ink: ink))</style>"
        if let r = page.range(of: "</head>", options: .caseInsensitive) { page.insert(contentsOf: block, at: r.lowerBound) } else { page = block + page }
        return page
    }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        load(web, context: context)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) { load(web, context: context) }

    private func load(_ web: WKWebView, context: Context) {
        let key = "\(url.path)|\(ink.dark)|\(ink.increaseContrast)"
        guard context.coordinator.loaded != key else { return }
        context.coordinator.loaded = key
        if let page = Self.html(of: url, ink: ink) {
            web.loadHTMLString(page, baseURL: url.deletingLastPathComponent())
        } else {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var loaded: String? }
}
