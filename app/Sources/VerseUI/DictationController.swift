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

    public var text: String {
        switch self {
        case .busy: return L10n.tr("Dictation is off while Verse is listening")
        case .cancelledByRun: return L10n.tr("Dictation stopped: Verse started listening")
        case .copiedToClipboard: return L10n.tr("No Accessibility permission: the text is on the clipboard. Paste it with ⌘V.")
        case .nothingHeard: return L10n.tr("Dictation heard nothing")
        case .failed(let why): return L10n.tr("Dictation failed: \(why)")
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

    @Published public private(set) var phase: DictationPhase = .idle
    /// The hot key is registered (the feature is on and the system accepted it).
    @Published public private(set) var hotKeyRegistered = false
    /// The feature is on but the system refused the hot key (another app holds it). Settings says so.
    @Published public private(set) var hotKeyRefused = false
    /// Fn + Space is live (the feature is on and the tap is installed).
    @Published public private(set) var fnSpaceActive = false
    /// The feature is on but Fn + Space could not be installed (the Accessibility permission is missing). Settings says so.
    @Published public private(set) var fnSpaceUnavailable = false

    public let settings: DictationSettings
    /// A meeting, a practice interview or another run holds (or is about to hold) the microphone. The app wires it
    /// (`VerseController.bindDictation`).
    public var isRunActive: () -> Bool = { false }

    private let registrar: any HotKeyRegistrar
    private let keyTap: any DictationKeyTap
    private let makeTranscriber: @MainActor () -> any DictationTranscribing
    private let inserter: any DictationTextInserting
    private let notifier: any DictationNotifying
    private let sounds: any DictationSoundPlaying
    private let accessibility: any AccessibilityTrust
    private let ticker: Ticker
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

    public init(settings: DictationSettings = DictationSettings(), registrar: (any HotKeyRegistrar)? = nil,
                keyTap: (any DictationKeyTap)? = nil,
                makeTranscriber: (@MainActor () -> any DictationTranscribing)? = nil,
                inserter: (any DictationTextInserting)? = nil, notifier: (any DictationNotifying)? = nil,
                sounds: (any DictationSoundPlaying)? = nil, accessibility: (any AccessibilityTrust)? = nil,
                ticker: Ticker? = nil,
                log: @escaping (String) -> Void = { FileLog.shared.write($0) }) {
        self.settings = settings
        self.registrar = registrar ?? CarbonRegistrar()
        self.keyTap = keyTap ?? FnSpaceEventTap()
        self.makeTranscriber = makeTranscriber ?? { AppleDictationTranscriber() }
        self.inserter = inserter ?? PasteboardTextInserter()
        self.notifier = notifier ?? DictationHUD()
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
        let ok = keyTap.install { [weak self] in
            Task { await self?.press() }
        }
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
            guard on else { return }
            MainActor.assumeIsolated { self?.runBecameActive() }
        }
    }

    /// A meeting or run started: a recording (or one being finalised) is dropped and the microphone released at once.
    /// An insertion already under way finishes (the microphone is closed by then).
    public func runBecameActive() {
        guard phase == .recording || phase == .finalising else { return }
        log("dictation: cancelled, a run started")
        cancelCurrent(notice: .cancelledByRun)
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
        let t = makeTranscriber()
        transcriber = t
        phase = .recording
        log("dictation: recording lang=\(lang)")
        let task = Task { @MainActor [weak self] in
            try await t.begin(lang: lang, onFailure: { why in self?.fail(why, generation: mine) })
        }
        beginTask = task
        do {
            try await task.value
        } catch {
            fail(Self.describe(error), generation: mine)
            return
        }
        // A run that started while the microphone was opening cancels now (its own observer found nothing to cancel then,
        // or did: then this dictation is already over).
        if generation == mine, isRunActive() {
            runBecameActive()
            return
        }
        // The microphone is open now: the start cue. Not when the second press came while it was opening (the stop cue
        // follows instead) or the dictation is already over.
        if generation == mine, phase == .recording { cue(.start) }
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
        phase = .finalising
        // Still opening: wait for it. A failure to open is reported by the start.
        do { try await beginTask?.value } catch { return }
        guard generation == mine else { return }
        // The stop cue at once, not after the engine has settled the last words (that can take a moment).
        cue(.stop)
        let text: String
        do {
            text = try await t.finish()
        } catch {
            fail(Self.describe(error), generation: mine)
            return
        }
        guard generation == mine, phase == .finalising else { return }
        transcriber = nil
        beginTask = nil
        let clean = DictationTranscript.clean(text)
        guard !clean.isEmpty else {
            log("dictation: empty transcript, nothing inserted")
            notifier.show(.nothingHeard)
            phase = .idle
            return
        }
        phase = .inserting
        let mayPrompt = !settings.accessibilityPrompted
        let outcome = await inserter.insert(clean, mayPromptForPermission: mayPrompt)
        log("dictation: \(outcome.rawValue) chars=\(clean.count)")
        if outcome == .copiedToClipboard {
            if mayPrompt { settings.accessibilityPrompted = true }
            notifier.show(.copiedToClipboard)
        }
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
        generation += 1
        transcriber = nil
        beginTask = nil
        phase = .idle
    }

    private static func describe(_ error: any Error) -> String {
        (error as? ListenError)?.description ?? "\(error)"
    }
}
