import AppKit
import ScreenCaptureKit
import SwiftUI

/// Captures a SwiftUI scene that contains Liquid Glass. `ImageRenderer` cannot draw glass (the window server does),
/// so the scene goes into a borderless window parked just below the screen's bottom edge at desktop level, and
/// ScreenCaptureKit grabs only that window (this process's own windows need no Screen Recording permission).
@MainActor
enum Capture {
    static func png<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, to url: URL) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.ignoresCycle, .transient]
        window.hasShadow = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height).clipped())
        if let s = NSScreen.main { window.setFrameOrigin(NSPoint(x: s.frame.midX - size.width / 2, y: s.frame.minY - size.height + 2)) }
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(600))

        let content = try await SCShareableContent.currentProcess
        guard let w = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw NSError(domain: "Capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "window not capturable"])
        }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let cfg = SCStreamConfiguration()
        let px = CGFloat(filter.pointPixelScale)
        cfg.width = Int(size.width * px)
        cfg.height = Int(size.height * px)
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        var image: CGImage?
        var lastError: Error?
        for attempt in 0..<5 where image == nil {
            do { image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
        }
        guard let image else { throw lastError ?? NSError(domain: "Capture", code: 3) }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Capture", code: 2)
        }
        try png.write(to: url)
    }
}
