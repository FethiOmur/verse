import AppKit
import SwiftUI

// G2: the home window's glass (spec 2.4). The whole window is one glass sheet behind the window, with the window
// background colour on top at the user's Window opacity. The sheet is an AppKit view placed under the SwiftUI
// content; SwiftUI's own `glassEffect` samples only its own window, so it cannot show the desktop.

/// Which AppKit view carries the behind-window glass.
enum HomeGlassKind: String {
    /// `NSGlassEffectView` (macOS 26 Liquid Glass).
    case glass
    /// `NSVisualEffectView` `.behindWindow`, the ChatGPT recipe (`vibrancy: menu`).
    case visualEffect

    /// `VERSE_HOME_GLASS=visual` forces the fallback (used to compare the two on screen).
    static var current: HomeGlassKind {
        HomeGlassKind(rawValue: ProcessInfo.processInfo.environment["VERSE_HOME_GLASS"] ?? "") ?? .glass
    }
}

/// Makes the hosting window non-opaque with a hidden title bar, puts the glass sheet behind the content, and moves the
/// traffic lights into the sidebar's corner.
struct HomeWindowConfigurator: NSViewRepresentable {
    var reduceTransparency: Bool

    func makeNSView(context: Context) -> ConfiguratorView {
        let v = ConfiguratorView()
        v.reduceTransparency = reduceTransparency
        return v
    }

    func updateNSView(_ v: ConfiguratorView, context: Context) {
        v.reduceTransparency = reduceTransparency
        v.apply()
    }

    @MainActor
    final class ConfiguratorView: NSView {
        var reduceTransparency = false
        private weak var configured: NSWindow?
        private var glass: NSView?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window, configured !== w else { return }
            // The hosting view is not laid out yet when the window is first attached.
            DispatchQueue.main.async { [weak self] in self?.configure(w) }
        }

        private func configure(_ w: NSWindow) {
            guard configured !== w else { return }
            configured = w
            w.identifier = HomeRouter.windowIdentifier
            w.isOpaque = false
            w.backgroundColor = .clear
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.isMovableByWindowBackground = false
            w.minSize = NSSize(width: 900, height: 600)
            w.hasShadow = true
            // Opens in the Space you are in, also over a full-screen app (it is a menu-bar app's window).
            w.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
            installGlass(in: w)
            let nc = NotificationCenter.default
            for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(nc.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.placeTrafficLights(); w.invalidateShadow() }
                })
            }
            placeTrafficLights()
            apply()
        }

        private func installGlass(in w: NSWindow) {
            guard let host = w.contentView, let frame = host.superview else { return }
            let radius = VT.Radius.window
            let view: NSView
            switch HomeGlassKind.current {
            case .glass:
                let g = NSGlassEffectView(frame: host.frame)
                g.cornerRadius = radius
                g.style = .regular
                view = g
            case .visualEffect:
                let v = NSVisualEffectView(frame: host.frame)
                v.blendingMode = .behindWindow
                v.material = .menu
                v.state = .active
                v.maskImage = Self.roundedMask(radius: radius)
                view = v
            }
            view.autoresizingMask = [.width, .height]
            frame.addSubview(view, positioned: .below, relativeTo: host)
            glass = view
        }

        /// A stretchable rounded-rect mask, the way `NSVisualEffectView` takes a corner radius.
        private static func roundedMask(radius: CGFloat) -> NSImage {
            let d = radius * 2 + 1
            let image = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                return true
            }
            image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
            image.resizingMode = .stretch
            return image
        }

        /// Reduce Transparency: no glass at all, the SwiftUI background is solid.
        func apply() {
            glass?.isHidden = reduceTransparency
            window?.invalidateShadow()
        }

        /// The mockup puts the traffic lights at x 20, centred 26 pt from the top.
        private func placeTrafficLights() {
            guard let w = window else { return }
            let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (i, k) in kinds.enumerated() {
                guard let b = w.standardWindowButton(k), let sv = b.superview else { continue }
                let x = 20 + CGFloat(i) * 20
                // `isFlipped` differs by container; place by the visual top edge.
                let y = sv.isFlipped ? 26 - b.frame.height / 2 : sv.bounds.height - 26 - b.frame.height / 2
                b.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }
    }
}

/// The veil and the 1 pt edge on top of the window glass (spec 2.4): the window background colour at the user's Window
/// opacity. Reduce Transparency: solid. Increase Contrast: nearly solid with a stronger edge.
struct HomeWindowVeil: View {
    var ink: VT.Window
    var opacity: Double
    /// Render only: the in-window glass that stands in for the behind-window sheet.
    var inWindowGlass = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: VT.Radius.window, style: .continuous)
        ZStack {
            if ink.reduceTransparency {
                shape.fill(ink.background)
            } else {
                if inWindowGlass { shape.fill(.clear).glassEffect(.regular, in: shape) }
                shape.fill(ink.background.opacity(ink.increaseContrast ? 0.94 : opacity))
            }
        }
    }
}
