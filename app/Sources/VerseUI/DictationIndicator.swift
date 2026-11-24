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
    /// "Show live text" is on: the wide layout with room for two lines.
    public var showsText: Bool

    public init(stage: DictationIndicatorStage, elapsed: TimeInterval = 0, levels: [Double] = [0, 0, 0], text: String = "",
                showsText: Bool = true) {
        self.stage = stage
        self.elapsed = elapsed
        self.levels = levels
        self.text = text
        self.showsText = showsText
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

    /// The text column of the indicator's wide layout (live text on).
    public static let textWidth: CGFloat = 282
    /// The indicator's text font: 13 pt medium, the island's card lead.
    static var textFont: NSFont { NSFont.systemFont(ofSize: 13, weight: .medium) }
    /// The text font's line height, measured once (the font is fixed).
    private static let textLineHeight: CGFloat = NSLayoutManager().defaultLineHeight(for: textFont)

    /// Whether `text` fits in `lines` lines of `width` points in the indicator's text font.
    static func fits(_ text: String, width: CGFloat, lines: Int) -> Bool {
        let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: textFont])
        return rect.height <= textLineHeight * CGFloat(lines) + 0.5
    }

    /// The app's text cut: what fits in the indicator's two lines (a few points narrower than drawn, for safety).
    static func measuredTail(_ text: String) -> String {
        tail(text) { fits($0, width: textWidth - 6, lines: 2) }
    }
}

/// The recording indicator's state (gap G5): fed the controller's phase, the current transcriber and whether a run is active,
/// it reads the microphone level, the first audio and the live text about 25 times a second while shown, and publishes what to
/// draw. The ticker runs only while it is shown.
@MainActor
public final class DictationIndicatorModel: ObservableObject {
    public static let tickInterval: TimeInterval = 1.0 / 25

    @Published public private(set) var content: DictationIndicatorContent?

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
                                             text: liveTextOn ? fittedText : "", showsText: liveTextOn)
        if next != content { content = next }
    }
}

// MARK: - View

/// The indicator: a compact dark capsule in the island's colours and type. Level bars and a mint dot while recording, the
/// elapsed time, and the last two lines of what has been recognised (cut at the head), or the stage's label.
struct DictationIndicatorView: View {
    var content: DictationIndicatorContent

    /// The wide layout (live text on).
    static let width: CGFloat = 400
    static var textWidth: CGFloat { DictationIndicatorRules.textWidth }

    private var label: String? {
        switch content.stage {
        case .preparing: return L10n.tr("Preparing microphone…")
        case .finishing: return L10n.tr("Finishing…")
        case .recording: return content.showsText && !content.text.isEmpty ? nil : L10n.tr("Listening…")
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 6) {
                dot
                if content.stage == .recording { LevelBars(levels: content.levels) }
            }
            .frame(width: 23, alignment: .leading)
            Group {
                if let label {
                    Text(verbatim: label).foregroundStyle(VT.Island.tertiary).lineLimit(1)
                } else {
                    Text(verbatim: content.text).foregroundStyle(VT.Island.primary)
                        .lineLimit(2).truncationMode(.head).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(Font(DictationIndicatorRules.textFont))
            .frame(width: content.showsText ? Self.textWidth : nil, alignment: .leading)
            if content.stage != .preparing {
                Text(verbatim: DictationIndicatorRules.elapsedLabel(content.elapsed))
                    .font(VT.Font.meta.monospacedDigit())
                    .foregroundStyle(VT.Island.tertiary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .padding(.vertical, 9)
        .frame(minHeight: 34)
        .frame(width: content.showsText ? Self.width : nil, alignment: .leading)
        .background(VT.islandSolid, in: RoundedRectangle(cornerRadius: VT.Radius.islandBottom, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VT.Radius.islandBottom, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var dot: some View {
        switch content.stage {
        case .preparing: IslandDot(.idle)
        case .recording: IslandDot(.live)
        case .finishing: Circle().fill(VT.Island.quaternary).frame(width: 7, height: 7)
        }
    }
}

// MARK: - Panel

/// The indicator's window: a borderless panel that never becomes key or main (`OverlayPanel`), ignores the mouse, joins every
/// Space, stays out of the window cycle, and sits top centre just under the menu bar (and the notch, which the menu bar
/// covers) with a gap that clears the island's band. Made on first show and reused.
@MainActor
final class DictationIndicatorPanel {
    /// Below the top of the visible frame (the menu bar's bottom edge). The island's band reaches 6 pt below the menu bar.
    static let topGap: CGFloat = 10

    private let model: DictationIndicatorModel
    private var panel: OverlayPanel?
    private var host: NSHostingView<DictationIndicatorView>?
    private var sub: AnyCancellable?
    private var screen: NSScreen?
    private var lastLayout: DictationIndicatorContent?
    /// The notice HUD places itself below the indicator; it hears of every move.
    var onFrameChange: (() -> Void)?

    /// The panel's frame while it is on screen.
    var visibleFrame: NSRect? { panel?.isVisible == true ? panel?.frame : nil }

    init(model: DictationIndicatorModel) {
        self.model = model
        sub = model.$content.sink { [weak self] c in MainActor.assumeIsolated { self?.apply(c) } }
    }

    private func apply(_ content: DictationIndicatorContent?) {
        guard let content else {
            if panel?.isVisible == true {
                panel?.orderOut(nil)
                onFrameChange?()
            }
            lastLayout = nil
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host: NSHostingView<DictationIndicatorView>
        if let h = self.host {
            h.rootView = DictationIndicatorView(content: content)
            host = h
        } else {
            host = NSHostingView(rootView: DictationIndicatorView(content: content))
            panel.contentView = host
            self.host = host
        }
        let wasVisible = panel.isVisible
        // Only a change of what takes room re-measures: the level and the seconds do not.
        var layout = content
        layout.levels = []
        layout.elapsed = 0
        if layout != lastLayout || !wasVisible {
            lastLayout = layout
            if !wasVisible { screen = NSScreen.main }
            let size = host.fittingSize
            if let f = (screen ?? NSScreen.main)?.visibleFrame {
                panel.setFrame(NSRect(x: (f.midX - size.width / 2).rounded(), y: (f.maxY - Self.topGap - size.height).rounded(),
                                      width: size.width, height: size.height), display: true)
                // A transparent panel's shadow follows the drawn shape: recompute it after a size change.
                panel.invalidateShadow()
            }
            if !wasVisible { panel.orderFrontRegardless() }
            onFrameChange?()
        }
    }

    private func makePanel() -> OverlayPanel {
        let p = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return p
    }
}
