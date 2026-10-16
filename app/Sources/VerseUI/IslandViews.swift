import SwiftUI

// The island's building blocks (UI redesign spec sections 2 and 3). Values come from `VT`; the approved mockups in
// design/mockups/Sources/VerseMockups/Island.swift are the reference for layout.

// MARK: - Accessibility environment

/// The accessibility switches the island follows. The system's own settings are the default; the screenshot renderer
/// forces them through `islandA11yOverride` (SwiftUI's own environment values are read-only).
struct IslandA11y: Equatable {
    var reduceTransparency = false
    var increaseContrast = false
    var reduceMotion = false
}

private struct IslandA11yOverrideKey: EnvironmentKey { static let defaultValue: IslandA11y? = nil }
private struct IslandContrastKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var islandA11yOverride: IslandA11y? {
        get { self[IslandA11yOverrideKey.self] }
        set { self[IslandA11yOverrideKey.self] = newValue }
    }
    /// Increase Contrast: points to 100 % white, wings to 85 %, chips get a border.
    var islandContrast: Bool {
        get { self[IslandContrastKey.self] }
        set { self[IslandContrastKey.self] = newValue }
    }
}

// MARK: - What the island shows

/// Which body sits under the band. One at a time, in this priority (the order the overlay always used).
enum IslandKind {
    case capsule
    case statusPanel(OverlayStatus)
    case prompt(MeetingPrompt)
    case sim(SimOverlay)
    case prompter
    case startup(StartupPanel)
    case topics
    case card(OverlayCard)

    static func resolve(_ s: OverlayState, prompterOpen: Bool) -> IslandKind {
        if let st = s.status, st.needsPanel { return .statusPanel(st) }
        if let p = s.meetingPrompt { return .prompt(p) }
        if let sim = s.sim { return .sim(sim) }
        if prompterOpen { return .prompter }
        if s.card == nil, let p = s.startup { return .startup(p) }
        if s.card == nil, !s.topics.isEmpty { return .topics }
        if let c = s.card { return .card(c) }
        return .capsule
    }

    /// Capsules are a bare band, 32 pt tall; everything else is a card.
    var isCapsule: Bool { if case .capsule = self { return true }; return false }
}

/// Widths of the island per state (spec 3.2). The width is the whole silhouette, shoulders included.
enum IslandWidth {
    static let status: CGFloat = 480
    static let prompt: CGFloat = 480
    static let startup: CGFloat = 480
    static let topics: CGFloat = 480
    static let practice: CGFloat = 520
    /// The teleprompter is 40 pt wider than the card.
    static let prompterExtra: CGFloat = 40

    static func width(kind: IslandKind, state: OverlayState, metrics: NotchMetrics, cardWidth: CGFloat, forcePracticeCapsule: Bool = false) -> CGFloat {
        switch kind {
        case .capsule:
            // Listening (354): someone is talking, a tag names who the question is for, or a short status ("Offline") needs
            // its wing. Otherwise the quiet capsule (266).
            let listening = state.status != nil || (state.running && (state.addresseeTag != nil || state.remoteSpeaking))
            return listening ? metrics.listeningWidth : metrics.capsuleWidth(wide: false)
        case .statusPanel: return status
        case .prompt: return prompt
        case .startup: return startup
        case .topics: return topics
        case .sim:
            if forcePracticeCapsule { return metrics.capsuleWidth(wide: true) }
            return state.card != nil ? max(practice, cardWidth) : practice
        case .prompter: return cardWidth + prompterExtra
        case .card: return cardWidth
        }
    }
}

// MARK: - Dots and bars

/// The live dot, 7 pt: mint while listening, a ring when nothing is happening, breathing while a call is in flight.
struct IslandDot: View {
    enum Kind { case live, idle, waiting, amber, coral }
    var kind: Kind
    @State private var breathe = false

    init(_ kind: Kind) { self.kind = kind }

    init(activity: OverlayActivity) {
        switch activity {
        case .offline, .idle: self.init(.idle)
        case .warming, .thinking: self.init(.waiting)
        case .listening: self.init(.live)
        }
    }

    var body: some View {
        Group {
            switch kind {
            case .live: Circle().fill(VT.mint)
            case .waiting: Circle().fill(VT.mint).opacity(breathe ? 1.0 : 0.35)
            case .idle: Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 1.3)
            case .amber: Circle().fill(VT.amber)
            case .coral: Circle().fill(VT.coral)
            }
        }
        .frame(width: 7, height: 7)
        .onAppear { breathe = true }
        .animation(kind == .waiting ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: breathe)
    }
}

/// Who is talking, as three short bars. Heights are the last 300 ms of level, not an animation loop.
struct LevelBars: View {
    var levels: [Double]

    var body: some View {
        let shown = (levels + [0, 0, 0]).prefix(3)
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, level in
                Capsule().fill(Color.white.opacity(0.72)).frame(width: 2, height: 3 + 9 * CGFloat(min(max(level, 0), 1)))
            }
        }
        .frame(height: 12)
    }
}

