import Combine
import Foundation
import VerseTurns

/// The overlay's observable state for SwiftUI. All logic is in `OverlayReducer`; this only publishes it and runs the
/// timeout clock.
@MainActor
public final class OverlayModel: ObservableObject {
    /// The island's state. Changes announce themselves (`objectWillChange`) only when something other than the level
    /// bars moved: the bars change about ten times a second for the whole call, and they are drawn from `levels` by the
    /// bars alone, so they must not re-evaluate the whole island (card included) each time (review V8).
    public private(set) var state = OverlayState() {
        willSet {
            if !newValue.equalIgnoringLevels(state) { objectWillChange.send() }
        }
        didSet { levels.update(remote: state.remoteBars, me: state.meBars) }
    }
    /// The level bars, published on their own for the bars views (`LiveLevelBars`).
    public let levels = IslandLevels()
    /// The running session is shutting down (the Stop controls show "Stopping…" and take no clicks). The controller sets it.
    @Published public private(set) var stopping = false
    /// The answers the notch showed in this session, and whether the island shows one of them instead of the live card.
    /// Recorded from `state.card` after every change; `state` itself stays the live state (the controller and the prompter
    /// read it), and only the view draws `displayState`.
    @Published public private(set) var history = AnswerHistory()
    /// The BAD marks of this session, by card (the island's button shows them; ⌥⌘↓ sets them too).
    @Published public private(set) var marks = CardMarks()
    private var reducer: OverlayReducer
    private let clock: () -> TimeInterval
    private var timer: Timer?

    public init(config: OverlayConfig = OverlayConfig(), bank: [String: BankOpener] = [:],
                clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        reducer = OverlayReducer(config: config, bank: bank)
        self.clock = clock
    }

    public var config: OverlayConfig {
        get { reducer.config }
        set { reducer.config = newValue }
    }

    public var bank: [String: BankOpener] {
        get { reducer.bank }
        set { reducer.bank = newValue }
    }

    public func apply(_ e: RunnerEvent) {
        reducer.apply(e, now: clock())
        publish()
    }

    /// Runs the card timeout (call it on a timer; tests call it with a moved clock).
    public func tick() {
        reducer.tick(now: clock())
        publish()
    }

    /// The running call's time cue (from its `call.json`); nil when it has none.
    public func setCallCue(_ cue: CallCue?) {
        reducer.setCallCue(cue, now: clock())
        publish()
    }

    public func sessionStarting(lang: String, session: String = "", app: String? = nil, route: AudioRoute? = nil, unprepared: Bool = false,
                                auto: Bool = false) {
        reducer.sessionStarting(lang: lang, session: session, app: app, route: route, unprepared: unprepared, auto: auto)
        history.clear()
        marks = CardMarks()
        publish()
    }

    /// The running call now listens on another route and/or in another language (the listen pipeline was swapped in place).
    /// Only the labels move: the card, the topics, the transcript state and the clock are the call's, untouched.
    public func listeningChanged(route: AudioRoute, lang: String, app: String? = nil, auto: Bool? = nil) {
        reducer.listeningChanged(route: route, lang: lang, app: app, auto: auto)
        publish()
    }

    /// "Press ⌥⌘V again to stop" on or off. It overlays whatever the island shows and never replaces a real status
    /// (an error or a permission message stays; a "reconnected" notice gives way); taking it down leaves any other status alone.
    public func setStopConfirm(_ on: Bool) {
        if on {
            let s = reducer.state.status
            if s == nil || s == .meMissing || s?.isTransientNotice == true { reducer.setStatus(.stopConfirm) }
        } else if reducer.state.status == .stopConfirm {
            reducer.setStatus(nil)
        }
        publish()
    }

    /// What the island's Stop button does: the controller's `stop()`, like the menu item.
    public var stopActions: (() -> Void)?

    public func setStopping(_ on: Bool) {
        if stopping != on { stopping = on }
    }

    /// The island's Stop control: only while a session runs and is not already stopping.
    public var canStop: Bool { SessionStop.canStop(running: state.running, stopping: stopping) }

    public func stopSession() {
        guard canStop else { return }
        stopActions?()
    }

    /// What the start card's chips do; the `VerseController` sets it.
    public var startChipActions: ((StartChipAction) -> Void)?

    public func startChipAction(_ a: StartChipAction) {
        startChipActions?(a)
    }

    /// Click on the capsule: closes the open card, else the start-up panel. While an earlier answer is shown, the click puts
    /// the live island back instead (the live card stays as it was).
    public func collapse() {
        if history.isPinned {
            history.returnToLive()
            return
        }
        reducer.collapse()
        publish()
    }

    // MARK: earlier answers

    /// What the island draws: the live state, or the live state with the pinned earlier answer in place of the card.
    public var displayState: OverlayState { history.display(state) }

    /// Back (the island's button, ⌥⌘←, ⇧<): one answer older. Only while a meeting session runs.
    public func showEarlierAnswer() {
        guard state.running, state.sim == nil else { return }
        history.back()
    }

    /// Forward (the island's button, ⌥⌘→): one answer newer, then live again.
    public func showNewerAnswer() {
        guard state.running else { return }
        history.forward()
    }

    public func showLiveAnswer() {
        history.returnToLive()
    }

    // MARK: live controls on the answer card

    /// What Regenerate asks of the brain; the controller sets it. False: no brain to ask (the press is undone).
    public var regenerateActions: ((RegenerateRequest) -> Bool)?
    /// Where a mark change goes (the brain's events.jsonl); the controller sets it.
    public var markActions: ((CardMarkEvent) -> Void)?

