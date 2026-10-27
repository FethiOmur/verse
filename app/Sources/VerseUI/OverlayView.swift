import SwiftUI

/// Visual constants of the overlay that other files still name. The design lives in `VT` (DesignTokens.swift).
public enum OverlayStyle {
    /// The single accent (lime A), used for the live dot and the primary action.
    public static let accent = VT.mint
    /// The morph between island sizes (spec 3.3: ease-out 140 ms, no spring).
    static let morph = VT.morph
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

    /// Idle capsule 266 (40 pt of wing each side), practice capsule 442 (128 pt) on a 186 pt notch.
    public func capsuleWidth(wide: Bool) -> CGFloat { notchWidth + 2 * (wide ? 128 : 40) }
    /// Listening capsule: 354 pt on a 186 pt notch (84 pt of wing each side, room for the level bars and a name).
    public var listeningWidth: CGFloat { notchWidth + 2 * 84 }
}

/// What the practice states need to know about the teleprompter in the band.
struct PrompterBandInfo: Equatable {
    var speaking: Bool
    var mode: String
    var page: Int
    var pages: Int
}

/// The band: the strip beside the camera. Wings only; text never enters the camera band.
struct IslandBand: View {
    var state: OverlayState
    var kind: IslandKind
    var metrics: NotchMetrics
    var width: CGFloat
    var prompter: PrompterBandInfo?
    /// The Stop button in the right wing while the pointer is over a bare capsule of a running session.
    var onStop: (() -> Void)?
    var stopping = false
    @Environment(\.islandHover) private var hover

    var body: some View {
        Wings(width: width, notchWidth: metrics.notchWidth, height: metrics.capsuleHeight, inset: width > 420 ? 22 : 12) {
            leftWing
        } right: {
            rightWing
        }
    }

    private var busyDot: IslandDot.Kind {
        switch state.activity {
        case .warming, .thinking: return .waiting
        default: return .live
        }
    }

    @ViewBuilder private var leftWing: some View {
        switch kind {
        case .capsule:
            if state.status != nil {
                IslandDot(activity: state.status == .offline ? .offline : state.activity)
            } else if state.remoteSpeaking {
                IslandDot(.live)
                LevelBars(levels: state.remoteBars)
            } else if state.activity == .listening, state.addresseeTag == nil {
                IslandDot(.idle)
            } else {
                IslandDot(activity: state.activity)
            }
        case .statusPanel(let s):
            IslandDot(Self.statusDot(s))
        case .prompt(let p):
            IslandDot(p.busy ? .waiting : .idle)
        case .sim(let sim):
            if sim.qTotal > 0 {
                Text("Q\(sim.qIndex) of \(sim.qTotal)", bundle: .module).foregroundStyle(VT.Island.secondary)
            } else {
                Text("Practice", bundle: .module).foregroundStyle(VT.Island.secondary)
            }
            SimTimer(start: sim.startedAt)
        case .prompter:
            IslandDot(prompter?.speaking == true ? .live : .idle)
            Text(prompter?.mode ?? "")
        case .startup(let p):
            switch p.phase {
            case .starting: IslandDot(.waiting)
            case .ready: IslandDot(.idle)
            case .listening: IslandDot(.live)
            }
        case .topics:
            IslandDot(activity: state.activity)
        case .card(let c):
            IslandDot(busyDot)
            if c.say == nil {
                LevelBars(levels: state.remoteBars)
            } else if c.following {
                LevelBars(levels: state.meBars)
            }
        }
    }

