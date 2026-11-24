import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import VerseAudio

/// Where a dictation is.
public enum DictationPhase: String, Sendable, Equatable {
    case idle
    /// The microphone is open (or opening) and the engine transcribes.
    case recording
    /// The second press: the microphone is closed and the engine settles the last words.
    case finalising
    /// The text goes into the app in front.
    case inserting
}

/// The brief on-screen notices of dictation.
public enum DictationNotice: Sendable, Equatable {
    /// The hot key was pressed while Verse listens to a meeting or another run is active: nothing started.
    case busy
    /// A meeting or run started while recording: the dictation was dropped.
    case cancelledByRun
    /// No Accessibility permission: the text is on the clipboard.
    case copiedToClipboard
    /// The transcript was empty: nothing was inserted.
    case nothingHeard
    /// The engine or the microphone failed.
    case failed(String)
    /// Esc cancelled the dictation: nothing was inserted.
    case cancelled
    /// The microphone has been open for a second and delivered nothing but exact silence (muted input, dead route).
    case microphoneSilent
    /// The whole recording was exact silence and nothing was heard: nothing was inserted.
    case microphoneSilentNothingInserted
    /// The paste went nowhere (gap G2): the text is on the clipboard.
    case notInserted

    public var text: String {
        switch self {
        case .busy: return L10n.tr("Dictation is off while Verse is listening")
        case .cancelledByRun: return L10n.tr("Dictation stopped: Verse started listening")
        case .copiedToClipboard: return L10n.tr("No Accessibility permission: the text is on the clipboard. Paste it with ⌘V.")
        case .nothingHeard: return L10n.tr("Dictation heard nothing")
        case .failed(let why): return L10n.tr("Dictation failed: \(why)")
        case .cancelled: return L10n.tr("Dictation cancelled")
        case .microphoneSilent: return L10n.tr("No sound from the microphone. Is it muted?")
        case .microphoneSilentNothingInserted: return L10n.tr("No sound from the microphone: nothing was inserted. Is it muted?")
        case .notInserted: return L10n.tr("Not inserted. It is on the clipboard: press ⌘V")
        }
    }
}

/// Shows a dictation notice. The app's is `DictationHUD`; tests record them.
@MainActor
public protocol DictationNotifying: AnyObject {
    func show(_ notice: DictationNotice)
}

