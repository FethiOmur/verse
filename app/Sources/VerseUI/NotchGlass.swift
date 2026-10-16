// Adapted from Moonglade (MIT, Copyright (c) 2026 Josemi Hernandez), Sources/MoongladeApp/NotchGlassBackground.swift and Sources/MoongladeCore/Presentation/NotchGlassStyle.swift; see docs/licences.md.
import AppKit
import CoreGraphics
import SwiftUI

/// Tunables of the island's glass layer. The veil on top of it is `IslandVeil` (below).
///
/// Verse keeps Moonglade's lens values but sets the glass to the spec's Regular baseline (smoked dark Regular glass)
/// instead of Moonglade's clear one: Moonglade sits over the dark menu bar, Verse's card has to stay readable over a white
/// page and over a busy video frame. The face wash and the frost below were tuned against the approved mockups, which
/// use SwiftUI's `glassEffect(.regular)` in dark appearance: with the veil on top, the island's pixels over a white page
/// and over the call frame land within 1-3 of 255 of the mockup's (2026-10-16, `--render-screens`).
public enum NotchGlassStyle {
    /// Glass blur radius. Moonglade: 1 (a whisper). Regular glass frosts what is behind it so text underneath is not
    /// readable through the card; 14 matches the mockups.
    public static let frostRadius: Double = 14
    /// Forced onto the private glassBackground filter over the system clear baseline: the face wash back on, squeezing
    /// what the glass samples into a dark band (black 0.06 ... white 0.36), as Regular glass does in a dark appearance;
    /// lensing boosted past the stock style (Moonglade's values, kept).
    public static let glassFilterOverrides: [String: Double] = [
        "inputFaceOpacity": 1,
        "inputFaceColorMatrixBlack": 0.06,
        "inputFaceColorMatrixWhite": 0.36,
        "inputInnerRefractionAmount": -80,
        "inputInnerRefractionHeight": 26,
    ]
}

/// The island's veil (UI redesign spec 2.4, G1): pure black through the camera band, then a smootherstep down to the
/// floor, the user's Island opacity, and a last strip that eases to 75 % of the floor so the lower rim reads as glass.
/// Pure math, so the stops are testable without a window.
public enum IslandVeil {
    public struct Stop: Equatable, Sendable {
        public let location: Double
        public let opacity: Double
    }

    /// Veil floor for the user's opacity. Reduce Transparency is solid; Increase Contrast keeps at least 92 %.
    public static func floor(userOpacity: Double, reduceTransparency: Bool, increaseContrast: Bool) -> Double {
        let user = min(max(userOpacity, 0.35), 1)   // AppSettings.islandOpacityRange
        if reduceTransparency { return 1 }
        return increaseContrast ? max(user, 0.92) : user
    }

    static func smootherstep(_ t: Double) -> Double { t * t * t * (t * (t * 6 - 15) + 10) }

    /// Black-opacity stops over a surface `height` tall whose band is `bandHeight` (the notch height; the black runs 6 pt
    /// past it). The dissolve reaches the floor at band + 34 % of the height (at most 78 %); the last
    /// `VT.islandRimHeight` points ease to `rimFactor * floor`. A surface no taller than the band is flat black.
    public static func stops(height: CGFloat, bandHeight: CGFloat, floor: Double, rimFactor: Double = 0.75) -> [Stop] {
        let h = Double(max(height, 1))
        let band = min((Double(bandHeight) + Double(VT.islandBandOverlap)) / h, 1)
        guard band < 1 else { return [Stop(location: 0, opacity: 1), Stop(location: 1, opacity: 1)] }
        var stops = [Stop(location: 0, opacity: 1), Stop(location: band, opacity: 1)]
        let reach = max(band + 0.01, min(0.78, band + 0.34))
        for i in 1...8 {
            let t = Double(i) / 8
            stops.append(Stop(location: band + (reach - band) * t, opacity: 1 - (1 - floor) * smootherstep(t)))
        }
        let rimStart = max(reach, 1 - Double(VT.islandRimHeight) / h)
        let rim = floor * rimFactor
        for i in 0...6 {
            let t = Double(i) / 6
            stops.append(Stop(location: rimStart + (1 - rimStart) * t, opacity: floor - (floor - rim) * smootherstep(t)))
        }
        return stops
    }

    /// Reduce Transparency: the solid surface shows below the band; the black band blends into it over 10 pt.
    public static func solidStops(height: CGFloat, bandHeight: CGFloat) -> [Stop] {
        let h = Double(max(height, 1))
        let band = min((Double(bandHeight) + Double(VT.islandBandOverlap)) / h, 1)
        guard band < 1 else { return [Stop(location: 0, opacity: 1), Stop(location: 1, opacity: 1)] }
        return [Stop(location: 0, opacity: 1), Stop(location: band, opacity: 1), Stop(location: min(1, band + 10 / h), opacity: 0), Stop(location: 1, opacity: 0)]
    }
}

