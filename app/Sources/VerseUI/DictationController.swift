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

/// Dictation: ⌃⌥⌘D starts recording the microphone, ⌃⌥⌘D again stops, and the transcript is inserted where the keyboard
/// focus is. Toggle only. It never runs while a meeting or another run is active and never starts one; a run that starts
/// while it records cancels it (`observeRuns`). The hot key is registered only while the feature is on.
@MainActor
public final class DictationController: ObservableObject {
    /// The hot key's id in the shared Carbon handler (`GlobalHotKeys` uses 1 and 2).
    public static let hotKeyID: UInt32 = 3
    /// ⌃⌥⌘D. Verse holds ⌥⌘V, ⌥⌘↩, ⌥Space and ⌃⌥ plus a letter (the prompter); macOS holds ⌥⌘D (Dock) and ⌃⌘D (look up),
    /// and window managers use ⌃⌥ plus a letter. Three modifiers keep it clear of all of them.
    public static let hotKey = HotKeySpec(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey | cmdKey))
    public static let hotKeyLabel = "⌃⌥⌘D"

    @Published public private(set) var phase: DictationPhase = .idle
    /// The hot key is registered (the feature is on and the system accepted it).
    @Published public private(set) var hotKeyRegistered = false
    /// The feature is on but the system refused the hot key (another app holds it). Settings says so.
    @Published public private(set) var hotKeyRefused = false

    public let settings: DictationSettings
    /// A meeting, a practice interview or another run holds (or is about to hold) the microphone. The app wires it
    /// (`VerseController.bindDictation`).
    public var isRunActive: () -> Bool = { false }

    private let registrar: any HotKeyRegistrar
    private let makeTranscriber: @MainActor () -> any DictationTranscribing
    private let inserter: any DictationTextInserting
    private let notifier: any DictationNotifying
    private let log: (String) -> Void

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
                makeTranscriber: (@MainActor () -> any DictationTranscribing)? = nil,
                inserter: (any DictationTextInserting)? = nil, notifier: (any DictationNotifying)? = nil,
                log: @escaping (String) -> Void = { FileLog.shared.write($0) }) {
        self.settings = settings
        self.registrar = registrar ?? CarbonRegistrar()
        self.makeTranscriber = makeTranscriber ?? { AppleDictationTranscriber() }
        self.inserter = inserter ?? PasteboardTextInserter()
        self.notifier = notifier ?? DictationHUD()
        self.log = log
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
        } else {
            if let t = token {
                registrar.unregister(t)
                log("dictation: \(Self.hotKeyLabel) unregistered")
            }
            token = nil
            hotKeyRegistered = false
            hotKeyRefused = false
            cancelCurrent(notice: nil)
        }
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

    /// One press of the hot key: idle starts, recording stops and inserts. Presses while finalising or inserting are ignored.
    public func press() async {
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
        if generation == mine, isRunActive() { runBecameActive() }
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