/// Dictation: Fn + Space (or ⌃⌥⌘D) starts recording the microphone, the same key again stops, and the transcript is inserted
/// where the keyboard focus is. Toggle only. It never runs while a meeting or another run is active and never starts one; a run
/// that starts while it records cancels it (`observeRuns`). Both keys exist only while the feature is on: ⌃⌥⌘D is a Carbon hot
/// key (no permission), Fn + Space an event tap (`FnSpaceEventTap`, needs Accessibility; without it only ⌃⌥⌘D works).
///
/// When the permission is missing, the controller asks for it once per launch (the system's Accessibility prompt) and then
/// retries the tap every `permissionPollInterval` until it is granted, so Fn + Space starts working without a relaunch.
///
/// Cues: a short drum-like sound once the microphone is actually open, a lower, softer one when the second press is taken
/// (`DictationSound`, setting `sounds`). Never while a run is active (dictation cannot run then anyway; the check stays so a
/// cue can never reach a call Verse is listening to), and none on a cancel or a failure (the notice says what happened).
///
/// Decisions of the second round (gaps G1, G3, G4, G7, G10 of the TypeWhisper comparison):
/// - Release tail (G4): after the stop press the microphone stays open up to 350 ms and closes after 150 ms of quiet
///   (`DictationReleaseTail`); no tail for a recording under 0.3 s. The stop cue now plays the moment the microphone's
///   capture has stopped (`DictationTranscribing.finish(onCaptureClosed:)`), not at the press: played at the press it would
///   sound into the open microphone during the tail, where it could keep the quiet detector from closing and reach the
///   engine. After the capture has stopped it provably cannot. It still comes before the engine settles the last words, so the
///   cue is late by the tail only (150-350 ms).
/// - Esc (G7): a single Esc cancels while recording or finishing (the release tail included): nothing is inserted, nothing is
///   kept, the notice "Dictation cancelled", no stop cue (a sound would only repeat the notice). Esc comes through the
///   Fn + Space event tap, armed only while a dictation is under way, so it passes to the app in front otherwise. The tap calls
///   `cancelByKey` synchronously, before it drops the key, and disarms in the same step the phase leaves `finalising`: an Esc
///   the tap swallowed always cancels, and the paste starts only from `finalising` with no suspension point in between, so the
///   text is never inserted after a swallowed Esc. Without the tap (no Accessibility permission, ⌃⌥⌘D only) there is no Esc
///   cancel. During the paste itself Esc is not taken (it reaches the app in front).
/// - Silent microphone (G10): once per dictation, once the microphone has delivered a second of audio and all of it was exact
///   silence (`DictationSilence`), the notice asks whether the microphone is muted; recording goes on (a warning, never an
///   auto-stop). A microphone that delivers no audio at all is a different state (a stalled route, not a muted input): it is
///   logged, never shown as "Is it muted?". If the whole clip was silent and the transcript is empty, the end notice says the
///   microphone gave no sound instead of "heard nothing". A non-empty transcript is inserted even then: never losing text wins
///   over a level reading.
/// - Last dictations (G1): every non-empty transcript is added to `history` just before it is inserted (so a paste that lands
///   nowhere is still there), with the name of the app in front. The menu offers "Paste last dictation", "Copy last
///   dictation" and "Clear recent dictations" while dictation is on, no run is active and there is one. A cancelled, failed or
///   empty dictation is not added.
/// - Paste check (G2): the inserter reads the focused element before the paste and polls it after (`DictationPasteCheck`).
///   A paste that went nowhere returns `.notInserted`: the text stays on the clipboard and the notice says to press ⌘V. The
///   same for "Paste last dictation".
/// - Recording indicator (G5): `indicator` follows the phase (preparing until the first audio, recording, finishing) and a
///   panel shows it top centre while a dictation is under way, never during a run, and only with the setting on. Notices go
///   below it (`DictationHUD.avoid`).
/// - Vocabulary (G3): `settings.vocabularyTerms` goes to the transcriber at every start; the Apple transcriber passes it on
///   only where the engine honours it (`AppleDictationTranscriber.config`).
@MainActor
public final class DictationController: ObservableObject {
    /// Calls `tick` every `interval` seconds until the returned token is cancelled. The app's is a main run loop `Timer`.
    public typealias Ticker = @MainActor (_ interval: TimeInterval, _ tick: @escaping @MainActor @Sendable () -> Void) -> AnyCancellable