    @ViewBuilder private var rightWing: some View {
        switch kind {
        case .capsule where hover && state.running && onStop != nil:
            IslandStopButton(stopping: stopping, compact: true) { onStop?() }
        case .capsule:
            if let s = state.status {
                Text(s.shortTitle).foregroundStyle(VT.Island.secondary)
            } else if let cue = state.timeCue {
                TimeCueText(cue: cue)
            } else if let tag = state.addresseeTag {
                Text(tag).foregroundStyle(state.tagDimmed ? VT.Island.tertiary : VT.Island.secondary)
            } else if state.unprepared, state.running, width >= metrics.listeningWidth {
                Text("Unprepared", bundle: .module).foregroundStyle(VT.Island.tertiary)
            }
        case .statusPanel(let s):
            Text(s.shortTitle)
        case .startup:
            if state.unprepared { Text("Unprepared", bundle: .module).foregroundStyle(VT.Island.tertiary) }
        case .prompt, .topics:
            EmptyView()
        case .sim(let sim):
            if sim.closing {
                Text("report", bundle: .module).foregroundStyle(VT.Island.secondary)
                IslandDot(.waiting)
            } else if sim.listening || (!sim.coach.isEmpty && !sim.speaking) {
                Text("your turn", bundle: .module).foregroundStyle(VT.Island.secondary)
                IslandDot(.live)
            } else if sim.speaking {
                Text("interviewer", bundle: .module).foregroundStyle(VT.Island.secondary)
                IslandDot(.idle)
            } else {
                Text("thinking", bundle: .module).foregroundStyle(VT.Island.secondary)
                IslandDot(.waiting)
            }
        case .prompter:
            if let p = prompter { Text(verbatim: "\(p.page) / \(p.pages)").monospacedDigit() }
        case .card where state.timeCue != nil:
            TimeCueText(cue: state.timeCue ?? .soon)
        case .card(let c):
            Text(verbatim: c.following && c.say != nil ? L10n.tr("your answer") : (state.addresseeTag ?? L10n.tr("for you")))
                .foregroundStyle(state.tagDimmed ? VT.Island.tertiary : VT.Island.secondary)
        }
    }

    static func statusDot(_ s: OverlayStatus) -> IslandDot.Kind {
        if case .error = s { return .coral }
        return .amber
    }
}

/// The calm time cue in the right wing: the last minute of the call's walkthrough, then the end of it.
struct TimeCueText: View {
    var cue: TimeCue

    var body: some View {
        switch cue {
        case .soon: Text("1 min left", bundle: .module).foregroundStyle(VT.Island.secondary)
        case .now: Text("wrap up", bundle: .module).foregroundStyle(VT.amber)
        }
    }
}

/// The compact band alone (the capsule states, and the band above a panel). `width` defaults to the capsule's.
struct CapsuleView: View {
    var state: OverlayState
    var metrics: NotchMetrics
    var width: CGFloat?

    var body: some View {
        let kind = IslandKind.resolve(state, prompterOpen: false)
        let w = width ?? IslandWidth.width(kind: kind, state: state, metrics: metrics, cardWidth: 600)
        IslandBand(state: state, kind: kind, metrics: metrics, width: w, prompter: nil)
            .transaction { $0.animation = nil }
    }
}

