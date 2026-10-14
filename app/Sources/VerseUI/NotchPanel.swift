import AppKit
import Combine
import SwiftUI

/// A borderless panel that never takes focus (the meeting app keeps it).
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The notch overlay window: a non-activating panel at the top center of the screen with the notch, above the menu
/// bar, on every Space and over full-screen apps, outside the window cycle and Mission Control.
///
/// The panel is only as big as what it shows (the capsule, or capsule + card), so it never blocks clicks elsewhere.
@MainActor
public final class NotchPanelController {
    private let panel: OverlayPanel
    private let model: OverlayModel
    private let settings: AppSettings
    private var metrics: NotchMetrics
    private var screen: NSScreen
    private var contentSize = CGSize(width: 300, height: 32)
    private var screenObserver: NSObjectProtocol?
    private var stateSub: AnyCancellable?
    private var hostingView: NSHostingView<AnyView>?
    private var layoutPending = false

    public init(model: OverlayModel, settings: AppSettings, onOpenSettings: @escaping (String) -> Void) {
        self.model = model
        self.settings = settings
        let s = Self.notchScreen()
        screen = s
        metrics = Self.metrics(for: s)
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 32),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        panel.title = "Verse overlay"

        let root = OverlayView(model: model, settings: settings, metrics: metrics, onOpenSettings: onOpenSettings,
                               onSizeChange: { [weak self] size in self?.contentSizeChanged(size) })
        let host = NSHostingView(rootView: AnyView(root.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)))
        host.sizingOptions = []
        // The hosting view sits inside a plain container so it never drives the window's size itself (as a window's
        // content view it resizes the window from inside the display cycle, which AppKit aborts on).
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container
        hostingView = host
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenChanged() }
        }
        // Nothing running and nothing to read: no window on screen.
        stateSub = model.$state.receive(on: RunLoop.main).sink { [weak self] s in
            MainActor.assumeIsolated {
                if !s.running, s.status == nil { self?.hide() }
            }
        }
    }

    public var windowNumber: Int { panel.windowNumber }
    public var isVisible: Bool { panel.isVisible }

    public func show() {
        layout()
        panel.orderFrontRegardless()
    }

    public func hide() {
        panel.orderOut(nil)
    }

    /// Closes the window for good (Quit).
    public func close() {
        panel.orderOut(nil)
        panel.close()
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
        screenObserver = nil
    }

    private func screenChanged() {
        let s = Self.notchScreen()
        let m = Self.metrics(for: s)
        screen = s
        if m != metrics {
            metrics = m
            let root = OverlayView(model: model, settings: settings, metrics: metrics, onOpenSettings: { _ in },
                                   onSizeChange: { [weak self] size in self?.contentSizeChanged(size) })
            hostingView?.rootView = AnyView(root.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        }
        layout()
    }

    /// Called from SwiftUI's layout pass: the window frame is never changed right there, only on the next turn of the
    /// run loop (growing) or after the morph (shrinking).
    private func contentSizeChanged(_ size: CGSize) {
        let grow = size.width > contentSize.width || size.height > contentSize.height
        contentSize = size
        if grow {
            scheduleLayout(after: 0)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.contentSize == size else { return }
                self.layout()
            }
        }
    }

    private func scheduleLayout(after delay: TimeInterval) {
        guard !layoutPending else { return }
        layoutPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.layoutPending = false
            self.layout()
        }
    }

    private func layout() {
        let f = screen.frame
        // Never wider than the screen, whatever the content reports.
        contentSize.width = min(contentSize.width, f.width)
        contentSize.height = min(contentSize.height, f.height * 0.8)
        let w = ceil(max(contentSize.width, metrics.capsuleWidth(wide: false))) + 16   // room for the glass rim
        let h = ceil(max(contentSize.height, metrics.capsuleHeight)) + 12
        let frame = NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// The built-in screen with the notch, else the main screen.
    static func notchScreen() -> NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func metrics(for s: NSScreen) -> NotchMetrics {
        let top = s.safeAreaInsets.top
        if top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            return NotchMetrics(notchWidth: s.frame.width - l.width - r.width, notchHeight: top, hasNotch: true)
        }
        // No notch: a notch-sized island at the top center, as tall as the menu bar.
        let menuBar = s.frame.maxY - s.visibleFrame.maxY
        return NotchMetrics(notchWidth: 180, notchHeight: max(menuBar, 28), hasNotch: false)
    }
}
