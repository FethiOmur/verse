import Combine
import Foundation
import VersePrompter
import VerseSpeech

/// Where the open script comes from. A meeting card is read through the meeting's own mic stream.
public enum PrompterSource: Sendable {
    case script
    case meetingCard(MeetingMicTap)

    public var isMeetingCard: Bool { if case .meetingCard = self { return true }; return false }
}

/// The UI side of the teleprompter: owns the `PrompterSession` while the prompter is open, mirrors its state for the
/// views, registers the shortcuts, and feeds meeting cards into the script. The reading logic is all in `VersePrompter`.
@MainActor
public final class PrompterModel: ObservableObject {
    public let settings: PrompterSettings

    @Published public private(set) var isOpen = false
    @Published public private(set) var state = PrompterState()
    /// The page being read (page-local words and text).
    @Published public private(set) var page = PromptPage(text: "")
    @Published public private(set) var source = PrompterSource.script
    /// Shortcuts another app already holds; their buttons on the panel work regardless.
    @Published public private(set) var unavailableShortcuts: [PrompterCommand] = []

    /// The language the microphone recognizer uses for a script read outside a meeting.
    public var language: () -> String = { "en" }
    /// Builds the session for a script. nil: the app's default, which opens the microphone (or wraps the meeting's
    /// mic stream). Tests set their own.
    public var makeSession: ((PromptScript, PrompterSource) -> PrompterSession)?
    /// Tests turn the global shortcuts off.
    var registersHotKeys = true

    /// The editor window's model, created on first use so the app pays nothing for it.
    public lazy var editor = ScriptEditorModel(store: .appDefault, writer: BrainScriptWriter())

    private var session: PrompterSession?
    private var consumer: Task<Void, Never>?
    private var shownPageIndex = 0
    private var cancellables: Set<AnyCancellable> = []
    private let hotKeys = PrompterHotKeys()
    private var layoutCache: (key: LayoutKey, layout: PrompterLayout)?

    private struct LayoutKey: Equatable {
        var text: String
        var currentSize: Double
        var maxWidth: Double
    }

    /// How much of the island card's SAY line he has said (the prompter-style answer card). Fed from the same
    /// meeting mic tap as the meeting-card prompter mode.
    public let cardReading = CardReading()

    // meeting cards (T4)
    private var meetingTap: MeetingMicTap?
    private var cardQueue: Task<Void, Never>?
    private var lastSay: String?
    private var currentTurn: String?
    private var dismissedTurn: String?

    public init(settings: PrompterSettings = PrompterSettings()) {
        self.settings = settings
        settings.$mode.dropFirst().removeDuplicates().sink { [weak self] mode in
            Task { @MainActor in await self?.applyMode(mode) }
        }.store(in: &cancellables)
        settings.$wordsPerMinute.dropFirst().removeDuplicates().sink { [weak self] wpm in
            Task { @MainActor in await self?.applySpeed(wpm) }
        }.store(in: &cancellables)
    }

    private func defaultSession(_ script: PromptScript, _ source: PrompterSource) -> PrompterSession {
        switch source {
        case .script:
            let inputs = ListenSessionInputs.micOnly(lang: language())
            return PrompterSession(script: script, mode: settings.mode, wordsPerMinute: settings.wordsPerMinute,
                                   transcript: inputs, levels: inputs)
        case .meetingCard(let tap):
            // Only the transcript of the meeting's mic channel; no level source, so voice-paced falls back to classic.
            return PrompterSession(script: script, mode: settings.mode, wordsPerMinute: settings.wordsPerMinute,
                                   transcript: ExternalTranscriptSource(stream: tap.stream()), levels: nil)
        }
    }

    // MARK: what the views read

    public var hint: PrompterHint? { PrompterHint(state: state) }
    public var wordRanges: PrompterWordRanges { PrompterWordRanges(state: state) }

    /// Line breaking of the current page as the island sets it: every word measured in the current line's type
    /// (`currentSize`, semibold), so no line is ever too wide. Cached until the page text, that size or the width changes:
    /// the view asks on every published state, once per word read (review V3: it used to measure the whole page each time).
    func layout(currentSize: CGFloat, maxWidth: CGFloat) -> PrompterLayout {
        let key = LayoutKey(text: page.text, currentSize: Double(currentSize), maxWidth: Double(maxWidth))
        if let cached = layoutCache, cached.key == key { return cached.layout }
        layoutMeasurements += 1
        let widths = PrompterTextMeasure.widths(of: page.words.map(\.text), fontSize: currentSize)
        let layout = PrompterLayout.make(wordWidths: widths, spaceWidth: PrompterTextMeasure.spaceWidth(size: currentSize, weight: .semibold),
                                         maxWidth: maxWidth)
        layoutCache = (key, layout)
        return layout
    }

