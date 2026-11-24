import AppKit
import Combine
import SwiftUI

/// Where a dictation is, as the recording indicator shows it (gap G5).
public enum DictationIndicatorStage: String, Sendable, Equatable {
    /// The key was pressed and the microphone is opening: no audio has arrived yet.
    case preparing
    /// Audio flows: the level, the elapsed time and the live text.
    case recording
    /// The stop press was taken: the release tail and the engine's last words.
    case finishing
}

/// What the indicator shows at one moment. Nil content means it is hidden.
public struct DictationIndicatorContent: Sendable, Equatable {
    public var stage: DictationIndicatorStage
    /// Seconds since the first audio arrived (frozen at the stop press).
    public var elapsed: TimeInterval
    /// The last three level readings, 0...1, newest last (the island's three bars).
    public var levels: [Double]
    /// The live text, already cut at the head to fit (`DictationIndicatorRules.tail`); empty when off or nothing yet.
    public var text: String
    /// "Show live text" is on: the island grows under its band for the text (up to `DictationIndicatorRules.textLines`).
    public var showsText: Bool
    /// The dictation's language code ("tr"), shown as "TR" (gap G12); empty: not shown.
    public var language: String

    public init(stage: DictationIndicatorStage, elapsed: TimeInterval = 0, levels: [Double] = [0, 0, 0], text: String = "",
                showsText: Bool = true, language: String = "") {
        self.stage = stage
        self.elapsed = elapsed
        self.levels = levels
        self.text = text
        self.showsText = showsText
        self.language = language
    }
}

/// The indicator's pure rules: when it shows, what stage, the level scale, the elapsed label and the text cut.
public enum DictationIndicatorRules {
    /// The stage for a controller phase. Idle and the paste itself show nothing: the dictation is over for the owner, and a
    /// notice ("Not inserted", "Dictation heard nothing") may follow in the same place.
    public static func stage(phase: DictationPhase, audioArrived: Bool) -> DictationIndicatorStage? {
        switch phase {
        case .idle, .inserting: return nil
        case .recording: return audioArrived ? .recording : .preparing
        case .finalising: return .finishing
        }
    }

    /// Shown only during a dictation, never while a meeting or another run holds the microphone, and only with the setting on.
    public static func isShown(stage: DictationIndicatorStage?, runActive: Bool, enabled: Bool) -> Bool {
        stage != nil && !runActive && enabled
    }

    /// RMS to 0...1 on a dB scale: -55 dBFS (a quiet room) is 0, -15 dBFS (close speech) is 1.
    public static func level(rms: Float?) -> Double {
        guard let rms, rms > 0 else { return 0 }
        let db = 20 * log10(Double(rms))
        return min(max((db + 55) / 40, 0), 1)
    }

    /// "mm:ss".
    public static func elapsedLabel(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// The newest part of `text` that `fits`, cut at the head at a word start and marked with "…", so the words being spoken
    /// are always visible. Line breaks show as spaces. A single word too long to fit is cut inside the word.
    public static func tail(_ text: String, fits: (String) -> Bool) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flat.isEmpty, !fits(flat) else { return flat }
        let chars = Array(flat)
        var starts: [Int] = []
        for i in 1..<chars.count where chars[i - 1] == " " && chars[i] != " " { starts.append(i) }
        func candidate(_ i: Int) -> String { "…" + String(chars[i...]) }
        // The longest suffix that fits: the smallest start, by binary search (a later start is shorter).
        func search(_ positions: [Int]) -> Int? {
            var lo = 0, hi = positions.count - 1, found: Int?
            while lo <= hi {
                let mid = (lo + hi) / 2
                if fits(candidate(positions[mid])) { found = positions[mid]; hi = mid - 1 } else { lo = mid + 1 }
            }
            return found
        }
        if let i = search(starts) { return candidate(i) }
        let from = starts.last ?? 1
        if let i = search(Array(from..<chars.count)) { return candidate(i) }
        return "…"
    }

    /// `tail` with a character budget (tests, and a fallback).
    public static func tail(_ text: String, maxCharacters: Int) -> String {
        tail(text) { $0.count <= maxCharacters }
    }

