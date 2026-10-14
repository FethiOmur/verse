import SwiftUI

/// Visual constants of the overlay. One accent colour; everything else is white at different strengths on dark glass.
public enum OverlayStyle {
    /// The single accent: a calm mint, used for the live dot and the SAY marker only.
    public static let accent = Color(red: 0.42, green: 0.90, blue: 0.70)
    static let wing: CGFloat = 72
    /// The morph between capsule and card (spec: <= 150 ms, no spring).
    static let morphDuration: Double = 0.14
    static let morph = Animation.easeOut(duration: morphDuration)
}

/// Where the overlay sits: the notch (or a notch-sized spot on a screen without one).
public struct NotchMetrics: Equatable, Sendable {
    public var notchWidth: CGFloat
    public var notchHeight: CGFloat
    public var hasNotch: Bool

    public init(notchWidth: CGFloat, notchHeight: CGFloat, hasNotch: Bool) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.hasNotch = hasNotch
    }

    /// A 14"/16" MacBook Pro notch.
    public static let macBookPro = NotchMetrics(notchWidth: 186, notchHeight: 32, hasNotch: true)

    public var capsuleHeight: CGFloat { max(notchHeight, 28) }

    public func capsuleWidth(wide: Bool) -> CGFloat { notchWidth + 2 * (wide ? OverlayStyle.wing + 64 : OverlayStyle.wing) }
}

/// The live dot.
struct StatusDot: View {
    var activity: OverlayActivity
    @State private var breathe = false

    var body: some View {
        ZStack {
            switch activity {
            case .offline, .idle:
                Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1.4)
            case .warming, .thinking:
                Circle().fill(OverlayStyle.accent).opacity(breathe ? 1.0 : 0.35)
            case .listening:
                Circle().fill(OverlayStyle.accent)
            }
        }
        .frame(width: 8, height: 8)
        .onAppear { breathe = true }
        .animation(activity == .thinking || activity == .warming ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                   value: breathe)
        .accessibilityLabel(activity.rawValue)
    }
}

/// The compact island: dot on the left wing, the tag (or a short status) on the right wing. Always the same width,
/// so the notch stays centred in it; longer messages go to the panel under it.
struct CapsuleView: View {
    var state: OverlayState
    var metrics: NotchMetrics

    var body: some View {
        HStack(spacing: 0) {
            StatusDot(activity: state.status == .offline ? .offline : state.activity)
                .frame(width: OverlayStyle.wing, alignment: .leading)
                .padding(.leading, 18)
            Spacer(minLength: 0)
            Group {
                if let s = state.status {
                    Text(s.shortTitle).foregroundStyle(.white)
                } else {
                    Text(state.capsuleTag).foregroundStyle(.white.opacity(state.tagDimmed ? 0.45 : 0.82))
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: OverlayStyle.wing, alignment: .trailing)
            .padding(.trailing, 18)
        }
        .frame(width: metrics.capsuleWidth(wide: false), height: metrics.capsuleHeight)
        .transaction { $0.animation = nil }
    }
}

/// The question card: SAY line, points, fact chips, Sonnet's points.
struct CardView: View {
    var card: OverlayCard
    var scale: CGFloat

    private func size(_ s: CGFloat) -> CGFloat { (s * scale).rounded() }