    /// The answer card on screen (the live one, or the earlier one shown with Back) while a meeting session runs.
    public var answerOnScreen: OverlayCard? {
        guard state.running, state.sim == nil, let c = displayState.card, AnswerHistory.isAnswer(c) else { return nil }
        return c
    }

    /// Regenerate is offered: an answer is on screen, the session is not stopping and no regenerate is in flight.
    public var canRegenerate: Bool { answerOnScreen != nil && !stopping && !state.regenerating }

    /// Regenerate (the island's button, ⌥⌘R): the question of the card on screen is answered again at once, in the language of
    /// most of the other side's speech when the card is not in it (`RegenerateRule`; the brain's majority language, else its
    /// dominant one from an older brain). The island goes back to live, where the new answer arrives; the
    /// card it replaces stays in the history (Back). Ignored while one is in flight. Returns what was asked, nil when ignored.
    @discardableResult
    public func regenerate() -> RegenerateRequest? {
        guard canRegenerate, let card = answerOnScreen else { return nil }
        let req = RegenerateRule.request(for: card, dominant: state.majorityLang ?? state.dominantLang)
        reducer.beginRegenerate(now: clock())
        history.returnToLive()
        if regenerateActions?(req) == false {
            reducer.cancelRegenerate()
            publish()
            return nil
        }
        publish()
        return req
    }

    /// The mark on the card on screen, for the island's button.
    public var markOnScreen: CardMark? { answerOnScreen.flatMap { marks.mark(for: $0) } }

    /// BAD (the island's button, ⌥⌘↓) on the card on screen; the same mark again clears it. Nothing else moves: listening and the
    /// cards go on. Every change goes to `markActions` (a `cleared` names the id the card's mark was sent under). Returns the last change, nil when no answer is on screen.
    @discardableResult
    public func mark(_ m: CardMark) -> CardMarkEvent? {
        guard !stopping, let card = answerOnScreen else { return nil }
        let events = marks.press(m, on: card)
        for e in events { markActions?(e) }
        return events.last
    }

    /// Shows an error message (with Retry) for a run that ended without saying why.
    public func showError(_ message: String) {
        reducer.setStatus(.error(message))
        publish()
    }

    /// Clears the status chip (the user closed the message).
    public func dismissStatus() {
        var s = reducer
        s.clearStatus()
        reducer = s
        publish()
    }

    /// Sets a state directly (screenshot renderer and previews).
    public func show(_ s: OverlayState) {
        state = s
    }

    public func startClock() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stopClock() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: practice interview (S4)

    /// What the sim panel's buttons do; the sim controller sets it while an interview runs.
    public var simActions: ((SimUIAction) -> Void)?

    public func simStarting(voice: String, showCaption: Bool) {
        reducer.simStarting(voice: voice, showCaption: showCaption)
        publish()
    }

    public func simApply(_ e: SimEvent) {
        reducer.simApply(e)
        publish()
    }

    /// A button in the sim panel. The caption toggle is local; the rest goes to the sim controller.
    public func simAction(_ a: SimUIAction) {
        if a == .toggleCaption {
            reducer.simToggleCaption()
            publish()
        }
        simActions?(a)
    }

    // MARK: meeting prompt

    /// What the prompt's buttons do; the `MeetingCoordinator` sets it.
    public var promptActions: ((PromptAction) -> Void)?

    /// Shows (or, with nil, removes) the notch prompt. A running session replaces it by itself (`sessionStarting`).
    public func showPrompt(_ p: MeetingPrompt?) {
        reducer.setPrompt(p)
        publish()
    }

    public func promptAction(_ a: PromptAction) {
        promptActions?(a)
    }

    private func publish() {
        if state != reducer.state { state = reducer.state }
        recordHistory()
    }

    /// The history follows the live card of a meeting session; a session that is not running (stopped, or not started yet)
    /// keeps none. Practice interviews keep none either.
    private func recordHistory() {
        var h = history
        if !state.running || state.sim != nil {
            h.clear()
            if !marks.marks.isEmpty { marks = CardMarks() }
        } else {
            h.observe(state.card)
            for card in reducer.backgroundCards.values.sorted(by: { $0.turnID < $1.turnID }) { h.record(card) }
        }
        if h != history { history = h }
    }
}

extension OverlayReducer {
    mutating func clearStatus() { setStatus(nil) }
}

/// The island's level bars (the last 300 ms of the meeting's and of my audio), apart from `OverlayState`'s other fields
/// so that only the bars views observe their ten updates a second.
@MainActor
public final class IslandLevels: ObservableObject {
    @Published public private(set) var remote: [Double] = [0, 0, 0]
    @Published public private(set) var me: [Double] = [0, 0, 0]

    public init() {}

    func update(remote r: [Double], me m: [Double]) {
        if remote != r { remote = r }
        if me != m { me = m }
    }
}

extension OverlayState {
    /// Equal in everything but the level bars.
    func equalIgnoringLevels(_ other: OverlayState) -> Bool {
        var a = self, b = other
        a.remoteBars = []; a.meBars = []
        b.remoteBars = []; b.meBars = []
        return a == b
    }
}

/// The start card's chips (anytime calls, spec 2.1): the route chip changes the route. There is no language chip.
public enum StartChipAction: Equatable, Sendable {
    case cycleRoute
}

/// The sim panel's controls.
public enum SimUIAction: Equatable, Sendable {
    case skip, `repeat`, end, doneAnswering, toggleCaption
}