/// The SwiftUI half of the surface: the black veil over the glass, in the island's silhouette, and the rim.
struct IslandVeilView: View {
    var bandHeight: CGFloat
    var floor: Double
    var reduceTransparency: Bool
    var increaseContrast: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let shape = HangingNotchShape()
            ZStack {
                if reduceTransparency {
                    shape.fill(VT.islandSolid)
                    shape.fill(gradient(IslandVeil.solidStops(height: size.height, bandHeight: bandHeight)))
                } else {
                    shape.fill(gradient(IslandVeil.stops(height: size.height, bandHeight: bandHeight, floor: floor)))
                }
                if increaseContrast {
                    shape.stroke(Color.white.opacity(0.6), lineWidth: 1.5)
                } else if !reduceTransparency, size.height > bandHeight + 8 {
                    shape.stroke(LinearGradient(stops: [.init(color: .white.opacity(0), location: 0),
                                                        .init(color: .white.opacity(0), location: min(0.99, Double((bandHeight + 10) / max(size.height, 1)))),
                                                        .init(color: .white.opacity(0.20), location: 1)],
                                                startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func gradient(_ stops: [IslandVeil.Stop]) -> LinearGradient {
        LinearGradient(stops: stops.map { Gradient.Stop(color: .black.opacity($0.opacity), location: $0.location) }, startPoint: .top, endPoint: .bottom)
    }
}

/// The live glass half: window-server Liquid Glass masked to the silhouette. It stays outside any SwiftUI layer
/// effect (a rasterizing effect would render it blank).
struct NotchGlassBackdrop: View {
    var body: some View {
        Group {
            if NotchCustomGlassView.isSupported {
                CustomGlassBackdrop()
            } else {
                VisualEffectBackdrop()
            }
        }
        .allowsHitTesting(false)
    }
}

private struct CustomGlassBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NotchCustomGlassView { NotchCustomGlassView() }
    func updateNSView(_ view: NotchCustomGlassView, context: Context) {}
}

/// Self-owned Liquid Glass: the private layer recipe inside `NSGlassEffectView`, owned outright so nothing re-commits
/// values over the tuning. SwiftUI's `glassEffect` samples only inside its own window (flat grey in a clear panel
/// over other apps), and `NSGlassEffectView` keeps resetting its filter, so neither gives this look.
///
///     CABackdropLayer ("@0", windowServerAware, glassBackground filter, masked to the silhouette)
///       └── CASDFLayer ("@0", CASDFOutputEffect(maximum: 1))
///             └── CALayer
///                   └── CASDFElementLayer (cornerRadius, continuous)
///
/// The filter reads its lens from the signed distance field of the sublayer named by `inputSourceSublayerName`;
/// without that stack it blurs but never refracts. Everything resolves at run time: `isSupported` is false when the
/// private classes are missing, and the overlay falls back to a behind-window blur.
final class NotchCustomGlassView: NSView {
    static let isSupported: Bool =
        makeGlassFilter() != nil
            && NSClassFromString("CASDFLayer") is CALayer.Type
            && NSClassFromString("CASDFElementLayer") is CALayer.Type
            && NSClassFromString("CASDFOutputEffect") is NSObject.Type

    private let shapeMask = CAShapeLayer()
    private var backdrop: CALayer?
    private var sdfLayer: CALayer?
    private var sdfContainer: CALayer?
    private var sdfElement: CALayer?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { installBackdropIfNeeded() }
    }

    /// Hosted as a plain sublayer, never as the backing layer: AppKit renames backing layers, which would break the
    /// "@0" pairing between the backdrop and its SDF source.
    private func installBackdropIfNeeded() {
        guard backdrop == nil, let host = layer else { return }
        guard let backdropType = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let sdfType = NSClassFromString("CASDFLayer") as? CALayer.Type,
              let elementType = NSClassFromString("CASDFElementLayer") as? CALayer.Type,
              let effectType = NSClassFromString("CASDFOutputEffect") as? NSObject.Type,
              let filter = Self.makeGlassFilter() else { return }

        let glass = backdropType.init()
        glass.name = "@0"
        glass.filters = [filter]
        // KVC on CALayer tolerates unknown keys, so these stay harmless if the private layer drops them.
        glass.setValue(true, forKey: "windowServerAware")
        glass.setValue(false, forKey: "allowsGroupBlending")
        glass.setValue(true, forKey: "allowsFilteredLuma")
        glass.setValue(0.5, forKey: "scale")
        glass.mask = shapeMask

        let sdf = sdfType.init()
        sdf.name = "@0"
        let effect = effectType.init()
        effect.setValue(1, forKey: "maximum")
        sdf.setValue(effect, forKey: "effect")

        let container = CALayer()
        let element = elementType.init()
        element.cornerRadius = HangingNotchMetrics.bottomCornerRadius
        element.cornerCurve = .continuous
        element.setValue(true, forKey: "hitTestsAsFill")
        container.addSublayer(element)
        sdf.addSublayer(container)
        glass.addSublayer(sdf)
        host.addSublayer(glass)

        backdrop = glass
        sdfLayer = sdf
        sdfContainer = container
        sdfElement = element
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop?.frame = bounds
        shapeMask.frame = bounds
        shapeMask.path = HangingNotchGeometry.path(in: bounds)
        sdfLayer?.frame = bounds
        sdfContainer?.frame = bounds
        // The lens is the straight-sided body: inset by the shoulder radius, so its round bottom corners coincide
        // with the silhouette's. Its top corners sit under the black band and never show.
        sdfElement?.frame = bounds.insetBy(dx: HangingNotchMetrics.topShoulderRadius, dy: 0)
        CATransaction.commit()
    }

    private static func makeGlassFilter() -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as AnyObject?,
              filterClass.responds(to: NSSelectorFromString("filterWithType:")),
              let filter = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "glassBackground")?
                  .takeUnretainedValue() as? NSObject
        else { return nil }
        // A fresh filter starts from zeroed inputs: seed the system baseline, then the tuning.
        for (key, value) in systemClearBaseline { filter.setValue(value, forKey: key) }
        for (key, value) in NotchGlassStyle.glassFilterOverrides { filter.setValue(value, forKey: key) }
        filter.setValue(NotchGlassStyle.frostRadius, forKey: "inputBlurRadius")
        return filter
    }