    /// The live text's column: the island's panel width (`DictationIslandView.bodyWidth`) less the card's side insets.
    static var textWidth: CGFloat { DictationIslandView.bodyWidth - 2 * VT.islandCardInset }
    /// The live text shows at most this many lines; older lines drop off at the head.
    public static let textLines = 3
    /// The live text's font, as AppKit measures it: the card's point type (`VT.Font.point()`, 15 regular) at text size M.
    static var textFont: NSFont { NSFont.systemFont(ofSize: 15) }
    /// The text font's line height, measured once (the font is fixed).
    private static let textLineHeight: CGFloat = NSLayoutManager().defaultLineHeight(for: textFont)

    /// Whether `text` fits in `lines` lines of `width` points in the live text's font.
    static func fits(_ text: String, width: CGFloat, lines: Int) -> Bool {
        let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: textFont])
        return rect.height <= textLineHeight * CGFloat(lines) + 0.5
    }

    /// The app's text cut: what fits in the island's `textLines` lines (a few points narrower than drawn, for safety).
    static func measuredTail(_ text: String) -> String {
        tail(text) { fits($0, width: textWidth - 6, lines: textLines) }
    }

    /// The user's Island opacity (Settings > Island opacity), read from the app's defaults the way `AppSettings` stores
    /// it, so the dictation island's veil matches the meeting island's.
    @MainActor static func islandOpacity(in defaults: UserDefaults?) -> Double {
        let stored = defaults?.object(forKey: "islandOpacity") as? Double ?? 0.62
        return min(max(stored, AppSettings.islandOpacityRange.lowerBound), AppSettings.islandOpacityRange.upperBound)
    }

    /// The defaults `AppSettings` uses: the standard ones inside the bundle, else its suite.
    @MainActor static var appDefaults: UserDefaults? {
        Bundle.main.bundleIdentifier == AppSettings.suiteName ? .standard : UserDefaults(suiteName: AppSettings.suiteName)
    }
}

/// The recording indicator's state (gap G5): fed the controller's phase, the current transcriber and whether a run is active,
/// it reads the microphone level, the first audio and the live text about 25 times a second while shown, and publishes what to
/// draw. The ticker runs only while it is shown.
@MainActor
public final class DictationIndicatorModel: ObservableObject {
    public static let tickInterval: TimeInterval = 1.0 / 25

    @Published public private(set) var content: DictationIndicatorContent?
    /// The current dictation's language (gap G12), set by the controller before the dictation starts.
    public var language = ""

    private let ticker: DictationController.Ticker
    private let now: @MainActor () -> TimeInterval
    private let fitText: (String) -> String
    private var subs: Set<AnyCancellable> = []
    private var tick: AnyCancellable?

    private var enabled: Bool
    private var liveTextOn: Bool
    private var phase: DictationPhase = .idle
    private var runActive = false
    private weak var source: (any DictationTranscribing)?
    private var audioArrived = false
    private var recordingSince: TimeInterval?
    private var frozenElapsed: TimeInterval?
    private var levels: [Double] = [0, 0, 0]
    private var rawText = ""
    private var fittedText = ""

    public init(settings: DictationSettings, ticker: @escaping DictationController.Ticker,
                now: @escaping @MainActor () -> TimeInterval, fitText: ((String) -> String)? = nil) {
        self.ticker = ticker
        self.now = now
        self.fitText = fitText ?? DictationIndicatorRules.measuredTail
        enabled = settings.showIndicator
        liveTextOn = settings.indicatorLiveText
        // `$x` delivers the new value before the property changes: use the delivered one.
        settings.$showIndicator.dropFirst().removeDuplicates().sink { [weak self] on in
            MainActor.assumeIsolated { self?.enabled = on; self?.refresh() }
        }.store(in: &subs)
        settings.$indicatorLiveText.dropFirst().removeDuplicates().sink { [weak self] on in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.liveTextOn = on
                self.rawText = ""
                self.fittedText = ""
                self.refresh()
            }
        }.store(in: &subs)
    }

    /// The controller's phase changed, or a run started or ended.
    public func update(phase newPhase: DictationPhase, source: (any DictationTranscribing)?, runActive: Bool) {
        if newPhase == .recording && phase != .recording {
            audioArrived = false
            recordingSince = nil
            frozenElapsed = nil
            levels = [0, 0, 0]
            rawText = ""
            fittedText = ""
        }
        if newPhase == .finalising && phase == .recording {
            frozenElapsed = recordingSince.map { now() - $0 } ?? 0
            levels = [0, 0, 0]
        }
        phase = newPhase
        self.source = (newPhase == .recording || newPhase == .finalising) ? source : nil
        self.runActive = runActive
        if source != nil { step() } else { refresh() }
    }

    /// One reading: first audio, level, live text. The ticker calls it while the indicator is shown.
    func step() {
        if let s = source {
            if !audioArrived, s.inputLevel.chunks > 0 {
                audioArrived = true
                recordingSince = now()
            }
            if phase == .recording, audioArrived {
                levels = Array((levels + [DictationIndicatorRules.level(rms: s.takeMeterLevel())]).suffix(3))
            }
            if liveTextOn {
                let raw = s.liveText
                if raw != rawText {
                    rawText = raw
                    fittedText = fitText(raw)
                }
            }
        }
        refresh()
    }

    private func refresh() {
        let stage = DictationIndicatorRules.stage(phase: phase, audioArrived: audioArrived)
        guard let stage, DictationIndicatorRules.isShown(stage: stage, runActive: runActive, enabled: enabled) else {
            tick?.cancel()
            tick = nil
            if content != nil { content = nil }
            return
        }
        if tick == nil {
            tick = ticker(Self.tickInterval) { [weak self] in self?.step() }
        }
        let elapsed = frozenElapsed ?? recordingSince.map { now() - $0 } ?? 0
        let next = DictationIndicatorContent(stage: stage, elapsed: elapsed, levels: levels,
                                             text: liveTextOn ? fittedText : "", showsText: liveTextOn, language: language)
        if next != content { content = next }
    }
}