    /// How many times `layout(currentSize:maxWidth:)` measured the page (tests).
    private(set) var layoutMeasurements = 0

    /// Shows the prompter on a given page and state without a session (the screenshot renderer).
    func presentForPreview(page: PromptPage, state: PrompterState) {
        self.page = page
        self.state = state
        isOpen = true
    }

    // MARK: open and close

    /// Opens the prompter on `script` and, with `autostart`, starts reading. An open prompter is closed first.
    public func open(script: PromptScript, source: PrompterSource = .script, autostart: Bool = true) async {
        guard !script.isEmpty else { return }
        if isOpen { await teardown() }
        let s = (makeSession ?? defaultSession)(script, source)
        session = s
        self.source = source
        page = script.pages[0]
        shownPageIndex = 0
        state = await s.state
        isOpen = true
        if !source.isMeetingCard { dismissedTurn = nil }
        startConsumer(s)
        if registersHotKeys {
            unavailableShortcuts = hotKeys.register { [weak self] command in self?.send(command) }
        }
        if autostart { await s.start() }
    }

    public func close() async {
        guard isOpen else { return }
        if source.isMeetingCard { dismissedTurn = currentTurn }
        isOpen = false
        await teardown()
        state = PrompterState()
    }

    private func teardown() async {
        consumer?.cancel()
        consumer = nil
        hotKeys.unregister()
        unavailableShortcuts = []
        let s = session
        session = nil
        await s?.stop()
    }

    private func startConsumer(_ s: PrompterSession) {
        let stream = s.states
        consumer = Task { [weak self] in
            for await next in stream {
                guard let self else { return }
                await self.apply(next, from: s)
            }
        }
    }

    private func apply(_ next: PrompterState, from s: PrompterSession) async {
        guard session === s else { return }
        if next.pageIndex != shownPageIndex || next.wordCount != page.wordCount {
            let fresh = await s.currentPage
            guard session === s else { return }
            page = fresh
            shownPageIndex = next.pageIndex
        }
        // The state changes 30 times a second in classic mode (the position is fractional); the views only show whole
        // words, so a change that moves no word, line or flag is not published.
        if next.displayKey != state.displayKey { state = next }
        // The speed buttons change the session; keep the saved preference in step.
        if abs(settings.wordsPerMinute - next.wordsPerMinute) > 0.5 { settings.wordsPerMinute = next.wordsPerMinute }
    }

    private func applyMode(_ mode: PrompterMode) async {
        guard let session, state.requestedMode != mode else { return }
        await session.setMode(mode)
    }

    private func applySpeed(_ wpm: Double) async {
        guard let session, abs(state.wordsPerMinute - wpm) > 0.5 else { return }
        await session.setWordsPerMinute(wpm)
    }

    // MARK: controls

    /// Start, pause or resume; on a finished script it reads the last page again.
    public func toggle() async {
        guard let session else { return }
        if state.isDone {
            await session.jump(toWord: 0)
            await session.start()
        } else if state.isPaused {
            await session.start()
        } else {
            await session.pause()
        }
    }

    public func nextPage() async { await session?.nextPage() }
    public func previousPage() async { await session?.previousPage() }
    public func restartPage() async { await session?.jump(toWord: 0) }
    public func jump(toWord index: Int) async { await session?.jump(toWord: index) }
    public func faster() async { await session?.adjustSpeed(bySteps: 1) }
    public func slower() async { await session?.adjustSpeed(bySteps: -1) }

    /// Swaps the text after the read part (a new meeting card). The page is read back afterwards because the words
    /// can change without the word count or the state changing.
    public func replaceUnread(with text: String) async {
        guard let session else { return }
        await session.replaceUnread(with: text)
        page = await session.currentPage
    }

    /// Replaces the whole page with `text` (a new meeting turn) and reads it from the start.
    private func replaceScript(with text: String) async {
        guard let session else { return }
        await session.replaceScript(PromptScript(pages: [PromptPage(text: text)]))
        guard self.session === session else { return }
        page = await session.currentPage
        shownPageIndex = 0
    }

    public func perform(_ command: PrompterCommand) async {
        switch command {
        case .toggle: await toggle()
        case .previousPage: await previousPage()
        case .nextPage: await nextPage()
        case .slower: await slower()
        case .faster: await faster()
        case .restart: await restartPage()
        case .close: await close()
        }
    }

    /// For buttons and shortcuts, which cannot await.
    public func send(_ command: PrompterCommand) { Task { @MainActor in await self.perform(command) } }