    /// How often the missing Accessibility permission is checked again.
    public static let permissionPollInterval: TimeInterval = 2
    /// The hot key's id in the shared Carbon handler (`CarbonRegistrar`, signature 'VRHQ'). `GlobalHotKeys` uses 1...7 and 9 under
    /// the same signature, and the registrar's action table is keyed by id alone, so the id must be none of theirs (it was 3,
    /// the earlier-answer key's id: a call's ⌥⌘← took over ⌃⌥⌘D's action and removed it when the call ended).
    public static let hotKeyID: UInt32 = 10
    /// ⌃⌥⌘D. Verse holds ⌥⌘V, ⌥⌘↩, ⌥Space and ⌃⌥ plus a letter (the prompter); macOS holds ⌥⌘D (Dock) and ⌃⌘D (look up),
    /// and window managers use ⌃⌥ plus a letter. Three modifiers keep it clear of all of them.
    public static let hotKey = HotKeySpec(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey | cmdKey))
    public static let hotKeyLabel = "⌃⌥⌘D"
    /// The main key, the one TypeWhisper-style dictation apps use.
    public static let fnSpaceLabel = "Fn + Space"
    /// How long "Paste last dictation" waits for the menu to close and the app in front to have its focus back.
    public static let menuCloseDelay: Duration = .milliseconds(200)

    @Published public private(set) var phase: DictationPhase = .idle {
        didSet {
            // Esc is taken only while there is something to cancel.
            let armed = phase == .recording || phase == .finalising
            if armed != cancelArmed {
                cancelArmed = armed
                keyTap.setCancelArmed(armed)
            }
            indicator.update(phase: phase, source: transcriber, runActive: runBlocks)
        }
    }
    /// The hot key is registered (the feature is on and the system accepted it).
    @Published public private(set) var hotKeyRegistered = false
    /// The feature is on but the system refused the hot key (another app holds it). Settings says so.
    @Published public private(set) var hotKeyRefused = false
    /// Fn + Space is live (the feature is on and the tap is installed).
    @Published public private(set) var fnSpaceActive = false
    /// The feature is on but Fn + Space could not be installed (the Accessibility permission is missing). Settings says so.
    @Published public private(set) var fnSpaceUnavailable = false

    public let settings: DictationSettings
    /// The last dictations (gap G1).
    public let history: DictationHistory
    /// The recording indicator's state (gap G5).
    public let indicator: DictationIndicatorModel
    /// Its window; nil in tests.
    private let indicatorPanel: DictationIndicatorPanel?
    /// A meeting, a practice interview or another run holds (or is about to hold) the microphone. The app wires it
    /// (`VerseController.bindDictation`).
    public var isRunActive: () -> Bool = { false }
    /// The last value `observeRuns` delivered: published so the menu rows appear and disappear with a run.
    @Published public private(set) var runActive = false

    private let registrar: any HotKeyRegistrar
    private let keyTap: any DictationKeyTap
    private let makeTranscriber: @MainActor () -> any DictationTranscribing
    private let inserter: any DictationTextInserting
    private let notifier: any DictationNotifying
    private let sounds: any DictationSoundPlaying
    private let accessibility: any AccessibilityTrust
    private let ticker: Ticker
    private let pasteboard: any DictationPasteboard
    private let frontAppName: @MainActor () -> String?
    private let now: @MainActor () -> TimeInterval
    private let sleep: @Sendable (Duration) async -> Void
    private let log: (String) -> Void

    /// The system's Accessibility prompt was shown in this launch (it is shown at most once per launch).
    private(set) var promptedThisLaunch = false
    /// The retry timer while Fn + Space waits for the permission.
    private var permissionWatch: AnyCancellable?
    var isWatchingPermission: Bool { permissionWatch != nil }

    private var activated = false
    private var token: Int?
    private var settingsSub: AnyCancellable?
    private var runSub: AnyCancellable?
    /// One number per dictation: a late completion of an older (cancelled or failed) one changes nothing.
    private var generation = 0
    private var transcriber: (any DictationTranscribing)?
    private var beginTask: Task<Void, any Error>?
    /// The microphone release of the last cancel or failure (tests wait for it).
    private(set) var pendingRelease: Task<Void, Never>?
    /// The key tap's Esc is armed.
    private(set) var cancelArmed = false
    /// When the microphone of the current dictation opened (`now`), nil before.
    private var openedAt: TimeInterval?
    /// The silent-microphone check while recording, and whether this dictation's warning was shown.
    private var silenceWatch: AnyCancellable?
    private(set) var warnedSilent = false
    /// This dictation's "no audio at all" was logged.
    private var loggedNoAudio = false

    public init(settings: DictationSettings = DictationSettings(), registrar: (any HotKeyRegistrar)? = nil,
                keyTap: (any DictationKeyTap)? = nil,
                makeTranscriber: (@MainActor () -> any DictationTranscribing)? = nil,
                inserter: (any DictationTextInserting)? = nil, notifier: (any DictationNotifying)? = nil,
                sounds: (any DictationSoundPlaying)? = nil, accessibility: (any AccessibilityTrust)? = nil,
                ticker: Ticker? = nil, history: DictationHistory? = nil, pasteboard: (any DictationPasteboard)? = nil,
                frontAppName: (@MainActor () -> String?)? = nil, now: (@MainActor () -> TimeInterval)? = nil,
                sleep: (@Sendable (Duration) async -> Void)? = nil, indicatorTicker: Ticker? = nil,
                presentsIndicator: Bool = true,
                log: @escaping (String) -> Void = { FileLog.shared.write($0) }) {
        self.settings = settings
        let clock = now ?? { ProcessInfo.processInfo.systemUptime }
        let indicator = DictationIndicatorModel(settings: settings, ticker: indicatorTicker ?? Self.timerTicker, now: clock)
        self.indicator = indicator
        let panel = presentsIndicator ? DictationIndicatorPanel(model: indicator) : nil
        self.indicatorPanel = panel
        self.history = history ?? DictationHistory(log: log)
        self.pasteboard = pasteboard ?? SystemDictationPasteboard()
        self.frontAppName = frontAppName ?? { NSWorkspace.shared.frontmostApplication?.localizedName }
        self.now = clock
        self.sleep = sleep ?? { try? await Task.sleep(for: $0) }
        self.registrar = registrar ?? CarbonRegistrar()
        self.keyTap = keyTap ?? FnSpaceEventTap()
        self.makeTranscriber = makeTranscriber ?? { AppleDictationTranscriber() }
        self.inserter = inserter ?? PasteboardTextInserter()
        let notifier = notifier ?? DictationHUD()
        self.notifier = notifier
        if let hud = notifier as? DictationHUD, let panel {
            hud.avoid = { [weak panel] in panel?.visibleFrame }
            panel.onFrameChange = { [weak hud] in hud?.reposition() }
        }
        self.sounds = sounds ?? SynthDictationSoundPlayer()
        self.accessibility = accessibility ?? SystemAccessibilityTrust()
        self.ticker = ticker ?? Self.timerTicker
        self.log = log
    }

    /// A repeating `Timer` on the main run loop (common modes, so it also fires while a menu is open).
    static func timerTicker(_ interval: TimeInterval, _ tick: @escaping @MainActor @Sendable () -> Void) -> AnyCancellable {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        return AnyCancellable { timer.invalidate() }
    }

    public var isRecording: Bool { phase == .recording }

    // MARK: hot key

    /// Starts following the setting (app launch): the hot key is registered while the feature is on, and unregistered (and a
    /// dictation under way cancelled) when it is turned off.
    public func activate() {
        guard !activated else { return }
        activated = true
        settingsSub = settings.$enabled.removeDuplicates().sink { [weak self] on in
            MainActor.assumeIsolated { self?.apply(enabled: on) }
        }
    }

    /// The opposite of `activate` (tests, quit): cancels a dictation under way and releases the hot key.
    public func deactivate() {
        settingsSub = nil
        runSub = nil
        activated = false
        cancelCurrent(notice: nil)
        apply(enabled: false)
    }

    private func apply(enabled on: Bool) {
        if on {
            guard token == nil else { return }
            token = registrar.register(Self.hotKey, id: Self.hotKeyID) { [weak self] in
                Task { await self?.press() }
            }
            hotKeyRegistered = token != nil
            hotKeyRefused = token == nil
            log(token == nil ? "dictation: \(Self.hotKeyLabel) is taken by another app" : "dictation: \(Self.hotKeyLabel) registered")
            // `$enabled` sends the new value before the property changes: pass it on.
            installFnSpace(enabled: true, mayPrompt: true)
        } else {
            if let t = token {
                registrar.unregister(t)
                log("dictation: \(Self.hotKeyLabel) unregistered")
            }
            token = nil
            hotKeyRegistered = false
            hotKeyRefused = false
            if fnSpaceActive {
                keyTap.remove()
                log("dictation: \(Self.fnSpaceLabel) removed")
            }
            fnSpaceActive = false
            fnSpaceUnavailable = false
            stopPermissionWatch()
            cancelCurrent(notice: nil)
        }
    }

    /// Installs Fn + Space when the feature is on and it is not live yet (the permission may have been granted since the last
    /// try). Called when the feature turns on, when Settings shows the dictation section, at every press of a dictation key and
    /// by the permission watch. A press never shows the permission prompt (⌃⌥⌘D behaves as without the watch); the other
    /// callers may, once per launch and never while a run is active or a dictation is under way.
    public func refreshFnSpace() { installFnSpace(enabled: settings.enabled, mayPrompt: true) }

    private func installFnSpace(enabled: Bool, mayPrompt: Bool) {
        guard activated, enabled, !fnSpaceActive else { return }
        let ok = keyTap.install(onToggle: { [weak self] in
            Task { await self?.press() }
        }, onCancel: { [weak self] in self?.cancelByKey() })
        fnSpaceActive = ok
        if ok {
            log(permissionWatch == nil ? "dictation: \(Self.fnSpaceLabel) installed"
                                       : "dictation: \(Self.fnSpaceLabel) available now (Accessibility granted), installed")
            stopPermissionWatch()
        } else {
            if !fnSpaceUnavailable {
                log("dictation: \(Self.fnSpaceLabel) unavailable (no Accessibility permission); \(Self.hotKeyLabel) only")
            }
            if mayPrompt { promptForPermissionIfDue() }
            startPermissionWatch()
        }
        fnSpaceUnavailable = !ok
    }

    // MARK: Accessibility permission

    /// The system's Accessibility prompt, once per launch, and only while nothing listens: not during a run, not during a
    /// dictation. Also marks the setting the insertion path reads, so a dictation's paste does not show the prompt a second time.
    private func promptForPermissionIfDue() {
        guard !promptedThisLaunch, phase == .idle, !isRunActive() else { return }
        promptedThisLaunch = true
        settings.accessibilityPrompted = true
        log("dictation: asking for the Accessibility permission (\(Self.fnSpaceLabel))")
        _ = accessibility.isTrusted(prompt: true)
    }

    private func startPermissionWatch() {
        guard permissionWatch == nil else { return }
        permissionWatch = ticker(Self.permissionPollInterval) { [weak self] in self?.permissionTick() }
    }

    private func stopPermissionWatch() {
        permissionWatch?.cancel()
        permissionWatch = nil
    }

    /// One retry: the tap installs the moment the permission is there (`FnSpaceEventTap.install` checks it without a prompt).
    private func permissionTick() {
        guard activated, settings.enabled, !fnSpaceActive else {
            stopPermissionWatch()
            return
        }
        installFnSpace(enabled: true, mayPrompt: true)
    }

    // MARK: runs

    /// Follows "a run is active": when it turns true, a dictation under way is cancelled without inserting.
    public func observeRuns<P: Publisher>(_ active: P) where P.Output == Bool, P.Failure == Never {
        runSub = active.removeDuplicates().sink { [weak self] on in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.runActive = on
                self.indicator.update(phase: self.phase, source: self.transcriber, runActive: self.runBlocks)
                if on { self.runBecameActive() }
            }
        }
    }

    /// A meeting or run started: a recording (or one being finalised) is dropped and the microphone released at once.
    /// An insertion already under way finishes (the microphone is closed by then).
    public func runBecameActive() {
        guard phase == .recording || phase == .finalising else { return }
        log("dictation: cancelled, a run started")
        cancelCurrent(notice: .cancelledByRun)
    }

    // MARK: Esc

    /// Esc while a dictation records or finishes (the release tail included): dropped without inserting, nothing kept, the
    /// microphone released at once, no stop cue. Ignored at any other time (the tap only takes Esc while armed anyway).
    public func cancelByKey() {
        guard phase == .recording || phase == .finalising else { return }
        log("dictation: cancelled with Esc")
        cancelCurrent(notice: .cancelled)
    }

    // MARK: last dictations

    /// The newest kept dictation.
    public var lastDictation: DictationRecord? { history.last }

    /// A meeting, a practice interview or the prompter holds the microphone (as delivered, or as the gate says now).
    private var runBlocks: Bool { runActive || isRunActive() }

    /// The menu shows "Paste last dictation", "Copy last dictation" and "Clear recent dictations": dictation is on, no run is
    /// active (the same rule as starting a dictation) and one is kept.
    public var offersLastDictation: Bool { settings.enabled && !runBlocks && lastDictation != nil }

    /// "Paste last dictation": the newest kept text through the same inserter, once the menu has closed. Not while a
    /// dictation is under way, and not while a run is active (the same rule as starting one: it never types into a call).
    /// Never shows the permission prompt (the dictation's own paste does that, once).
    public func pasteLast() async {
        guard settings.enabled, phase == .idle, lastDictation != nil else { return }
        if runBlocks {
            log("dictation: paste last ignored, a run is active")
            notifier.show(.busy)
            return
        }
        await sleep(Self.menuCloseDelay)
        guard phase == .idle, let text = lastDictation?.text else { return }
        // A run may have started while the menu closed.
        if runBlocks {
            log("dictation: paste last ignored, a run is active")
            notifier.show(.busy)
            return
        }
        phase = .inserting
        let outcome = await inserter.insert(text, mayPromptForPermission: false)
        log("dictation: last dictation \(outcome.rawValue) chars=\(text.count)")
        if outcome == .copiedToClipboard { notifier.show(.copiedToClipboard) }
        if outcome == .notInserted { notifier.show(.notInserted) }
        phase = .idle
    }

    /// "Copy last dictation": the newest kept text on the clipboard (kept by clipboard managers: the owner asked for it).
    public func copyLast() {
        guard settings.enabled, let text = lastDictation?.text else { return }
        pasteboard.write(text, transient: false)
        log("dictation: last dictation copied chars=\(text.count)")
    }

    /// "Clear recent dictations": empties the list in memory and in its file. Same rule as the other two rows.
    public func clearRecent() {
        guard settings.enabled, !runBlocks else { return }
        history.clear()
        log("dictation: recent dictations cleared")
    }

    // MARK: the key

    /// One press of a dictation key (Fn + Space or ⌃⌥⌘D): idle starts, recording stops and inserts. Presses while finalising or inserting are ignored.
    public func press() async {
        installFnSpace(enabled: settings.enabled, mayPrompt: false)
        switch phase {
        case .idle: await startRecording()
        case .recording: await finishRecording()
        case .finalising, .inserting: log("dictation: key ignored while \(phase.rawValue)")
        }
    }

    private func startRecording() async {
        guard settings.enabled else { return }
        if isRunActive() {
            log("dictation: key ignored, a run is active")
            notifier.show(.busy)
            return
        }
        generation += 1
        let mine = generation
        let lang = settings.language
        let vocabulary = settings.vocabularyTerms
        let t = makeTranscriber()
        transcriber = t
        openedAt = nil
        warnedSilent = false
        loggedNoAudio = false
        phase = .recording
        log("dictation: recording lang=\(lang) vocabulary=\(vocabulary.count)")
        let task = Task { @MainActor [weak self] in
            try await t.begin(lang: lang, vocabulary: vocabulary, onFailure: { why in self?.fail(why, generation: mine) })
        }
        beginTask = task
        do {
            try await task.value
        } catch {
            fail(Self.describe(error), generation: mine)
            return
        }
        if generation == mine { openedAt = now() }
        // A run that started while the microphone was opening cancels now (its own observer found nothing to cancel then,
        // or did: then this dictation is already over).
        if generation == mine, isRunActive() {
            runBecameActive()
            return
        }
        // The microphone is open now: the start cue. Not when the second press came while it was opening (the stop cue
        // follows instead) or the dictation is already over.
        if generation == mine, phase == .recording {
            cue(.start)
            startSilenceWatch(generation: mine)
        }
    }

    // MARK: silent microphone

    private func startSilenceWatch(generation mine: Int) {
        stopSilenceWatch()
        silenceWatch = ticker(DictationSilence.checkInterval) { [weak self] in self?.silenceTick(generation: mine) }
    }

    private func stopSilenceWatch() {
        silenceWatch?.cancel()
        silenceWatch = nil
    }

    /// One look while recording: the warning once, then the watch ends.
    private func silenceTick(generation mine: Int) {
        guard generation == mine, phase == .recording, let t = transcriber, let opened = openedAt, !warnedSilent else {
            stopSilenceWatch()
            return
        }
        switch DictationSilence.reading(openFor: now() - opened, level: t.inputLevel) {
        case .silent:
            warnedSilent = true
            stopSilenceWatch()
            log("dictation: the microphone gives no sound")
            notifier.show(.microphoneSilent)
        case .noAudio:
            // No callbacks at all: not a muted input. Logged once; the watch goes on (audio may still arrive, and be silent).
            guard !loggedNoAudio else { return }
            loggedNoAudio = true
            log("dictation: no audio from the microphone for \(DictationSilence.minimumDuration) s (no callbacks)")
        case .sound, .undecided:
            break
        }
    }

    // MARK: release tail

    /// Keeps the microphone open after the stop press (see `DictationReleaseTail`): one frame every 50 ms until the tail is
    /// over, or the dictation was cancelled meanwhile.
    private func runReleaseTail(_ t: any DictationTranscribing, recordedFor: TimeInterval, generation mine: Int) async {
        guard DictationReleaseTail.applies(recordedFor: recordedFor) else { return }
        _ = t.takeFrameRMS()    // the audio before the press is not part of the tail
        var tail = DictationReleaseTail()
        let start = now()
        let frame = Duration.milliseconds(Int((DictationReleaseTail.frameDuration * 1000).rounded()))
        repeat {
            await sleep(frame)
            guard generation == mine, phase == .finalising else { return }
        } while !tail.add(frameRMS: t.takeFrameRMS(), elapsed: now() - start)
        log("dictation: release tail \(Int(((now() - start) * 1000).rounded())) ms")
    }

    /// The microphone's capture has stopped: the stop cue can no longer reach the transcript. The report arrives on the main
    /// queue and may come after the engine settled and the paste began, so only a cancel or failure (a new generation) stops it.
    private func captureClosed(generation mine: Int) {
        guard generation == mine else { return }
        cue(.stop)
    }

    private func cue(_ sound: DictationSound) {
        guard settings.sounds, !isRunActive() else { return }
        sounds.play(sound)
    }

    private func finishRecording() async {
        guard let t = transcriber else {
            phase = .idle
            return
        }
        let mine = generation
        let pressedAt = now()
        phase = .finalising
        stopSilenceWatch()
        // Still opening: wait for it. A failure to open is reported by the start.
        do { try await beginTask?.value } catch { return }
        guard generation == mine else { return }
        // The microphone opened after the press (the press came while it was opening): no tail.
        let recordedFor = openedAt.map { max(0, pressedAt - $0) } ?? 0
        await runReleaseTail(t, recordedFor: recordedFor, generation: mine)
        guard generation == mine, phase == .finalising else { return }
        // The stop cue the moment the microphone is closed, not after the engine has settled the last words (that can take a
        // moment), and not at the press (it would sound into the release tail).
        let text: String
        do {
            text = try await t.finish(onCaptureClosed: { [weak self] in self?.captureClosed(generation: mine) })
        } catch {
            fail(Self.describe(error), generation: mine)
            return
        }
        guard generation == mine, phase == .finalising else { return }
        let level = t.inputLevel
        let silent = DictationSilence.isSilent(level)
        if level.chunks == 0 { log("dictation: the microphone delivered no audio") }
        transcriber = nil
        beginTask = nil
        let clean = DictationTranscript.clean(text)
        guard !clean.isEmpty else {
            log(silent ? "dictation: the microphone gave no sound, nothing inserted" : "dictation: empty transcript, nothing inserted")
            notifier.show(silent ? .microphoneSilentNothingInserted : .nothingHeard)
            phase = .idle
            return
        }
        if silent { log("dictation: text from a microphone that read silent; inserted anyway") }
        // No suspension point from the guard above to `.inserting`: an Esc (delivered synchronously by the tap) either
        // cancelled before the guard, or arrives after the phase change, when the tap is already disarmed and it passes.
        // `add` updates memory at once; the file is written off the main actor.
        history.add(DictationRecord(text: clean, date: Date(), app: frontAppName()))
        phase = .inserting
        let mayPrompt = !settings.accessibilityPrompted
        let outcome = await inserter.insert(clean, mayPromptForPermission: mayPrompt)
        log("dictation: \(outcome.rawValue) chars=\(clean.count)")
        if outcome == .copiedToClipboard {
            if mayPrompt { settings.accessibilityPrompted = true }
            notifier.show(.copiedToClipboard)
        }
        if outcome == .notInserted { notifier.show(.notInserted) }
        phase = .idle
    }

    /// Reports an engine or microphone failure once and returns to idle.
    private func fail(_ why: String, generation mine: Int) {
        guard generation == mine, phase == .recording || phase == .finalising else { return }
        log("dictation: failed: \(why)")
        let t = transcriber
        endDictation()
        notifier.show(.failed(why))
        pendingRelease = Task { await t?.cancel() }
    }

    private func cancelCurrent(notice: DictationNotice?) {
        guard phase == .recording || phase == .finalising else { return }
        let t = transcriber
        endDictation()
        if let notice { notifier.show(notice) }
        pendingRelease = Task { await t?.cancel() }
    }

    private func endDictation() {
        stopSilenceWatch()
        generation += 1
        transcriber = nil
        beginTask = nil
        phase = .idle
    }

    private static func describe(_ error: any Error) -> String {
        (error as? ListenError)?.description ?? "\(error)"
    }
}