// MARK: - Notices in the island

public extension DictationNotice {
    /// Shown in the dictation island, under the notch. The two notices that come while a meeting or another run holds the
    /// notch ("Dictation is off while Verse is listening", "Dictation stopped: Verse started listening") stay in the
    /// free-standing notice panel (`DictationHUD`): the meeting island owns the notch then.
    var showsInIsland: Bool {
        switch self {
        case .busy, .cancelledByRun: return false
        default: return true
        }
    }

    /// A failure (coral dot); every other notice is a caution (amber), as the meeting island's status panels.
    internal var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - View

/// The dictation island: the meeting island's surface and type, hanging from the notch the way the island does during a
/// call. The band beside the camera carries the wings (left: the dot and, while recording, the level bars; right: the
/// language code and the elapsed time); under it, with live text on, the island grows downward for the words being
/// recognised, in the answer card's point type, newest last (at most `DictationIndicatorRules.textLines` lines, the oldest
/// dropping off at the head). Preparing, finishing and the notices use the island's status type. With live text off and no
/// notice it is the band alone, a listening capsule.
struct DictationIslandView: View {
    var content: DictationIndicatorContent?
    /// A notice in the island (`DictationNotice.showsInIsland`): it takes the body's place.
    var notice: DictationNotice? = nil
    var metrics: NotchMetrics = .macBookPro
    /// The veil's floor before the accessibility rules (`IslandVeil.floor`): the user's Island opacity.
    var islandOpacity: Double = 0.62

    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.islandA11yOverride) private var a11yOverride

    /// The island's width when it has a body under the band: the island's panel width (status, start-up).
    static var bodyWidth: CGFloat { IslandWidth.status }

    /// Whether anything shows under the band.
    static func hasBody(content: DictationIndicatorContent?, notice: DictationNotice?) -> Bool {
        notice != nil || content?.showsText == true
    }

    /// The whole silhouette's width: the panel width with a body, else the listening capsule, widened by the island's own
    /// rule when the right wing's text needs it.
    static func width(content: DictationIndicatorContent?, notice: DictationNotice?, metrics: NotchMetrics) -> CGFloat {
        hasBody(content: content, notice: notice) ? bodyWidth : IslandWidth.listeningWidth(wingText: wingSample(content), metrics: metrics)
    }