    /// Input values of a live `NSGlassEffectView` in `.clear` style, as Moonglade recovered them.
    private static let systemClearBaseline: [String: Any] = [
        "inputSourceSublayerName": "@0",
        "inputClamp": 1,
        "inputClampPreserveHue": false,
        "inputMaxHeadroom": 9999,
        "inputBlurRadius": 10,
        "inputBlurOpacity0": 1, "inputBlurDistance0": 0,
        "inputBlurOpacity1": 1, "inputBlurDistance1": 0,
        "inputBlurOpacity2": 1, "inputBlurDistance2": 0,
        "inputBlurOpacity3": 1, "inputBlurDistance3": 0,
        "inputBlurOpacity4": 1, "inputBlurDistance4": 0,
        "inputInnerRefractionAmount": -60,
        "inputInnerRefractionHeight": 20,
        "inputOuterRefractionAmount": 0,
        "inputOuterRefractionHeight": 0,
        "inputRefractionDistance0": -1,
        "inputRefractionDistance1": -0.5,
        "inputRefractionOpacity": 0,
        "inputFaceOpacity": 1,
        "inputFaceColorMatrixBlack": 0.05,
        "inputFaceColorMatrixWhite": 0.8,
        "inputFaceColorMatrixSaturation": 1,
        "inputFaceColorMatrixFillColor": CGColor(red: 1, green: 1, blue: 1, alpha: 0.05),
        "inputBleedAmount": 0,
        "inputBleedOpacity": 0,
        "inputBleedHeight": 0,
        "inputBleedBlurRadius": 0,
        "inputBleedDistance0": 1,
        "inputBleedDistance1": 0,
        "inputBleedDarkenBlend": true,
        "inputBleedColorMatrixBlack": 0.75,
        "inputBleedColorMatrixWhite": 1,
        "inputBleedColorMatrixSaturation": 1.2,
        "inputShadowOpacity": 0,
        "inputShadowAmount": 75,
        "inputShadowHeight": 48,
        "inputShadowRadius": 0,
        "inputShadowBlurRadius": 0,
        "inputShadowOffset": NSValue(size: NSSize(width: 0, height: 8)),
        "inputShadowDistanceOffset": 0,
        "inputShadowVibrancyContribution": 0,
        "inputShadowColorMatrixBlack": 0,
        "inputShadowColorMatrixWhite": 1,
        "inputShadowColorMatrixSaturation": 1.2,
        "inputShadowColorMatrixFillColor": CGColor(red: 0, green: 0, blue: 0, alpha: 0.1),
        "inputSDRGradientDistance0": 0,
        "inputSDRGradientDistance1": 0,
        "inputSDRShadowOpacity": 0,
        "inputSDRHoldingToneEnabled": false,
        "inputSDRHoldingToneWhite": 1,
    ]
}

/// Fallback: behind-window blur masked to the silhouette. SwiftUI clipping cannot clip behind-window blur, so the
/// mask lives on the `NSVisualEffectView`; every curve sits inside the cap insets, so resizing stretches only the
/// flat middle.
private struct VisualEffectBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.material = .fullScreenUI
        v.state = .active   // the panel never becomes key
        v.maskImage = Self.mask
        return v
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    private static let mask: NSImage = {
        let top = HangingNotchMetrics.topShoulderRadius
        let bottom = HangingNotchMetrics.bottomCornerRadius
        let side = top + bottom
        let image = NSImage(size: NSSize(width: side * 2 + 4, height: top + bottom + 4), flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.addPath(HangingNotchGeometry.path(in: rect))
            cg.setFillColor(.black)
            cg.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: top, left: side, bottom: bottom, right: side)
        image.resizingMode = .stretch
        return image
    }()
}
