import SwiftUI

/// Visual constants of the overlay. One accent colour; everything else is white at different strengths on dark glass.
public enum OverlayStyle {
    /// The single accent: a calm mint, used for the live dot and the SAY marker only.
    public static let accent = Color(red: 0.42, green: 0.90, blue: 0.70)
    static let wing: CGFloat = 72
    static let cardGap: CGFloat = 8
    static let cardRadius: CGFloat = 26
    /// The morph between capsule and card (spec: <= 150 ms, no spring).
    static let morph = Animation.easeOut(duration: 0.14)
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

/// The black island around the notch: flush with the top edge, small concave flares where it meets the screen edge
/// (like the hardware notch), and round lower corners.
struct IslandShape: Shape {
    var bottomRadius: CGFloat
    var flare: CGFloat = 7

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let f = min(flare, r.width / 4)
        let br = min(bottomRadius, (r.height) / 1.0, (r.width - 2 * f) / 2)
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        // top-right flare (concave)
        p.addQuadCurve(to: CGPoint(x: r.maxX - f, y: r.minY + f), control: CGPoint(x: r.maxX - f, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - f, y: r.maxY - br))
        p.addQuadCurve(to: CGPoint(x: r.maxX - f - br, y: r.maxY), control: CGPoint(x: r.maxX - f, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + f + br, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX + f, y: r.maxY - br), control: CGPoint(x: r.minX + f, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + f, y: r.minY + f))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY), control: CGPoint(x: r.minX + f, y: r.minY))
        p.closeSubpath()
        return p
    }
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
                    Text(c.source).foregroundStyle(.white.opacity(0.55)).lineLimit(1).fixedSize()
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
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(OverlayButtonStyle(prominent: false, scale: scale))
            }
        }
        .padding(18 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// Everything under the notch: the island, and the card or status message that grows out of it.
public struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @ObservedObject var settings: AppSettings
    var metrics: NotchMetrics
    var onOpenSettings: (String) -> Void
    var onSizeChange: (CGSize) -> Void

    @Namespace private var ns
    @State private var dragStart: (width: Double, height: Double)?

    public init(model: OverlayModel, settings: AppSettings, metrics: NotchMetrics,
                onOpenSettings: @escaping (String) -> Void = { _ in }, onSizeChange: @escaping (CGSize) -> Void = { _ in }) {
        self.model = model
        self.settings = settings
        self.metrics = metrics
        self.onOpenSettings = onOpenSettings
        self.onSizeChange = onSizeChange
    }

    private var state: OverlayState { model.state }
    private var scale: CGFloat { settings.textScale.factor }
    private var showPanel: Bool { state.status?.needsPanel ?? false }
    private var showTopics: Bool { state.card == nil && !showPanel && !state.topics.isEmpty }
    private var expanded: Bool { state.card != nil || showPanel || showTopics }

    /// Lower corners follow the card's corner radius when expanded, so the island and the card read as one family.
    private var islandRadius: CGFloat { metrics.capsuleHeight / 2 - 1 }

    /// The glass itself stays clear-ish; a dark veil inside it carries the contrast, so white text stays readable over a
    /// white page (measured >= 7:1) and over a bright window in a video frame.
    private var cardGlass: Glass { .regular.tint(Color(white: 0.05).opacity(0.35)) }
    private static let veil = Color(white: 0.02).opacity(0.46)

    public var body: some View {
        GlassEffectContainer(spacing: 24) {
            VStack(spacing: OverlayStyle.cardGap) {
                CapsuleView(state: state, metrics: metrics)
                    .background(IslandShape(bottomRadius: islandRadius).fill(Color.black))
                    .glassEffect(.identity, in: IslandShape(bottomRadius: islandRadius))
                    .glassEffectID("island", in: ns)

                if showPanel, let s = state.status {
                    StatusPanelView(status: s, scale: scale, onOpenSettings: onOpenSettings, onDismiss: { model.dismissStatus() })
                        .frame(width: CGFloat(min(settings.cardWidth, 520)))
                        .background(Self.veil, in: RoundedRectangle(cornerRadius: OverlayStyle.cardRadius, style: .continuous))
                        .glassEffect(cardGlass, in: RoundedRectangle(cornerRadius: OverlayStyle.cardRadius, style: .continuous))
                        .glassEffectID("panel", in: ns)
                        .glassEffectTransition(.matchedGeometry)
                } else if showTopics {
                    ChipRow(chips: state.topics, scale: scale, leading: 0)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: CGFloat(settings.cardWidth))
                        .fixedSize()
                        .transaction { $0.animation = nil }
                        .background(Self.veil, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .glassEffect(cardGlass, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .glassEffectID("topics", in: ns)
                        .glassEffectTransition(.matchedGeometry)
                } else if let card = state.card {
                    VStack(spacing: 0) {
                        ScrollView(.vertical, showsIndicators: false) {
                            CardView(card: card, scale: scale)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxHeight: CGFloat(settings.cardMaxHeight))
                        .fixedSize(horizontal: false, vertical: true)
                        ResizeGrip(onDrag: resize, onEnd: { dragStart = nil })
                            .padding(.bottom, 2)
                    }
                    .frame(width: CGFloat(settings.cardWidth))
                    .background(Self.veil, in: RoundedRectangle(cornerRadius: OverlayStyle.cardRadius, style: .continuous))
                    .glassEffect(cardGlass, in: RoundedRectangle(cornerRadius: OverlayStyle.cardRadius, style: .continuous))
                    .glassEffectID("card", in: ns)
                    .glassEffectTransition(.matchedGeometry)
                }
            }
        }
        .animation(OverlayStyle.morph, value: expanded)
        .animation(OverlayStyle.morph, value: state.status)
        .environment(\.colorScheme, .dark)
        // The panel follows the content's own size (measured before any outer frame, so it can't feed back).
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { onSizeChange($0) })
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func resize(_ t: CGSize) {
        if dragStart == nil { dragStart = (settings.cardWidth, settings.cardMaxHeight) }
        guard let s = dragStart else { return }
        settings.cardWidth = (s.width + 2 * Double(t.width)).clamped(to: AppSettings.cardWidthRange)
        settings.cardMaxHeight = (s.height + Double(t.height)).clamped(to: AppSettings.cardMaxHeightRange)
    }
}