    var body: some View {
        VStack(alignment: .leading, spacing: size(10)) {
            if let say = card.say {
                HStack(alignment: .top, spacing: size(11)) {
                    Capsule().fill(OverlayStyle.accent).frame(width: 3)
                        .padding(.vertical, size(3))
                    VStack(alignment: .leading, spacing: size(4)) {
                        Text(say)
                            .font(.system(size: size(20), weight: .semibold))
                            .tracking(-0.25)
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        if card.sayCorrected {
                            Label("Corrected by Sonnet", systemImage: "arrow.uturn.backward")
                                .font(.system(size: size(11), weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Listening to the question…")
                    .font(.system(size: size(15), weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            if !card.bullets.isEmpty {
                PointList(points: card.bullets, scale: scale, opacity: 0.88)
            }
            if !card.chips.isEmpty {
                ChipRow(chips: card.chips, scale: scale)
            }
            if !card.deepPoints.isEmpty {
                SonnetDivider(scale: scale)
                PointList(points: card.deepPoints, scale: scale, opacity: 0.78)
            }
        }
        .padding(.horizontal, size(20))
        .padding(.top, size(16))
        .padding(.bottom, size(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { $0.animation = nil }
    }
}

struct PointList: View {
    var points: [String]
    var scale: CGFloat
    var opacity: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                HStack(alignment: .firstTextBaseline, spacing: 9 * scale) {
                    Circle().fill(.white.opacity(0.5)).frame(width: 4 * scale, height: 4 * scale)
                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4.5 * scale }
                    Text(p)
                        .font(.system(size: (14 * scale).rounded()))
                        .foregroundStyle(.white.opacity(opacity))
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 14 * scale)
    }
}

struct ChipRow: View {
    var chips: [OverlayChip]
    var scale: CGFloat
    var leading: CGFloat = 14

    var body: some View {
        FlowLayout(spacing: 6 * scale) {
            ForEach(chips) { c in
                HStack(spacing: 5 * scale) {
                    Text(c.text).foregroundStyle(.white.opacity(0.92)).lineLimit(1).truncationMode(.tail)
                    Text("·").foregroundStyle(.white.opacity(0.4))
                    Text(c.source).foregroundStyle(.white.opacity(0.62)).lineLimit(1).fixedSize()
                }
                .font(.system(size: (12 * scale).rounded(), weight: .medium))
                .padding(.horizontal, 8 * scale)
                .padding(.vertical, 4 * scale)
                .background(RoundedRectangle(cornerRadius: 7 * scale, style: .continuous).fill(.white.opacity(0.11)))
                .overlay(RoundedRectangle(cornerRadius: 7 * scale, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            }
        }
        .padding(.leading, leading * scale)
    }
}

struct SonnetDivider: View {
    var scale: CGFloat
    var body: some View {
        HStack(spacing: 8 * scale) {
            Rectangle().fill(.white.opacity(0.16)).frame(width: 14 * scale, height: 0.5)
            Text("Sonnet").font(.system(size: (11 * scale).rounded(), weight: .medium)).foregroundStyle(.white.opacity(0.5))
            Rectangle().fill(.white.opacity(0.16)).frame(height: 0.5)
        }
        .padding(.leading, 14 * scale)
        .padding(.top, 2 * scale)
    }
}

/// A status that needs more than the capsule: permission (with a System Settings button), credit, error.
struct StatusPanelView: View {
    var status: OverlayStatus
    var scale: CGFloat
    var onOpenSettings: (String) -> Void
    var onDismiss: () -> Void
    /// Shown for errors when nothing is running.
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            Text(status.title)
                .font(.system(size: (16 * scale).rounded(), weight: .semibold))
                .foregroundStyle(.white)
            if let d = status.detail {
                Text(d)
                    .font(.system(size: (13 * scale).rounded()))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if case .permission(let kind) = status {
                    Button("Open System Settings") { onOpenSettings(kind) }
                        .buttonStyle(OverlayButtonStyle(prominent: true, scale: scale))
                }
                if let onRetry {
                    Button("Retry", action: onRetry)
                        .buttonStyle(OverlayButtonStyle(prominent: true, scale: scale))
                }
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(OverlayButtonStyle(prominent: false, scale: scale))
            }
        }
        .padding(18 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The start-up panel: Starting… (with the step) → Ready · session → Listening. Stays until the first card or a click
/// on the capsule.
struct StartupPanelView: View {
    var panel: StartupPanel
    var scale: CGFloat

    private var starting: Bool { if case .starting = panel.phase { return true }; return false }

    var body: some View {
        HStack(alignment: .center, spacing: 12 * scale) {
            Group {
                if starting {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Circle().fill(Color.green).frame(width: 10 * scale, height: 10 * scale)
                        .shadow(color: .green.opacity(0.6), radius: 4)
                }
            }
            .frame(width: 18 * scale, height: 18 * scale)
            VStack(alignment: .leading, spacing: 3 * scale) {
                Text(panel.title)
                    .font(.system(size: (16 * scale).rounded(), weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(panel.subtitle)
                    .font(.system(size: (13 * scale).rounded()))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18 * scale)
        .padding(.top, 12 * scale)
        .padding(.bottom, 16 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("verse.startup")
    }
}

/// Buttons on the dark glass: white label, quiet fill; the prominent one carries the accent.
struct OverlayButtonStyle: ButtonStyle {
    var prominent: Bool
    var scale: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: (13 * scale).rounded(), weight: .semibold))
            .foregroundStyle(prominent ? Color.black.opacity(0.88) : .white)
            .padding(.horizontal, 12 * scale)
            .padding(.vertical, 6 * scale)
            .background(RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                .fill(prominent ? OverlayStyle.accent : Color.white.opacity(0.14)))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

/// Lays chips out in rows.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(ProposedViewSize(width: maxW, height: nil))
            let w = min(sz.width, maxW)
            if x > 0, x + w > maxW { y += rowH + spacing; x = 0; rowH = 0 }
            x += w + spacing
            rowH = max(rowH, sz.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            let w = min(sz.width, bounds.width)
            if x > bounds.minX, x + w > bounds.maxX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: w, height: sz.height))
            x += w + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

/// The resize grip at the bottom of the card.
struct ResizeGrip: View {
    var onDrag: (CGSize) -> Void
    var onEnd: () -> Void
    @State private var hovering = false

    var body: some View {
        Capsule()
            .fill(.white.opacity(hovering ? 0.5 : 0.22))
            .frame(width: 36, height: 4)
            .frame(width: 120, height: 14)
            .contentShape(Rectangle())
            .onHover { h in
                hovering = h
                if h { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { onDrag($0.translation) }
                    .onEnded { _ in onEnd() }
            )
            .accessibilityLabel("Resize")
    }
}

/// Everything under the notch, as one surface: the black band around the notch with the capsule's dot and tag, and
/// the card, status message or topic row below it. The glass is a single hanging silhouette that grows out of the
/// notch (Moonglade's shape and glass, see `HangingNotchGeometry` and `NotchGlass`); only that surface animates.
/// Text is laid out at its final place and full opacity at once, never animated.
public struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @ObservedObject var settings: AppSettings
    var metrics: NotchMetrics
    var onOpenSettings: (String) -> Void
    var onRetry: () -> Void
    var onSizeChange: (CGSize) -> Void

    @State private var dragStart: (width: Double, height: Double)?
    /// The size the glass shows now; it follows `target` with the morph.
    @State private var surface: CGSize = .zero
    /// The content's own size plus the shoulders.
    @State private var target: CGSize = .zero

    public init(model: OverlayModel, settings: AppSettings, metrics: NotchMetrics,
                onOpenSettings: @escaping (String) -> Void = { _ in }, onRetry: @escaping () -> Void = {},
                onSizeChange: @escaping (CGSize) -> Void = { _ in }) {
        self.model = model
        self.settings = settings
        self.metrics = metrics
        self.onOpenSettings = onOpenSettings
        self.onRetry = onRetry
        self.onSizeChange = onSizeChange
    }

    private var state: OverlayState { model.state }
    private var scale: CGFloat { settings.textScale.factor }
    private var showPanel: Bool { state.status?.needsPanel ?? false }
    private var showStartup: Bool { state.card == nil && !showPanel && state.startup != nil }
    private var showTopics: Bool { state.card == nil && !showPanel && !showStartup && !state.topics.isEmpty }
    private static let shoulder = HangingNotchMetrics.topShoulderRadius
    private var capsuleWidth: CGFloat { metrics.capsuleWidth(wide: false) }

    /// The size the surface has before the first measurement: the compact capsule.
    private var compactSize: CGSize { CGSize(width: capsuleWidth + 2 * Self.shoulder, height: metrics.capsuleHeight) }

    public var body: some View {
        let shown = surface == .zero ? compactSize : surface
        ZStack(alignment: .top) {
            ZStack {
                NotchGlassBackdrop()
                NotchGlassScrim(bandHeight: metrics.capsuleHeight)
            }
            .frame(width: shown.width, height: shown.height)

            content
                .padding(.horizontal, Self.shoulder)
                .fixedSize()
                .transaction { $0.animation = nil }
                .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { surfaceTargetChanged($0) })
        }
        .frame(width: max(shown.width, target.width), height: max(shown.height, target.height), alignment: .top)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// The band (capsule row) and, under it, whatever is open. The band keeps the capsule's width and stays centred,
    /// so the dot and the tag do not move when the surface grows.
    private var content: some View {
        VStack(spacing: 0) {
            CapsuleView(state: state, metrics: metrics)
                .contentShape(Rectangle())
                // Click the capsule: close the card (or the start-up panel). The panel never becomes key, so Esc
                // can't reach it; the click is the dismiss.
                .onTapGesture { model.collapse() }
            if showPanel, let s = state.status {
                let canRetry: Bool = { if case .error = s { return !state.running }; return false }()
                StatusPanelView(status: s, scale: scale, onOpenSettings: onOpenSettings, onDismiss: { model.dismissStatus() },
                                onRetry: canRetry ? onRetry : nil)
                    .frame(width: max(capsuleWidth, CGFloat(min(settings.cardWidth, 520))))
            } else if showStartup, let p = state.startup {
                StartupPanelView(panel: p, scale: scale)
                    .frame(width: max(capsuleWidth, CGFloat(min(settings.cardWidth, 460))))
            } else if showTopics {
                ChipRow(chips: state.topics, scale: scale, leading: 0)
                    .frame(maxWidth: CGFloat(settings.cardWidth) - 32)
                    .fixedSize()
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                    .contentShape(Rectangle())
                    .onTapGesture { model.collapse() }   // a click on the row clears the topic hints
                    .frame(minWidth: capsuleWidth)
            } else if let card = state.card {
                VStack(spacing: 0) {
                    ScrollView(.vertical, showsIndicators: false) {
                        CardView(card: card, scale: scale)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: CGFloat(settings.cardMaxHeight))
                    .fixedSize(horizontal: false, vertical: true)
                    ResizeGrip(onDrag: resize, onEnd: { dragStart = nil })
                        .padding(.bottom, 4)
                }
                .frame(width: CGFloat(settings.cardWidth))
            }
        }
    }

    private func surfaceTargetChanged(_ size: CGSize) {
        target = size
        onSizeChange(size)
        if surface == .zero {
            surface = size
        } else {
            withAnimation(OverlayStyle.morph) { surface = size }
        }
    }

    private func resize(_ t: CGSize) {
        if dragStart == nil { dragStart = (settings.cardWidth, settings.cardMaxHeight) }
        guard let s = dragStart else { return }
        settings.cardWidth = (s.width + 2 * Double(t.width)).clamped(to: AppSettings.cardWidthRange)
        settings.cardMaxHeight = (s.height + Double(t.height)).clamped(to: AppSettings.cardMaxHeightRange)
    }
}