/// The two strips beside the camera. Text never enters the camera band.
struct Wings<L: View, R: View>: View {
    var width: CGFloat
    var notchWidth: CGFloat
    var height: CGFloat
    /// Inset from the straight side: 12 on capsules, 22 on cards (so the dot sits on the SAY bar's axis).
    var inset: CGFloat
    @ViewBuilder var left: L
    @ViewBuilder var right: R
    @Environment(\.islandContrast) private var contrast

    var body: some View {
        let wing = (width - notchWidth) / 2
        let pad = VT.Radius.islandShoulder + inset
        HStack(spacing: 0) {
            HStack(spacing: 7) { left }.frame(width: max(wing - pad, 0), alignment: .leading).padding(.leading, pad)
            Spacer(minLength: notchWidth)
            HStack(spacing: 6) { right }.lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: max(wing - pad, 0), alignment: .trailing).padding(.trailing, pad)
        }
        .font(VT.Font.wing)
        .foregroundStyle(contrast ? Color.white.opacity(0.85) : VT.Island.tertiary)
        .frame(width: width, height: height)
    }
}

// MARK: - Card pieces

/// The line to say: 22 semibold with the mint bar. Size scales with the text size.
struct SayLine: View {
    var text: String
    var scale: CGFloat
    var corrected = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule().fill(VT.mint).frame(width: 3).padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(VT.Font.say(scale))
                    .tracking(VT.Font.sayTracking)
                    .lineSpacing(2)
                    .foregroundStyle(VT.Island.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if corrected {
                    Label("Corrected by Sonnet", systemImage: "arrow.uturn.backward")
                        .font(VT.Font.meta)
                        .foregroundStyle(VT.Island.tertiary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// "↳ Following you": the card continues what Alex is saying; it does not answer the question.
struct FollowMark: View {
    var body: some View {
        Label("Following you", systemImage: "arrow.turn.down.right")
            .font(VT.Font.meta)
            .foregroundStyle(VT.Island.tertiary)
            .padding(.leading, 15)
            .accessibilityIdentifier("verse.followMark")
    }
}

/// Points under the SAY line. Points already said are struck through and dimmed (no animation, like all card text).
struct PointList: View {
    var points: [String]
    var scale: CGFloat
    /// The deep (Sonnet) points are a step quieter than the fast ones.
    var quiet = false
    var struck: Set<Int> = []
    @Environment(\.islandContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                let done = struck.contains(i)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(Color.white.opacity(done ? 0.25 : 0.55)).frame(width: 4.5, height: 4.5)
                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4.5 }
                    Text(p)
                        .font(VT.Font.point(scale))
                        .strikethrough(done, color: .white.opacity(0.55))
                        .foregroundStyle(color(done: done))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(done ? "\(p), said" : p)
                }
            }
        }
        .padding(.leading, 15)
    }

    private func color(done: Bool) -> Color {
        if done { return contrast ? Color.white.opacity(0.7) : VT.Island.quaternary }
        if contrast { return .white }
        return quiet ? Color.white.opacity(0.72) : VT.Island.secondary
    }
}

struct FactChip: View {
    var chip: OverlayChip
    var scale: CGFloat
    @Environment(\.islandContrast) private var contrast

    var body: some View {
        HStack(spacing: 6) {
            Text(chip.text).foregroundStyle(VT.Island.primary.opacity(0.94)).lineLimit(1).truncationMode(.tail)
            Text(chip.source).foregroundStyle(contrast ? Color.white.opacity(0.8) : VT.Island.tertiary).lineLimit(1).fixedSize()
        }
        .font(VT.Font.chip(scale))
        .padding(.horizontal, 9).frame(height: (24 * scale).rounded())
        .background(VT.Island.fill, in: RoundedRectangle(cornerRadius: VT.Radius.chip, style: .continuous))
        .overlay { if contrast { RoundedRectangle(cornerRadius: VT.Radius.chip, style: .continuous).strokeBorder(Color.white.opacity(0.5)) } }
    }
}

struct ChipRow: View {
    var chips: [OverlayChip]
    var scale: CGFloat
    var leading: CGFloat = 15

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(chips) { FactChip(chip: $0, scale: scale) }
        }
        .padding(.leading, leading)
    }
}

/// "Sonnet": a hairline between the fast points and the deep ones.
struct SonnetDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.white.opacity(0.16)).frame(width: 14, height: 0.5)
            Text("Sonnet").font(VT.Font.caption).foregroundStyle(VT.Island.tertiary)
            Rectangle().fill(.white.opacity(0.16)).frame(height: 0.5)
        }
        .padding(.leading, 15)
    }
}