    // MARK: meeting cards (T4)

    /// A meeting run starts. Returns the tap the runner feeds with every transcript event.
    public func meetingStarted(room: Bool = false) -> MeetingMicTap {
        let tap = MeetingMicTap()
        cardReading.roomRoute = room
        meetingTap = tap
        cardReading.connect(tap)
        cardReading.setSay(nil)
        lastSay = nil
        currentTurn = nil
        dismissedTurn = nil
        return tap
    }

    /// The call's audio route changed in place: the card's reading follows the room route's microphone or not.
    public func meetingRoute(room: Bool) {
        cardReading.roomRoute = room
        if isOpen, source.isMeetingCard, !meetingCardPrompterCanTrack {
            Task { @MainActor in await self.closeMeetingCardPrompter() }
        }
    }

    /// Review V6: on the room route the microphone's events arrive as `remote`, and the prompter's word tracking reads only
    /// `me`, so a meeting-card prompter would never move and would hide the card, whose own reading (`CardReading`) does
    /// follow the room route. There the card stays instead. Classic and voice-paced (classic without levels) need no speech.
    private var meetingCardPrompterCanTrack: Bool {
        !(cardReading.roomRoute && settings.mode == .wordTracking)
    }

    /// Closes a meeting-card prompter for a reason other than the user's X: the turn is not marked dismissed.
    private func closeMeetingCardPrompter() async {
        guard isOpen, source.isMeetingCard else { return }
        isOpen = false
        await teardown()
        state = PrompterState()
    }

    /// The meeting run ended: the mic stream is gone, so a card being read is closed.
    public func meetingEnded() {
        meetingTap?.finish()
        meetingTap = nil
        cardReading.connect(nil)
        cardQueue = nil
        if isOpen, source.isMeetingCard { Task { @MainActor in await self.close() } }
    }

    /// The overlay's current card changed. Queued, so quick changes apply in order.
    public func meetingCard(_ card: OverlayCard?) {
        cardReading.setSay(card?.say)   // the island card's spoken/unspoken split, whatever the prompter setting is
        cardReading.setPoints((card?.bullets ?? []) + (card?.deepPoints ?? []))   // the reading can jump to a point too
        let previous = cardQueue
        cardQueue = Task { @MainActor [weak self] in
            await previous?.value
            await self?.handleMeetingCard(card)
        }
    }

    /// With "Prompter on meeting cards" on: the first card with a SAY line opens the prompter on that text; a later SAY
    /// text of the same turn replaces the unread tail and keeps what was read, and a new turn starts a fresh page. A card
    /// the user closed does not reopen it. On the room route with word tracking the card shows instead (review V6).
    public func handleMeetingCard(_ card: OverlayCard?) async {
        guard settings.followMeetingCards, let tap = meetingTap, let card else { return }
        let say = (card.say ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !say.isEmpty else { return }
        if isOpen {
            guard source.isMeetingCard, say != lastSay else { return }   // a script being read is not interrupted
            guard meetingCardPrompterCanTrack else { await closeMeetingCardPrompter(); return }
            lastSay = say
            if card.turnID != currentTurn {
                // A new turn: a fresh page with only its answer (review V3: the page used to keep every earlier answer and
                // grow for the whole call).
                currentTurn = card.turnID
                await replaceScript(with: say)
            } else {
                await replaceUnread(with: say)
            }
            return
        }
        guard dismissedTurn != card.turnID, meetingCardPrompterCanTrack else { return }
        lastSay = say
        currentTurn = card.turnID
        await open(script: PromptScript(pages: [PromptPage(text: say)]), source: .meetingCard(tap), autostart: true)
    }
}

extension PrompterState {
    /// What the views can tell apart: the whole word index instead of the fractional position.
    struct DisplayKey: Equatable {
        var pageIndex: Int
        var pageCount: Int
        var word: Int
        var wordCount: Int
        var isSpeaking: Bool
        var isLost: Bool
        var isPaused: Bool
        var isDone: Bool
        var mode: PrompterMode
        var requestedMode: PrompterMode
        var wordsPerMinute: Double
        var notice: PrompterNotice?
    }

    var displayKey: DisplayKey {
        DisplayKey(pageIndex: pageIndex, pageCount: pageCount, word: Int((wordPosition + 1e-9).rounded(.down)), wordCount: wordCount,
                   isSpeaking: isSpeaking, isLost: isLost, isPaused: isPaused, isDone: isDone, mode: mode,
                   requestedMode: requestedMode, wordsPerMinute: wordsPerMinute, notice: notice)
    }
}