    /// The right wing's widest text for `content`: the language code and "mm:ss" (the digits are monospaced, so any time
    /// measures the same); two spaces stand for the wing's 6 pt spacing.
    static func wingSample(_ content: DictationIndicatorContent?) -> String? {
        guard let content else { return nil }
        var parts: [String] = []
        if !content.language.isEmpty { parts.append(DictationLanguageChoice.shortCode(content.language)) }
        if content.stage != .preparing { parts.append(DictationIndicatorRules.elapsedLabel(0)) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    private var a11y: IslandA11y {
        a11yOverride ?? IslandA11y(reduceTransparency: systemReduceTransparency, increaseContrast: systemContrast == .increased)
    }

    var body: some View {
        let a = a11y
        let w = Self.width(content: content, notice: notice, metrics: metrics)
        VStack(spacing: 0) {
            Wings(width: w, notchWidth: metrics.notchWidth, height: metrics.capsuleHeight, inset: IslandBand.wingInset(width: w)) {
                leftWing
            } right: {
                rightWing
            }
            bodyView(a)
        }
        .frame(width: w, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(alignment: .top) { IslandSurface(bandHeight: metrics.capsuleHeight, userOpacity: islandOpacity, a11y: a) }
        .environment(\.colorScheme, .dark)
        .environment(\.islandContrast, a.increaseContrast)
        .interfaceLocale()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var leftWing: some View {
        if let content {
            switch content.stage {
            case .preparing: IslandDot(.idle)
            case .recording:
                IslandDot(.live)
                LevelBars(levels: content.levels)
            case .finishing: IslandDot(.waiting)
            }
        } else if let notice {
            IslandDot(notice.isFailure ? .coral : .amber)
        }
    }

    @ViewBuilder private var rightWing: some View {
        if let content {
            if !content.language.isEmpty {
                Text(verbatim: DictationLanguageChoice.shortCode(content.language))
            }
            if content.stage != .preparing {
                Text(verbatim: DictationIndicatorRules.elapsedLabel(content.elapsed)).monospacedDigit()
            }
        }
    }

    /// Everything under the band. The dictation's own bodies keep the card's insets, so the island does not jump by the
    /// panels' 2 pt when the stage changes; a notice is a status panel.
    @ViewBuilder private func bodyView(_ a: IslandA11y) -> some View {
        if let notice {
            let parts = StatusPanelView.split(notice.text)
            IslandStatusLines(headline: parts.headline, line: parts.line).islandBody(.panel)
        } else if let content, content.showsText {
            switch content.stage {
            case .preparing:
                IslandStatusLines(headline: L10n.tr("Preparing microphone…")).islandBody(.card)
            case .finishing:
                IslandStatusLines(headline: L10n.tr("Finishing…")).islandBody(.card)
            case .recording where content.text.isEmpty:
                CardHearingLine(text: L10n.tr("Listening…")).islandBody(.card)
            case .recording:
                // The card's points: point type, secondary (white under Increase Contrast), the points' line spacing.
                Text(verbatim: content.text)
                    .font(VT.Font.point())
                    .foregroundStyle(a.increaseContrast ? Color.white : VT.Island.secondary)
                    .lineSpacing(PointList.lineSpacing)
                    .lineLimit(DictationIndicatorRules.textLines)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
                    .islandBody(.card)
            }
        }
    }
}

// MARK: - Panel

/// The dictation island's window, placed as the meeting island's (`NotchPanelController`): a borderless panel that never
/// becomes key or main (`OverlayPanel`), above the menu bar, on every Space and over full-screen apps, outside the window
/// cycle; on the screen with the notch (else the main screen, with a notch-sized island at the top centre), centred on
/// the notch, its top edge the screen's, exactly the surface's size. Unlike the meeting island it ignores the mouse.
/// It shows while the indicator model has content or a notice is up, and is made on first show and reused. During a run
/// the meeting island owns the notch alone: the model hides, and a run that starts drops a notice. The meeting island can
/// also be up with no run (a meeting prompt, an offline or error status); then this island hangs just below it
/// (`frame(island:avoiding:)`), never on top of it, so a click meant for the prompt is never hidden under a window that
/// ignores the mouse.
@MainActor
final class DictationIndicatorPanel {
    private let model: DictationIndicatorModel
    private var panel: OverlayPanel?
    private var host: NSHostingView<DictationIslandView>?
    /// The user's Island opacity, read when the island goes from hidden to shown (not while it stays up).
    private var islandOpacity = 0.62
    private var sub: AnyCancellable?
    private var runSub: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    /// The meeting island's frame while it is on screen (`NotchPanelController.visibleFrame`); nil: not shown, or not wired.
    var meetingIsland: (@MainActor () -> NSRect?)?
    private var screen: NSScreen?
    private var metrics = NotchMetrics.macBookPro
    /// The model's content as last delivered (`$content` delivers before the property changes).
    private var content: DictationIndicatorContent?
    private var notice: DictationNotice?
    private var noticeTask: Task<Void, Never>?
    private var lastLayout: Layout?
    /// The notice HUD places itself below the island; it hears of every move.
    var onFrameChange: (() -> Void)?

    /// What takes room: the level and the seconds do not. The meeting island's frame moves this one.
    private struct Layout: Equatable {
        var content: DictationIndicatorContent?
        var notice: DictationNotice?
        var meeting: NSRect?
    }

    /// The space between the meeting island and this one when it hangs below it.
    nonisolated static let meetingGap: CGFloat = 6

    /// `island` (the frame hanging from the notch) moved straight down to just below `meeting` when the two would overlap;
    /// else `island` unchanged (no meeting island, or one on another screen).
    nonisolated static func frame(island: NSRect, avoiding meeting: NSRect?) -> NSRect {
        guard let meeting, meeting.intersects(island) else { return island }
        var f = island
        f.origin.y = meeting.minY - meetingGap - f.height
        return f
    }

    /// The panel's frame while it is on screen.
    var visibleFrame: NSRect? { panel?.isVisible == true ? panel?.frame : nil }

    init(model: DictationIndicatorModel) {
        self.model = model
        content = model.content
        sub = model.$content.sink { [weak self] c in
            MainActor.assumeIsolated {
                self?.content = c
                self?.render()
            }
        }
        // A display change (a lid closed, a monitor plugged in) while the island is up: hang it from the new notch. The
        // panel lives as long as the controller (the app); the block holds it weakly.
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenChanged() }
        }
    }

    /// The meeting island appeared, moved, grew or went: place this island again if it is up.
    func meetingIslandChanged() {
        guard panel?.isVisible == true else { return }
        render()
    }

    private func screenChanged() {
        guard panel?.isVisible == true else { return }
        takeScreen()
        lastLayout = nil
        render()
    }

    private func takeScreen() {
        let s = NotchPanelController.notchScreen()
        screen = s
        metrics = NotchPanelController.metrics(for: s)
    }

    /// Shows `notice` in the island for `duration`, under the band (in place of the live text while a dictation is shown).
    func show(_ notice: DictationNotice, for duration: Duration) {
        self.notice = notice
        render()
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.clearNotice()
        }
    }

    func clearNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        guard notice != nil else { return }
        notice = nil
        render()
    }