/// Everything under the notch, as one surface: the black band around the notch with the wings, and the card, status
/// message, prompt or teleprompter below it. The glass is a single hanging silhouette that grows out of the notch
/// (Moonglade's shape and glass, see `HangingNotchGeometry` and `NotchGlass`, with the spec 2.4 veil on top); only that
/// surface animates. Text is laid out at its final place and full opacity at once, never animated.
public struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @ObservedObject var settings: AppSettings
    /// T-UI: the teleprompter shown under the band while it is open.
    @ObservedObject var prompter: PrompterModel
    var metrics: NotchMetrics
    var onOpenSettings: (String) -> Void
    var onRetry: () -> Void
    var onSizeChange: (CGSize) -> Void
    /// Renderer only: the practice states drawn as the bare capsule (spec 3.2, state 6).
    var forcePracticeCapsule = false

    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.islandA11yOverride) private var a11yOverride
    @Environment(\.islandHoverOverride) private var hoverOverride

    @State private var dragStart: (width: Double, height: Double)?
    /// The size the glass shows now; it follows `target` with the morph.
    @State private var surface: CGSize = .zero
    /// The content's own size.
    @State private var target: CGSize = .zero
    /// Reduce Motion: the surface fades in at its new size instead of morphing.
    @State private var fade = 1.0
    /// The pointer is over the island: the control rows show.
    @State private var hovering = false

    public init(model: OverlayModel, settings: AppSettings, prompter: PrompterModel = PrompterModel(), metrics: NotchMetrics,
                onOpenSettings: @escaping (String) -> Void = { _ in }, onRetry: @escaping () -> Void = {},
                onSizeChange: @escaping (CGSize) -> Void = { _ in }) {
        self.model = model
        self.settings = settings
        self.prompter = prompter
        self.metrics = metrics
        self.onOpenSettings = onOpenSettings
        self.onRetry = onRetry
        self.onSizeChange = onSizeChange
    }

    init(model: OverlayModel, settings: AppSettings, prompter: PrompterModel, metrics: NotchMetrics, forcePracticeCapsule: Bool) {
        self.init(model: model, settings: settings, prompter: prompter, metrics: metrics)
        self.forcePracticeCapsule = forcePracticeCapsule
    }

    private var state: OverlayState { model.state }
    private var scale: CGFloat { settings.textScale.factor }
    private var kind: IslandKind { IslandKind.resolve(state, prompterOpen: prompter.isOpen) }
    private var cardWidth: CGFloat { CGFloat(settings.cardWidth) }
    private var width: CGFloat {
        IslandWidth.width(kind: kind, state: state, metrics: metrics, cardWidth: cardWidth, forcePracticeCapsule: forcePracticeCapsule)
    }
    private var a11y: IslandA11y {
        a11yOverride ?? IslandA11y(reduceTransparency: systemReduceTransparency, increaseContrast: systemContrast == .increased,
                                   reduceMotion: systemReduceMotion)
    }
    /// A card never grows past 420 pt (spec 3.2); the user's height setting can only lower that.
    private var maxIslandHeight: CGFloat { min(CGFloat(settings.cardMaxHeight), 420) }

    /// The size the surface has before the first measurement: the idle capsule.
    private var compactSize: CGSize { CGSize(width: metrics.capsuleWidth(wide: false), height: metrics.capsuleHeight) }

    public var body: some View {
        let shown = surface == .zero ? compactSize : surface
        let a = a11y
        ZStack(alignment: .top) {
            ZStack {
                if !a.reduceTransparency { NotchGlassBackdrop() }
                IslandVeilView(bandHeight: metrics.capsuleHeight,
                               floor: IslandVeil.floor(userOpacity: settings.islandOpacity, reduceTransparency: a.reduceTransparency,
                                                       increaseContrast: a.increaseContrast),
                               reduceTransparency: a.reduceTransparency, increaseContrast: a.increaseContrast)
            }
            .frame(width: shown.width, height: shown.height)
            .opacity(a.reduceMotion ? fade : 1)

            content
                .fixedSize(horizontal: false, vertical: true)
                .transaction { $0.animation = nil }
                .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { surfaceTargetChanged($0, reduceMotion: a.reduceMotion) })
        }
        .frame(width: max(shown.width, target.width), height: max(shown.height, target.height), alignment: .top)
        .environment(\.colorScheme, .dark)
        .environment(\.islandContrast, a.increaseContrast)
        .frame(maxWidth: .infinity, alignment: .top)
        .interfaceLocale()
    }

    private var prompterInfo: PrompterBandInfo {
        let s = prompter.state
        return PrompterBandInfo(speaking: s.isSpeaking, mode: s.mode.wingName, page: s.pageIndex + 1, pages: s.pageCount)
    }

    /// The band (wings) and, under it, whatever is open. The band keeps the camera gap at the island's centre, so the
    /// dot and the tags do not move when the surface grows.
    private var content: some View {
        VStack(spacing: 0) {
            IslandBand(state: state, kind: kind, metrics: metrics, width: width, prompter: prompterInfo,
                       onStop: { model.stopSession() }, stopping: model.stopping)
                .contentShape(Rectangle())
                // Click the band: close the card (or the start-up panel). The panel never becomes key, so Esc can't
                // reach it; the click is the dismiss.
                .onTapGesture { model.collapse() }
            bodyView
        }
        .frame(width: width, alignment: .top)
        .contentShape(HangingNotchShape())
        .onHover { hovering = $0 }
        .environment(\.islandHover, hoverOverride ?? hovering)
    }

    @ViewBuilder private var bodyView: some View {
        switch kind {
        case .capsule:
            EmptyView()
        case .statusPanel(let s):
            let canRetry: Bool = { if case .error = s { return !state.running && !state.practiceEnded }; return false }()
            StatusPanelView(status: s, onOpenSettings: onOpenSettings, onDismiss: { model.dismissStatus() }, onRetry: canRetry ? onRetry : nil,
                            onOpenMe: { HomeRouter.shared.show(.me) })
        case .prompt(let prompt):
            // "Meeting detected · Start Verse?" / "Save summary to vault?": a question with two buttons.
            MeetingPromptView(prompt: prompt, onAction: { model.promptAction($0) })
        case .sim(let sim):
            if !forcePracticeCapsule {
                // Practice interview: the sim panel, and under it the hint card when hints are on.
                VStack(spacing: 0) {
                    SimPanelView(sim: sim, scale: scale, onAction: { model.simAction($0) })
                    if let card = state.card {
                        Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5).padding(.horizontal, VT.islandCardInset)
                        LiveCardView(card: card, scale: scale, maxHeight: max(maxIslandHeight * 0.6, 120), reading: prompter.cardReading)
                    }
                }
            }
        case .prompter:
            // The teleprompter takes the card's place (a status message or a practice interview still comes first).
            PrompterPanelView(model: prompter, settings: prompter.settings, width: width, scale: scale)
        case .startup(let p):
            StartupPanelView(panel: p, onAction: { model.startChipAction($0) })
        case .topics:
            ChipRow(chips: state.topics, scale: scale, leading: 15)
                .padding(.horizontal, VT.islandCardInset)
                .padding(.top, 8)
                .padding(.bottom, 20)
                .frame(width: width, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { model.collapse() }   // a click on the row clears the topic hints
                .overlay(alignment: .bottomTrailing) { stopRow }
        case .card(let card):
            LiveCardView(card: card, scale: scale, maxHeight: max(maxIslandHeight - metrics.capsuleHeight, 120), reading: prompter.cardReading)
                .overlay(alignment: .bottom) {
                    ResizeGrip(onDrag: resize, onEnd: { dragStart = nil })
                }
                .overlay(alignment: .bottomTrailing) { stopRow }
        }
    }

    /// Stop, in the hover control row at the bottom right of the card (the prompter and practice rows work the same way:
    /// the panel never becomes key, `acceptsFirstMouse` lets the first click through).
    @ViewBuilder private var stopRow: some View {
        if state.running {
            HoverControls(horizontalInset: VT.islandCardInset - 12) {
                IslandStopButton(stopping: model.stopping) { model.stopSession() }
            }
        }
    }

    private func surfaceTargetChanged(_ size: CGSize, reduceMotion: Bool) {
        target = size
        onSizeChange(size)
        if surface == .zero {
            surface = size
        } else if reduceMotion {
            // No size morph: the new size is in place at once and fades in over 150 ms.
            var t = Transaction(animation: nil)
            t.disablesAnimations = true
            withTransaction(t) { surface = size; fade = 0.25 }
            withAnimation(.easeInOut(duration: 0.15)) { fade = 1 }
        } else {
            withAnimation(VT.morph) { surface = size }
        }
    }

    private func resize(_ t: CGSize) {
        if dragStart == nil { dragStart = (settings.cardWidth, settings.cardMaxHeight) }
        guard let s = dragStart else { return }
        settings.cardWidth = (s.width + 2 * Double(t.width)).clamped(to: AppSettings.cardWidthRange)
        settings.cardMaxHeight = (s.height + Double(t.height)).clamped(to: AppSettings.cardMaxHeightRange)
    }
}