/// Proposes at most `maxHeight` to its one child when nobody proposed a height (an unconstrained parent), and takes the
/// child's own size. `ViewThatFits` needs a proposal to pick the variant that fits; a plain frame would make the card
/// as tall as the proposal.
private struct ProposeHeight: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(ProposedViewSize(width: proposal.width, height: min(proposal.height ?? maxHeight, maxHeight)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

private extension View {
    func proposingHeight(_ maxHeight: CGFloat) -> some View { ProposeHeight(maxHeight: maxHeight) { self } }
}

/// The question card: hearing (the heard question), the answer, or what continues his own line.
struct CardView: View {
    var card: OverlayCard
    var scale: CGFloat
    /// Room for the body under the band. nil: as tall as the content (previews).
    var maxHeight: CGFloat?

    var body: some View {
        if let maxHeight {
            // Deep points drop first, oldest first, until the card fits; the last variant scrolls.
            ViewThatFits(in: .vertical) {
                content(dropping: 0)
                content(dropping: 1)
                content(dropping: 2)
                content(dropping: 3)
                content(dropping: 4)
                ScrollView(.vertical, showsIndicators: false) { content(dropping: card.deepPoints.count) }
                    .scrollBounceBehavior(.basedOnSize)
            }
            .proposingHeight(maxHeight)
        } else {
            content(dropping: 0)
        }
    }

    private func content(dropping n: Int) -> some View {
        let deep = Array(card.deepPoints.dropFirst(n))
        return VStack(alignment: .leading, spacing: 12) {
            if card.following, card.say != nil {
                FollowMark().padding(.bottom, -4)
            }
            if let say = card.say {
                SayLine(text: say, scale: scale, corrected: card.sayCorrected)
            } else {
                // Hearing: Verse has the question and the answer is on its way.
                Text(card.question.isEmpty ? "Listening to the question…" : "“\(card.question)”")
                    .font(.system(size: (15 * scale).rounded(), weight: .medium))
                    .foregroundStyle(VT.Island.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !card.bullets.isEmpty {
                PointList(points: card.bullets, scale: scale, struck: card.struck)
                    .padding(.top, card.following ? 0 : 0)
            }
            if !card.chips.isEmpty {
                ChipRow(chips: card.chips, scale: scale)
            }
            if !deep.isEmpty {
                SonnetDivider()
                PointList(points: deep, scale: scale, quiet: true)
            }
        }
        .padding(.horizontal, VT.islandCardInset)
        .padding(.top, card.following && card.say != nil ? 10 : 12)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { $0.animation = nil }
    }
}

// MARK: - Panels

/// A status that needs more than the wing: permission (with a System Settings button), credit, error. One sentence in
/// 15 semibold and one line of what still works.
struct StatusPanelView: View {
    var status: OverlayStatus
    var onOpenSettings: (String) -> Void
    var onDismiss: () -> Void
    /// Shown for errors when nothing is running.
    var onRetry: (() -> Void)?

    /// "Max API credit used up until 1 December. Verse keeps transcribing locally." -> the first sentence and the rest.
    static func split(_ text: String) -> (headline: String, line: String?) {
        guard let r = text.range(of: ". ") else { return (text, nil) }
        let head = String(text[..<r.lowerBound]) + "."
        let rest = text[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return (head, rest.isEmpty ? nil : rest)
    }

    private var parts: (headline: String, line: String?) {
        switch status {
        case .error(let m) where !m.isEmpty: return Self.split(m)
        case .creditExhausted(let m) where !m.isEmpty: return Self.split(m)
        default: return (status.title, status.detail)
        }
    }

    var body: some View {
        let p = parts
        VStack(alignment: .leading, spacing: 4) {
            Text(p.headline)
                .font(VT.Font.title)
                .foregroundStyle(VT.Island.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let line = p.line {
                Text(line)
                    .font(VT.Font.meta)
                    .foregroundStyle(VT.Island.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if case .permission(let kind) = status {
                    Button("Open System Settings") { onOpenSettings(kind) }.buttonStyle(OverlayButtonStyle(prominent: true))
                }
                if let onRetry {
                    Button("Retry", action: onRetry).buttonStyle(OverlayButtonStyle(prominent: true))
                }
                Button("Dismiss", action: onDismiss).buttonStyle(OverlayButtonStyle(prominent: false))
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, VT.islandCardInset)
        .padding(.top, 10)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { $0.animation = nil }
    }
}

/// The start-up panel: Starting… (with the step) → Ready · session → Listening. Stays until the first card or a click
/// on the band.
struct StartupPanelView: View {
    var panel: StartupPanel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(panel.title).font(VT.Font.title).foregroundStyle(VT.Island.primary).lineLimit(1)
            Text(panel.subtitle).font(VT.Font.meta).foregroundStyle(VT.Island.tertiary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, VT.islandCardInset)
        .padding(.top, 10)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("verse.startup")
    }
}

/// Buttons on the island: 9 pt rounded rectangles, 30 pt tall. The primary one carries the mint fill; the rest are
/// neutral fills. One primary per card.
struct OverlayButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(prominent ? VT.onMint : VT.Island.primary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(prominent ? VT.mint : VT.Island.fillStrong, in: RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous))
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

/// The resize grip at the bottom of the card. Drawn only while the pointer is over it: the card stays clean.
struct ResizeGrip: View {
    var onDrag: (CGSize) -> Void
    var onEnd: () -> Void
    @State private var hovering = false

    var body: some View {
        Capsule()
            .fill(.white.opacity(hovering ? 0.5 : 0))
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