    /// A run that starts takes the notch: a notice still up goes at once.
    func observeRuns<P: Publisher>(_ runs: P) where P.Output == Bool, P.Failure == Never {
        runSub = runs.sink { [weak self] on in
            MainActor.assumeIsolated { if on { self?.clearNotice() } }
        }
    }

    private func render() {
        guard content != nil || notice != nil else {
            if panel?.isVisible == true {
                panel?.orderOut(nil)
                onFrameChange?()
            }
            lastLayout = nil
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let wasVisible = panel.isVisible
        if !wasVisible {
            takeScreen()
            islandOpacity = DictationIndicatorRules.islandOpacity(in: DictationIndicatorRules.appDefaults)
        }
        let view = DictationIslandView(content: content, notice: notice, metrics: metrics, islandOpacity: islandOpacity)
        let host: NSHostingView<DictationIslandView>
        if let h = self.host {
            h.rootView = view
            host = h
        } else {
            host = NSHostingView(rootView: view)
            panel.contentView = host
            self.host = host
        }
        let meeting = meetingIsland?()
        var layout = Layout(content: content, notice: notice, meeting: meeting)
        layout.content?.levels = []
        layout.content?.elapsed = 0
        guard layout != lastLayout || !wasVisible else { return }
        lastLayout = layout
        if let s = screen {
            let hanging = NotchPanelController.islandFrame(contentSize: host.fittingSize, screenFrame: s.frame,
                                                           centerX: NotchPanelController.notchCenterX(on: s), metrics: metrics)
            let frame = Self.frame(island: hanging, avoiding: meeting)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
        }
        if !wasVisible { panel.orderFrontRegardless() }
        onFrameChange?()
    }

    private func makePanel() -> OverlayPanel {
        let p = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: true)
        p.isFloatingPanel = true
        // The meeting island's level: above the menu bar, so the silhouette hangs from the screen's top edge.
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        // As the notch: no window shadow; the glass's rim lies inside the silhouette.
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.isExcludedFromWindowsMenu = true
        p.animationBehavior = .none
        p.becomesKeyOnlyIfNeeded = true
        return p
    }
}
