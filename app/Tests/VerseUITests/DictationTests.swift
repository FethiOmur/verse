import Combine
import CoreGraphics
import Foundation
import VerseSpeech
@testable import VerseUI
import XCTest

/// Dictation (Fn + Space, ⌃⌥⌘D): the controller's state machine, the run gate, the keys' registration, the Fn + Space decision,
/// the insertion paths and the transcript assembly. Everything is faked: no microphone, no key events, no event tap, no
/// pasteboard, no recognizer.
@MainActor
final class DictationTests: XCTestCase {

    // MARK: fakes

    final class FakeRegistrar: HotKeyRegistrar {
        var live: [Int: (spec: HotKeySpec, id: UInt32, action: @MainActor () -> Void)] = [:]
        var refuse: Set<UInt32> = []
        private var next = 1
        func register(_ spec: HotKeySpec, id: UInt32, action: @escaping @MainActor () -> Void) -> Int? {
            if refuse.contains(id) { return nil }
            defer { next += 1 }
            live[next] = (spec, id, action)
            return next
        }
        func unregister(_ token: Int) { live[token] = nil }
        func press(_ id: UInt32) { live.values.first { $0.id == id }?.action() }
    }

    final class FakeKeyTap: DictationKeyTap {
        var permitted = true
        private(set) var installs = 0
        private(set) var removes = 0
        private(set) var onToggle: (@MainActor @Sendable () -> Void)?
        private(set) var onRelease: (@MainActor @Sendable () -> Void)?
        private(set) var onCancel: (@MainActor @Sendable () -> Void)?
        /// Every change of the Esc arming, in order.
        private(set) var armed: [Bool] = []
        var isInstalled: Bool { onToggle != nil }
        func install(onToggle: @escaping @MainActor @Sendable () -> Void, onRelease: @escaping @MainActor @Sendable () -> Void,
                     onCancel: @escaping @MainActor @Sendable () -> Void) -> Bool {
            installs += 1
            guard permitted else { return false }
            self.onToggle = onToggle
            self.onRelease = onRelease
            self.onCancel = onCancel
            return true
        }
        func setCancelArmed(_ on: Bool) { armed.append(on) }
        func remove() { removes += 1; onToggle = nil; onRelease = nil; onCancel = nil }
    }

    struct Boom: Error, CustomStringConvertible { var description: String }

    final class FakeTranscriber: DictationTranscribing {
        var beginError: (any Error)?
        var finishText = "hello"
        var finishError: (any Error)?
        var holdBegin = false
        var holdFinish = false
        private(set) var began: [String] = []
        private(set) var vocabularies: [[String]] = []
        /// The peak `inputLevel` reports once audio flows (a real microphone in a quiet room is far above the silence floor).
        var peak: Float = 0.05
        /// Seconds of audio delivered: nil follows the clock from the open (audio flows all along); 0 = no callbacks at all.
        var audioSeconds: TimeInterval?
        /// The rig's clock.
        var now: () -> TimeInterval = { 0 }
        private var openedAt: TimeInterval = 0
        /// The RMS of each `takeFrameRMS` call by its index (0 is the drain at the stop press); nil = no audio.
        var frame: (Int) -> Float? = { _ in nil }
        private(set) var frameCalls = 0
        private(set) var finishCalls = 0
        private(set) var cancelCalls = 0
        private(set) var onFailure: (@MainActor (String) -> Void)?
        private var beginGate: CheckedContinuation<Void, Never>?
        private var finishGate: CheckedContinuation<Void, Never>?
        var beginHeld: Bool { beginGate != nil }
        var finishHeld: Bool { finishGate != nil }

        func begin(lang: String, vocabulary: [String], onFailure: @escaping @MainActor (String) -> Void) async throws {
            began.append(lang)
            vocabularies.append(vocabulary)
            self.onFailure = onFailure
            if holdBegin { await withCheckedContinuation { beginGate = $0 } }
            if let beginError { throw beginError }
            openedAt = now()
        }
        var inputLevel: DictationInputLevel {
            let secs = audioSeconds ?? max(0, now() - openedAt)
            guard secs > 0 else { return DictationInputLevel(peak: 0, audioSeconds: 0, chunks: 0) }
            return DictationInputLevel(peak: peak, audioSeconds: secs, chunks: max(1, Int(secs * 100)))
        }
        func takeFrameRMS() -> Float? {
            defer { frameCalls += 1 }
            return frame(frameCalls)
        }
        /// The capture closes at once (as `ListenSession.stop` stops the source first), then the engine settles.
        /// The capture-closed report arrives late (the real one is a main-queue hop): kept until the test calls it.
        var reportCaptureLate = false
        private(set) var lateCaptureReport: (@MainActor @Sendable () -> Void)?
        func finish(onCaptureClosed: @escaping @MainActor @Sendable () -> Void) async throws -> String {
            finishCalls += 1
            if reportCaptureLate { lateCaptureReport = onCaptureClosed } else { onCaptureClosed() }
            if holdFinish { await withCheckedContinuation { finishGate = $0 } }
            if let finishError { throw finishError }
            return finishText
        }
        func cancel() async { cancelCalls += 1 }
        /// The recording indicator's live text and level (gap G5).
        var liveText = ""
        var meterLevel: Float?
        func takeMeterLevel() -> Float? { meterLevel }
        func releaseBegin() { beginGate?.resume(); beginGate = nil }
        func releaseFinish() { finishGate?.resume(); finishGate = nil }
        func failNow(_ why: String) { onFailure?(why) }
    }

    final class FakeInserter: DictationTextInserting {
        var outcome = DictationInsertOutcome.pasted
        private(set) var calls: [(text: String, mayPrompt: Bool)] = []
        /// The smart-insertion options of each call (gap G13), in order.
        private(set) var formattings: [DictationInsertFormatting?] = []
        func insert(_ text: String, mayPromptForPermission: Bool) async -> DictationInsertOutcome {
            await insert(text, mayPromptForPermission: mayPromptForPermission, formatting: nil)
        }
        func insert(_ text: String, mayPromptForPermission: Bool,
                    formatting: DictationInsertFormatting?) async -> DictationInsertOutcome {
            calls.append((text, mayPromptForPermission))
            formattings.append(formatting)
            return outcome
        }
    }

    final class FakeNotifier: DictationNotifying {
        private(set) var notices: [DictationNotice] = []
        func show(_ notice: DictationNotice) { notices.append(notice) }
    }

    final class FakeAccessibility: AccessibilityTrust {
        var trusted: Bool
        private(set) var asked: [Bool] = []
        init(trusted: Bool) { self.trusted = trusted }
        func isTrusted(prompt: Bool) -> Bool { asked.append(prompt); return trusted }
    }

    final class FakePasteboard: DictationPasteboard {
        var items: [[String: Data]] = []
        private(set) var changeCount = 0
        private(set) var transientWrites = 0
        var string: String? { items.first?["public.utf8-plain-text"].flatMap { String(data: $0, encoding: .utf8) } }
        func snapshot() -> PasteboardSnapshot { PasteboardSnapshot(items: items) }
        func write(_ text: String, transient: Bool) -> Int {
            items = [["public.utf8-plain-text": Data(text.utf8)]]
            if transient { transientWrites += 1 }
            changeCount += 1
            return changeCount
        }
        func restore(_ snapshot: PasteboardSnapshot) {
            items = snapshot.items
            changeCount += 1
        }
        /// Someone else copies something.
        func externalCopy(_ text: String) {
            items = [["public.utf8-plain-text": Data(text.utf8)]]
            changeCount += 1
        }
    }

    final class FakeKeystroke: PasteKeystroke {
        private(set) var posted = 0
        private(set) var waited = 0
        var onPost: (() -> Void)?
        func waitForModifierRelease() async { waited += 1 }
        func postPaste() { posted += 1; onPost?() }
    }

    final class Box<T> { var value: T; init(_ v: T) { value = v } }

    final class FakeSounds: DictationSoundPlaying {
        private(set) var played: [DictationSound] = []
        func play(_ sound: DictationSound) { played.append(sound) }
    }

    /// The permission watch's timer, fired by hand.
    @MainActor
    final class FakeTicker {
        private(set) var intervals: [TimeInterval] = []
        private var ticks: [Int: @MainActor @Sendable () -> Void] = [:]
        private var next = 0
        var running: Int { ticks.count }
        func make(_ interval: TimeInterval, _ tick: @escaping @MainActor @Sendable () -> Void) -> AnyCancellable {
            intervals.append(interval)
            let id = next
            next += 1
            ticks[id] = tick
            return AnyCancellable { [weak self] in MainActor.assumeIsolated { _ = self?.ticks.removeValue(forKey: id) } }
        }
        func fire() { for t in Array(ticks.values) { t() } }
    }

    /// The controller's clock: time moves only when the controller sleeps (or a test sets it). `onSleep` runs after each
    /// sleep with the number of sleeps so far.
    @MainActor
    final class FakeClock {
        var t: TimeInterval = 0
        private(set) var sleeps: [Duration] = []
        var onSleep: ((Int) -> Void)?
        func sleep(_ d: Duration) {
            sleeps.append(d)
            t += Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            onSleep?(sleeps.count)
        }
    }

    func defaults() -> UserDefaults {
        let name = "verse.dictation.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    struct Rig {
        let controller: DictationController
        let settings: DictationSettings
        let registrar: FakeRegistrar
        let keyTap: FakeKeyTap
        let inserter: FakeInserter
        let notifier: FakeNotifier
        let made: Box<[FakeTranscriber]>
        let sounds: FakeSounds
        let ax: FakeAccessibility
        let ticker: FakeTicker
        let logs: Box<[String]>
        let clock: FakeClock
        let history: DictationHistory
        let pasteboard: FakePasteboard
        let frontApp: Box<String?>
        /// The bundle id of the app in front (gap G12).
        let frontBundle: Box<String?>
        let indicatorTicker: FakeTicker
        var last: FakeTranscriber? { made.value.last }
    }

    /// A controller with every dependency faked. `prepare` configures each transcriber as it is made.
    func rig(enabled: Bool = true, lang: String = "en", inserter: (any DictationTextInserting)? = nil,
             history: DictationHistory? = nil, returnKey: (any DictationReturnKeyPosting)? = nil,
             prepare: @escaping (FakeTranscriber) -> Void = { _ in }) -> Rig {
        let settings = DictationSettings(defaults: defaults())
        settings.enabled = enabled
        settings.language = lang
        let reg = FakeRegistrar(), tap = FakeKeyTap(), fakeInserter = FakeInserter(), notifier = FakeNotifier()
        let made = Box<[FakeTranscriber]>([])
        let sounds = FakeSounds(), ax = FakeAccessibility(trusted: false), ticker = FakeTicker(), logs = Box<[String]>([])
        let clock = FakeClock(), store = history ?? DictationHistory(fileURL: nil), pb = FakePasteboard()
        let frontApp = Box<String?>("Notes")
        let frontBundle = Box<String?>("com.example.notes")
        let indicatorTicker = FakeTicker()
        let c = DictationController(settings: settings, registrar: reg, keyTap: tap, makeTranscriber: {
            let t = FakeTranscriber()
            t.now = { clock.t }
            prepare(t)
            made.value.append(t)
            return t
        }, inserter: inserter ?? fakeInserter, notifier: notifier, sounds: sounds, accessibility: ax,
           ticker: { ticker.make($0, $1) }, history: store, pasteboard: pb, frontAppName: { frontApp.value },
           now: { clock.t }, sleep: { d in await clock.sleep(d) }, indicatorTicker: { indicatorTicker.make($0, $1) },
           presentsIndicator: false, returnKey: returnKey ?? FakeReturnKey(), frontAppBundleID: { frontBundle.value },
           frontApp: DictationFrontAppTracker(observe: false), log: { logs.value.append($0) })
        return Rig(controller: c, settings: settings, registrar: reg, keyTap: tap, inserter: fakeInserter, notifier: notifier,
                   made: made, sounds: sounds, ax: ax, ticker: ticker, logs: logs, clock: clock, history: store, pasteboard: pb,
                   frontApp: frontApp, frontBundle: frontBundle, indicatorTicker: indicatorTicker)
    }

    private func waitUntil(_ what: String = "condition", _ cond: () -> Bool) async {
        for _ in 0..<2000 {
            if cond() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for \(what)")
    }

    // MARK: state machine

    func testOnePressRecordsTheNextFinalisesInsertsAndReturnsToIdle() async {
        let r = rig(lang: "tr") { $0.finishText = "  Merhaba dünya, çok güzel 👋\nİkinci satır  " }
        let phases = Box<[DictationPhase]>([])
        let sub = r.controller.$phase.sink { phases.value.append($0) }
        defer { sub.cancel() }

        await r.controller.press()
        XCTAssertEqual(r.controller.phase, .recording)
        XCTAssertEqual(r.last?.began, ["tr"], "the dictation language from Settings")
        XCTAssertTrue(r.inserter.calls.isEmpty)

        await r.controller.press()
        XCTAssertEqual(phases.value, [.idle, .recording, .finalising, .inserting, .idle])
        XCTAssertEqual(r.last?.finishCalls, 1)
        XCTAssertEqual(r.inserter.calls.map(\.text), ["Merhaba dünya, çok güzel 👋\nİkinci satır"],
                       "trimmed at the ends; Turkish letters, emoji and the line break untouched")
        XCTAssertEqual(r.last?.cancelCalls, 0)
        XCTAssertTrue(r.notifier.notices.isEmpty)
        XCTAssertEqual(r.made.value.count, 1)
    }

    func testASecondPressWhileTheMicrophoneIsStillOpeningWaitsForItThenFinishes() async {
        let r = rig { $0.holdBegin = true; $0.finishText = "quick" }
        let first = Task { await r.controller.press() }
        await waitUntil("begin held") { r.last?.beginHeld == true }
        XCTAssertEqual(r.controller.phase, .recording)
        let second = Task { await r.controller.press() }
        await waitUntil("finalising") { r.controller.phase == .finalising }
        XCTAssertEqual(r.last?.finishCalls, 0, "finish waits for begin")
        r.last?.releaseBegin()
        await first.value
        await second.value
        XCTAssertEqual(r.inserter.calls.map(\.text), ["quick"])
        XCTAssertEqual(r.controller.phase, .idle)
    }

    func testPressesWhileFinalisingAreIgnored() async {
        let r = rig { $0.holdFinish = true }
        await r.controller.press()
        let stop = Task { await r.controller.press() }
        await waitUntil("finish held") { r.last?.finishHeld == true }
        await r.controller.press()
        XCTAssertEqual(r.made.value.count, 1, "no second dictation")
        XCTAssertEqual(r.last?.finishCalls, 1)
        r.last?.releaseFinish()
        await stop.value
        XCTAssertEqual(r.inserter.calls.count, 1)
    }

    // MARK: runs

    func testPressingWhileARunIsActiveDoesNothingButANotice() async {
        let r = rig()
        r.controller.isRunActive = { true }
        await r.controller.press()
        XCTAssertEqual(r.controller.phase, .idle)
        XCTAssertTrue(r.made.value.isEmpty, "no microphone opened")
        XCTAssertEqual(r.notifier.notices, [.busy])
        XCTAssertTrue(r.inserter.calls.isEmpty)
    }

    func testARunStartingWhileRecordingCancelsWithoutInserting() async {
        let r = rig()
        let runs = PassthroughSubject<Bool, Never>()
        r.controller.observeRuns(runs)
        await r.controller.press()
        XCTAssertEqual(r.controller.phase, .recording)

        runs.send(true)
        XCTAssertEqual(r.controller.phase, .idle)
        await r.controller.pendingRelease?.value
        XCTAssertEqual(r.last?.cancelCalls, 1, "the microphone is released")
        XCTAssertEqual(r.last?.finishCalls, 0)
        XCTAssertTrue(r.inserter.calls.isEmpty)
        XCTAssertEqual(r.notifier.notices, [.cancelledByRun])

        // The run ends: the next press is a new dictation.
        runs.send(false)
        await r.controller.press()
        XCTAssertEqual(r.made.value.count, 2)
        XCTAssertEqual(r.controller.phase, .recording)
    }

    func testARunStartingWhileFinalisingDropsTheText() async {
        let r = rig { $0.holdFinish = true; $0.finishText = "never typed" }
        await r.controller.press()
        let stop = Task { await r.controller.press() }
        await waitUntil("finish held") { r.last?.finishHeld == true }
        r.controller.runBecameActive()
        XCTAssertEqual(r.controller.phase, .idle)
        r.last?.releaseFinish()
        await stop.value
        XCTAssertTrue(r.inserter.calls.isEmpty, "the late transcript is not inserted")
        XCTAssertEqual(r.notifier.notices, [.cancelledByRun])
        XCTAssertEqual(r.controller.phase, .idle)
    }

    func testARunThatStartedWhileTheMicrophoneWasOpeningCancelsOnceItIsOpen() async {
        let r = rig { $0.holdBegin = true }
        let active = Box(false)
        r.controller.isRunActive = { active.value }
        let press = Task { await r.controller.press() }
        await waitUntil("begin held") { r.last?.beginHeld == true }
        active.value = true          // the run's own observer would also fire; here only the state changed
        r.last?.releaseBegin()
        await press.value
        XCTAssertEqual(r.controller.phase, .idle)
        await r.controller.pendingRelease?.value
        XCTAssertEqual(r.last?.cancelCalls, 1)
        XCTAssertEqual(r.notifier.notices, [.cancelledByRun])
    }

    /// The app's gate: a meeting running or stopping, a practice interview, or the open prompter blocks dictation.
    func testTheVerseControllerGateFollowsMeetingAndPractice() async {
        let d = defaults()
        let c = VerseController(settings: AppSettings(defaults: d), launch: LaunchOptions(arguments: []))
        let sim = SimController(settings: c.settings, simSettings: SimSettings(defaults: d), meeting: c)
        let r = rig()
        c.dictation = r.controller
        c.bindDictation(practice: sim)
        XCTAssertFalse(r.controller.isRunActive())

        sim.setPhaseForPreview(.running)
        XCTAssertTrue(r.controller.isRunActive(), "a practice interview holds the microphone")
        await r.controller.press()
        XCTAssertTrue(r.made.value.isEmpty)
        sim.setPhaseForPreview(.finished)
        XCTAssertFalse(r.controller.isRunActive())

        await r.controller.press()
        XCTAssertEqual(r.controller.phase, .recording)
        c.setRunningForPreview(true)
        XCTAssertEqual(r.controller.phase, .idle, "a meeting starting cancels the dictation")
        XCTAssertTrue(r.controller.isRunActive())
        XCTAssertEqual(r.notifier.notices, [.busy, .cancelledByRun])
        c.setRunningForPreview(false)
        XCTAssertFalse(r.controller.isRunActive())
    }

    func testGateTruthTable() {
        XCTAssertFalse(VerseController.dictationBlocked(running: false, stopping: false, practiceRunning: false, prompterOpen: false))
        XCTAssertTrue(VerseController.dictationBlocked(running: true, stopping: false, practiceRunning: false, prompterOpen: false))
        XCTAssertTrue(VerseController.dictationBlocked(running: false, stopping: true, practiceRunning: false, prompterOpen: false))
        XCTAssertTrue(VerseController.dictationBlocked(running: false, stopping: false, practiceRunning: true, prompterOpen: false))
        XCTAssertTrue(VerseController.dictationBlocked(running: false, stopping: false, practiceRunning: false, prompterOpen: true))
    }

    // MARK: hot key

    func testFeatureOffRegistersNoHotKey() async {
        let r = rig(enabled: false)
        r.controller.activate()
        XCTAssertTrue(r.registrar.live.isEmpty)
        XCTAssertFalse(r.controller.hotKeyRegistered)
        XCTAssertFalse(r.controller.hotKeyRefused)
        await r.controller.press()
        XCTAssertTrue(r.made.value.isEmpty, "off: even a direct press does nothing")
    }

    func testTurningTheFeatureOnAndOffRegistersAndUnregisters() async {
        let r = rig(enabled: false)
        r.controller.activate()
        r.settings.enabled = true
        XCTAssertEqual(r.registrar.live.count, 1)
        XCTAssertEqual(r.registrar.live.values.first?.id, DictationController.hotKeyID)
        XCTAssertEqual(r.registrar.live.values.first?.spec, DictationController.hotKey)
        XCTAssertTrue(r.controller.hotKeyRegistered)
        r.settings.enabled = true
        XCTAssertEqual(r.registrar.live.count, 1, "no duplicate registration")

        // The key's action presses.
        r.registrar.press(DictationController.hotKeyID)
        await waitUntil("recording") { r.controller.phase == .recording }

        // Off while recording: unregistered and the dictation dropped.
        r.settings.enabled = false
        XCTAssertTrue(r.registrar.live.isEmpty)
        XCTAssertFalse(r.controller.hotKeyRegistered)
        XCTAssertEqual(r.controller.phase, .idle)
        await r.controller.pendingRelease?.value
        XCTAssertEqual(r.last?.cancelCalls, 1)
        XCTAssertTrue(r.inserter.calls.isEmpty)

        r.settings.enabled = true
        XCTAssertEqual(r.registrar.live.count, 1)
        r.controller.deactivate()
        XCTAssertTrue(r.registrar.live.isEmpty)
    }

    func testARefusedHotKeyIsReportedForSettings() {
        let r = rig(enabled: true)
        r.registrar.refuse = [DictationController.hotKeyID]
        r.controller.activate()
        XCTAssertFalse(r.controller.hotKeyRegistered)
        XCTAssertTrue(r.controller.hotKeyRefused)
        r.settings.enabled = false
        XCTAssertFalse(r.controller.hotKeyRefused, "off is not refused")
    }

    func testTheHotKeyIsNoneOfVersesOwn() {
        let k = DictationController.hotKey
        XCTAssertNotEqual(k, HotKeySpec.startStop)
        XCTAssertNotEqual(k, HotKeySpec.cardNow)
        XCTAssertEqual(k.keyCode, 2, "D")
        XCTAssertEqual(k.modifiers, UInt32(0x1000 | 0x0800 | 0x0100), "control + option + command")
        // The prompter's keys are ⌃⌥ + a letter and the practice key is ⌥Space: the extra ⌘ keeps them distinct.
        XCTAssertNotEqual(k.modifiers, UInt32(0x1000 | 0x0800), "not the prompter's ⌃⌥")
        XCTAssertNotEqual(k.modifiers, UInt32(0x0800 | 0x0100), "not ⌥⌘ (⌥⌘D is the Dock)")
        XCTAssertNotEqual(DictationController.hotKeyID, GlobalHotKeys.startStopID)
        XCTAssertNotEqual(DictationController.hotKeyID, GlobalHotKeys.cardNowID)
    }

    // MARK: insertion

    func testMissingAccessibilityPutsTheTextOnTheClipboardAndPromptsOnce() async {
        let ax = FakeAccessibility(trusted: false), pb = FakePasteboard(), keys = FakeKeystroke()
        pb.externalCopy("what was there")
        let inserter = PasteboardTextInserter(accessibility: ax, pasteboard: pb, keystroke: keys, focus: FakeFocus(.unverifiableWeb), sleep: { _ in })
        let r = rig(inserter: inserter) { $0.finishText = "Şu an çalışmıyor" }

        await r.controller.press()
        await r.controller.press()
        XCTAssertEqual(pb.string, "Şu an çalışmıyor", "left on the clipboard")
        XCTAssertEqual(pb.transientWrites, 0, "kept by clipboard managers: the owner needs it")
        XCTAssertEqual(keys.posted, 0, "no key event without the permission")
        XCTAssertEqual(r.notifier.notices, [.copiedToClipboard])
        XCTAssertEqual(ax.asked, [true], "the system prompt is asked for the first time")
        XCTAssertTrue(r.settings.accessibilityPrompted)

        await r.controller.press()
        await r.controller.press()
        XCTAssertEqual(ax.asked, [true, false], "and never again")
        XCTAssertEqual(r.notifier.notices, [.copiedToClipboard, .copiedToClipboard])
        XCTAssertEqual(r.controller.phase, .idle)
    }

    func testPasteRestoresThePreviousClipboard() async {
        let ax = FakeAccessibility(trusted: true), pb = FakePasteboard(), keys = FakeKeystroke()
        let original: [[String: Data]] = [["public.utf8-plain-text": Data("old".utf8), "public.html": Data("<b>old</b>".utf8)],
                                          ["public.png": Data([0x89, 0x50, 0x4E, 0x47])]]
        pb.items = original
        let atPost = Box<String?>(nil)
        keys.onPost = { atPost.value = pb.string }
        let inserter = PasteboardTextInserter(accessibility: ax, pasteboard: pb, keystroke: keys, focus: FakeFocus(.unverifiableWeb), sleep: { _ in })

        let outcome = await inserter.insert("Ciao, com'è? 🇮🇹\nRiga due", mayPromptForPermission: true)
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(keys.waited, 1)
        XCTAssertEqual(keys.posted, 1)
        XCTAssertEqual(atPost.value, "Ciao, com'è? 🇮🇹\nRiga due", "the pasteboard held the text when ⌘V went out")
        XCTAssertEqual(pb.transientWrites, 1)
        XCTAssertEqual(pb.items, original, "every item and type came back")
        XCTAssertEqual(ax.asked, [true])
    }

    func testSomethingCopiedDuringThePasteIsNotOverwritten() async {
        let ax = FakeAccessibility(trusted: true), pb = FakePasteboard(), keys = FakeKeystroke()
        pb.externalCopy("old")
        let inserter = PasteboardTextInserter(accessibility: ax, pasteboard: pb, keystroke: keys, focus: FakeFocus(.unverifiableWeb), sleep: { _ in
            await MainActor.run { pb.externalCopy("newer") }
        })
        _ = await inserter.insert("dictated", mayPromptForPermission: false)
        XCTAssertEqual(pb.string, "newer")
    }

    func testAnEmptyTextInsertsNothing() async {
        let ax = FakeAccessibility(trusted: true), pb = FakePasteboard(), keys = FakeKeystroke()
        let inserter = PasteboardTextInserter(accessibility: ax, pasteboard: pb, keystroke: keys, focus: FakeFocus(.unverifiableWeb), sleep: { _ in })
        let outcome = await inserter.insert("", mayPromptForPermission: true)
        XCTAssertEqual(outcome, .nothing)
        XCTAssertEqual(pb.changeCount, 0)
        XCTAssertTrue(ax.asked.isEmpty)
    }

    func testAnEmptyTranscriptInsertsNothing() async {
        let r = rig { $0.finishText = "  \n\t " }
        await r.controller.press()
        await r.controller.press()
        XCTAssertTrue(r.inserter.calls.isEmpty)
        XCTAssertEqual(r.notifier.notices, [.nothingHeard])
        XCTAssertEqual(r.controller.phase, .idle)
    }

    // MARK: failures

    func testAStartFailureReturnsToIdleAndReportsOnce() async {
        let r = rig { $0.beginError = ListenError.permissionDenied(.microphone) }
        await r.controller.press()
        XCTAssertEqual(r.controller.phase, .idle)
        XCTAssertEqual(r.notifier.notices.count, 1)
        guard case .failed? = r.notifier.notices.first else { return XCTFail("a failure notice") }
        XCTAssertTrue(r.inserter.calls.isEmpty)
    }

    func testAMidRecordingEngineErrorReturnsToIdleAndReportsOnce() async {
        let r = rig()
        await r.controller.press()
        r.last?.failNow("speech failed")
        r.last?.failNow("speech failed again")
        XCTAssertEqual(r.controller.phase, .idle)
        XCTAssertEqual(r.notifier.notices, [.failed("speech failed")])
        await r.controller.pendingRelease?.value
        XCTAssertEqual(r.last?.cancelCalls, 1, "the microphone is released")

        // The key works again.
        await r.controller.press()
        XCTAssertEqual(r.controller.phase, .recording)
        XCTAssertEqual(r.made.value.count, 2)
        // A late failure report of the old dictation changes nothing.
        r.made.value[0].failNow("late")
        XCTAssertEqual(r.controller.phase, .recording)
        XCTAssertEqual(r.notifier.notices.count, 1)
    }

    func testAFinishErrorReturnsToIdleAndReportsOnce() async {
        let r = rig { $0.finishError = Boom(description: "flush failed") }
        await r.controller.press()
        await r.controller.press()
        XCTAssertEqual(r.controller.phase, .idle)
        XCTAssertEqual(r.notifier.notices, [.failed("flush failed")])
        XCTAssertTrue(r.inserter.calls.isEmpty)
    }

    // MARK: transcript and engine configuration

    func testTranscriptJoinsFinalsAndKeepsAnUncoveredVolatileTail() {
        var t = DictationTranscript()
        t.add(text: "Hello", isFinal: false, start: 0, end: 0.5)
        t.add(text: " Hello there.", isFinal: true, start: 0, end: 1.0)
        t.add(text: "How are", isFinal: false, start: 1.1, end: 1.6)
        XCTAssertEqual(t.text, "Hello there. How are")
        t.add(text: "How are you?", isFinal: true, start: 1.1, end: 2.0)
        XCTAssertEqual(t.text, "Hello there. How are you?")
        t.add(text: "you", isFinal: false, start: 1.5, end: 1.9)
        XCTAssertEqual(t.text, "Hello there. How are you?", "a volatile guess for audio a final covers is dropped")
        XCTAssertEqual(DictationTranscript().text, "")
    }

    func testOnlyUnrecoverableIssuesEndADictation() {
        XCTAssertTrue(DictationTranscript.isFatal(.permissionDenied(.microphone)))
        XCTAssertTrue(DictationTranscript.isFatal(.speechFailed(.me, "x")))
        XCTAssertTrue(DictationTranscript.isFatal(.captureFailed(.me, "x")))
        XCTAssertFalse(DictationTranscript.isFatal(.speechRecovered(.me, "x")))
        XCTAssertFalse(DictationTranscript.isFatal(.captureRecovered(.me, "x")))
        XCTAssertFalse(DictationTranscript.isFatal(.deadStream(.me)), "a silent microphone gives an empty transcript instead")
    }

    func testTheAppleTranscriberUsesTheMicrophoneAloneAndTheLanguagesAppleEngine() throws {
        for (lang, kind) in [("en", EngineKind.speechTranscriber), ("it", .speechTranscriber), ("tr", .dictationTranscriber)] {
            let c = AppleDictationTranscriber.config(lang: lang)
            XCTAssertEqual(c.lang, lang)
            XCTAssertEqual(c.engineKind, kind, "never Nemotron: no model load, the meeting's pool untouched")
            XCTAssertTrue(c.micEnabled)
            XCTAssertTrue(c.remoteBundleIDs.isEmpty)
            XCTAssertFalse(c.releaseIdleModelsOnStop)
            XCTAssertNil(c.statusSink)
            XCTAssertNil(try AppleDictationTranscriber.environment(meter: DictationInputMeter()).makeRemoteSource(c),
                         "no process tap, no system audio")
        }
    }

    // MARK: settings

    func testSettingsAreOffByDefaultAndPersist() {
        let d = defaults()
        let s = DictationSettings(defaults: d, preferredLanguages: ["en-US"])
        XCTAssertFalse(s.enabled)
        XCTAssertEqual(s.language, "en")
        XCTAssertFalse(s.accessibilityPrompted)
        s.enabled = true
        s.language = "tr"
        s.accessibilityPrompted = true
        let again = DictationSettings(defaults: d, preferredLanguages: ["it-IT"])
        XCTAssertTrue(again.enabled)
        XCTAssertEqual(again.language, "tr", "a chosen language wins over the system's")
        XCTAssertTrue(again.accessibilityPrompted)
        d.set("de", forKey: "dictationLanguage")
        XCTAssertEqual(DictationSettings(defaults: d, preferredLanguages: ["en-US"]).language, "en", "an unknown language falls back")
        XCTAssertEqual(DictationSettings(defaults: d, preferredLanguages: ["tr-TR"]).language, "tr",
                       "to the system's language, not always English")
    }

    func testTheDefaultLanguageIsTheFirstSupportedPreferredLanguage() {
        let table: [([String], String)] = [
            (["tr-TR", "en-US"], "tr"),
            (["en-GB", "tr-TR"], "en"),
            (["it_IT"], "it"),
            (["de-DE", "tr-TR"], "tr"),
            (["de-DE", "fr-FR"], "en"),
            (["tr"], "tr"),
            ([], "en"),
        ]
        for (preferred, want) in table {
            XCTAssertEqual(DictationSettings.defaultLanguage(preferred: preferred), want, "\(preferred)")
        }
        let d = defaults()
        XCTAssertEqual(DictationSettings(defaults: d, preferredLanguages: ["tr-TR", "en-US"]).language, "tr",
                       "a first dictation on a Turkish Mac listens in Turkish")
        XCTAssertNil(d.string(forKey: "dictationLanguage"), "the default is not stored: it follows the system until chosen")
    }

    // MARK: Fn + Space

    private static let fn = CGEventFlags.maskSecondaryFn
    private static let space = FnSpaceFilter.spaceKeyCode

    func testFnSpaceDecisionTable() {
        struct Row { let type: CGEventType; let key: Int64; let flags: CGEventFlags; let isRepeat: Bool; let want: FnSpaceDecision; let why: String }
        let rows: [Row] = [
            Row(type: .keyDown, key: Self.space, flags: Self.fn, isRepeat: false, want: .toggle, why: "Fn + Space"),
            Row(type: .keyDown, key: Self.space, flags: [Self.fn, .maskAlphaShift], isRepeat: false, want: .toggle, why: "Caps Lock does not count"),
            Row(type: .keyDown, key: Self.space, flags: [Self.fn, .maskNumericPad], isRepeat: false, want: .toggle, why: "the numeric-pad flag does not count"),
            Row(type: .keyDown, key: Self.space, flags: [Self.fn, .maskNonCoalesced], isRepeat: false, want: .toggle, why: "the non-coalesced bit real key events carry"),
            Row(type: .keyDown, key: Self.space, flags: CGEventFlags(rawValue: 0x80_0100), isRepeat: false, want: .toggle, why: "raw Fn + Space flags as a keyboard sends them"),
            Row(type: .keyDown, key: Self.space, flags: CGEventFlags(rawValue: 0xA0_0100), isRepeat: false, want: .toggle, why: "raw Fn + numeric pad + non-coalesced"),
            Row(type: .keyDown, key: Self.space, flags: [Self.fn, .maskNumericPad, .maskNonCoalesced, .maskHelp], isRepeat: false, want: .toggle, why: "other non-modifier bits do not count"),
            Row(type: .keyDown, key: Self.space, flags: CGEventFlags(rawValue: 0x80_0108 | CGEventFlags.maskCommand.rawValue), isRepeat: false, want: .pass, why: "raw Fn ⌘ Space with the left-⌘ device bit"),
            Row(type: .keyDown, key: Self.space, flags: [], isRepeat: false, want: .pass, why: "a plain space is typed"),
            Row(type: .keyDown, key: Self.space, flags: [Self.fn, .maskShift], isRepeat: false, want: .pass, why: "Fn ⇧ Space is another combination"),
            Row(type: .keyDown, key: Self.space, flags: [Self.fn, .maskControl], isRepeat: false, want: .pass, why: "Fn ⌃ Space"),
            Row(type: .keyDown, key: Self.space, flags: [Self.fn, .maskAlternate], isRepeat: false, want: .pass, why: "Fn ⌥ Space"),
            Row(type: .keyDown, key: Self.space, flags: [Self.fn, .maskCommand], isRepeat: false, want: .pass, why: "Fn ⌘ Space"),
            Row(type: .keyDown, key: Self.space, flags: .maskCommand, isRepeat: false, want: .pass, why: "⌘ Space (Spotlight)"),
            Row(type: .keyDown, key: Self.space, flags: Self.fn, isRepeat: true, want: .pass, why: "a repeat never toggles"),
            Row(type: .keyDown, key: 2, flags: Self.fn, isRepeat: false, want: .pass, why: "Fn + D is not ours"),
            Row(type: .keyDown, key: 123, flags: Self.fn, isRepeat: false, want: .pass, why: "arrow keys carry the Fn flag by themselves"),
            Row(type: .keyUp, key: Self.space, flags: Self.fn, isRepeat: false, want: .pass, why: "a key-up alone is not ours"),
            Row(type: .flagsChanged, key: 63, flags: Self.fn, isRepeat: false, want: .pass, why: "the Fn key itself"),
        ]
        for r in rows {
            var f = FnSpaceFilter()
            XCTAssertEqual(f.decide(type: r.type, keyCode: r.key, flags: r.flags, isRepeat: r.isRepeat), r.want, r.why)
        }
    }

    func testAHeldFnSpaceTogglesOnceAndSwallowsItsRepeatsAndKeyUp() {
        var f = FnSpaceFilter()
        XCTAssertEqual(f.decide(type: .keyDown, keyCode: Self.space, flags: Self.fn, isRepeat: false), .toggle)
        XCTAssertEqual(f.decide(type: .keyDown, keyCode: Self.space, flags: Self.fn, isRepeat: true), .swallow)
        XCTAssertEqual(f.decide(type: .keyDown, keyCode: Self.space, flags: [], isRepeat: true), .swallow,
                       "Fn let go first: the held space still types nothing")
        XCTAssertEqual(f.decide(type: .keyDown, keyCode: 0, flags: [], isRepeat: false), .pass, "other keys meanwhile are untouched")
        XCTAssertEqual(f.decide(type: .keyUp, keyCode: Self.space, flags: [], isRepeat: false), .release,
                       "dropped, and the end of the hold is reported (gap G8)")
        XCTAssertFalse(f.swallowing)
        XCTAssertEqual(f.decide(type: .keyUp, keyCode: Self.space, flags: [], isRepeat: false), .pass, "only the one key-up")
        // A plain space afterwards is typed, repeats included.
        XCTAssertEqual(f.decide(type: .keyDown, keyCode: Self.space, flags: [], isRepeat: false), .pass)
        XCTAssertEqual(f.decide(type: .keyDown, keyCode: Self.space, flags: [], isRepeat: true), .pass)
        XCTAssertEqual(f.decide(type: .keyUp, keyCode: Self.space, flags: [], isRepeat: false), .pass)
        // The second press stops.
        XCTAssertEqual(f.decide(type: .keyDown, keyCode: Self.space, flags: Self.fn, isRepeat: false), .toggle)
    }

    func testFnSpaceIsInstalledOnlyWhileDictationIsOnAndToggles() async {
        let r = rig(enabled: false)
        r.controller.refreshFnSpace()
        XCTAssertEqual(r.keyTap.installs, 0, "nothing before activation")
        r.controller.activate()
        XCTAssertEqual(r.keyTap.installs, 0, "off: no tap")
        XCTAssertFalse(r.controller.fnSpaceActive)

        r.settings.enabled = true
        XCTAssertTrue(r.keyTap.isInstalled)
        XCTAssertTrue(r.controller.fnSpaceActive)
        XCTAssertFalse(r.controller.fnSpaceUnavailable)
        r.controller.refreshFnSpace()
        XCTAssertEqual(r.keyTap.installs, 1, "no second tap")

        r.keyTap.onToggle?()
        await waitUntil("recording") { r.controller.phase == .recording }
        r.keyTap.onToggle?()
        await waitUntil("inserted") { r.inserter.calls.count == 1 }
        XCTAssertEqual(r.controller.phase, .idle)

        r.settings.enabled = false
        XCTAssertFalse(r.keyTap.isInstalled, "removed when dictation is turned off")
        XCTAssertEqual(r.keyTap.removes, 1)
        XCTAssertFalse(r.controller.fnSpaceActive)
        r.settings.enabled = true
        XCTAssertTrue(r.keyTap.isInstalled)
        r.controller.deactivate()
        XCTAssertFalse(r.keyTap.isInstalled)
    }

    func testWithoutThePermissionOnlyTheHotKeyWorksUntilItIsGranted() async {
        let r = rig(enabled: true)
        r.keyTap.permitted = false
        r.controller.activate()
        XCTAssertFalse(r.controller.fnSpaceActive)
        XCTAssertTrue(r.controller.fnSpaceUnavailable, "Settings says what to grant")
        XCTAssertTrue(r.controller.hotKeyRegistered, "⌃⌥⌘D does not need it")

        r.registrar.press(DictationController.hotKeyID)
        await waitUntil("recording") { r.controller.phase == .recording }
        XCTAssertFalse(r.controller.fnSpaceActive)

        // Granted in System Settings: the next press (or the Settings page) installs the tap.
        r.keyTap.permitted = true
        r.registrar.press(DictationController.hotKeyID)
        await waitUntil("inserted") { r.inserter.calls.count == 1 }
        XCTAssertTrue(r.controller.fnSpaceActive)
        XCTAssertFalse(r.controller.fnSpaceUnavailable)
    }

    func testFnSpaceWhileVerseListensDoesNothingButANotice() async {
        let r = rig(enabled: true)
        r.controller.isRunActive = { true }
        r.controller.activate()
        r.keyTap.onToggle?()
        await waitUntil("notice") { !r.notifier.notices.isEmpty }
        XCTAssertEqual(r.notifier.notices, [.busy])
        XCTAssertTrue(r.made.value.isEmpty)
    }

    func testTheSettingsTextsNameBothKeys() {
        for s in [SettingsDictationSection.status(hotKeyRefused: false, fnSpaceActive: true),
                  SettingsDictationSection.status(hotKeyRefused: false, fnSpaceActive: false),
                  SettingsDictationSection.shortcutsDetail, SettingsDictationSection.accessibilityDetail] {
            XCTAssertTrue(s.contains("Fn + Space"), s)
            XCTAssertTrue(s.contains("⌃⌥⌘D"), s)
        }
        XCTAssertTrue(SettingsDictationSection.status(hotKeyRefused: true, fnSpaceActive: true).contains("Fn + Space"),
                      "⌃⌥⌘D taken: Fn + Space still works")
    }

    // MARK: Accessibility permission watch

    func testAMissingPermissionIsAskedForOnceThenFnSpaceInstallsTheMomentItIsGranted() async {
        let r = rig(enabled: true)
        r.keyTap.permitted = false
        r.controller.activate()
        XCTAssertTrue(r.controller.fnSpaceUnavailable)
        XCTAssertEqual(r.ax.asked, [true], "the system prompt, at once")
        XCTAssertTrue(r.settings.accessibilityPrompted, "so a dictation's paste does not prompt a second time")
        XCTAssertEqual(r.ticker.intervals, [DictationController.permissionPollInterval])
        XCTAssertEqual(DictationController.permissionPollInterval, 2)
        XCTAssertEqual(r.ticker.running, 1)

        r.ticker.fire()
        r.ticker.fire()
        XCTAssertEqual(r.keyTap.installs, 3, "one retry per tick")
        XCTAssertEqual(r.ax.asked, [true], "never asked again")
        XCTAssertTrue(r.controller.fnSpaceUnavailable)
        XCTAssertEqual(r.logs.value.filter { $0.contains("unavailable") }.count, 1, "the missing permission is logged once")

        // Granted in System Settings: the next tick installs the tap and the watch ends.
        r.keyTap.permitted = true
        r.ticker.fire()
        XCTAssertTrue(r.controller.fnSpaceActive)
        XCTAssertFalse(r.controller.fnSpaceUnavailable)
        XCTAssertEqual(r.ticker.running, 0, "the timer stops once trusted")
        XCTAssertFalse(r.controller.isWatchingPermission)
        XCTAssertEqual(r.logs.value.filter { $0.contains("available now") }.count, 1, "one line when it becomes available")

        // And Fn + Space now starts a dictation.
        r.keyTap.onToggle?()
        await waitUntil("recording") { r.controller.phase == .recording }
    }

    func testTurningDictationOffStopsTheWatchAndThePromptIsOncePerLaunch() {
        let r = rig(enabled: true)
        r.keyTap.permitted = false
        r.controller.activate()
        XCTAssertEqual(r.ticker.running, 1)
        r.settings.enabled = false
        XCTAssertEqual(r.ticker.running, 0, "no polling while dictation is off")
        XCTAssertFalse(r.controller.isWatchingPermission)
        r.settings.enabled = true
        XCTAssertEqual(r.ticker.running, 1, "polling again")
        XCTAssertEqual(r.ax.asked, [true], "but no second prompt in this launch")
        r.controller.refreshFnSpace()
        XCTAssertEqual(r.ax.asked, [true], "the Settings page does not prompt again either")
        XCTAssertEqual(r.ticker.running, 1, "one timer")
        r.controller.deactivate()
        XCTAssertEqual(r.ticker.running, 0)
    }

    func testThePromptWaitsWhileARunIsActive() {
        let r = rig(enabled: true)
        r.keyTap.permitted = false
        let active = Box(true)
        r.controller.isRunActive = { active.value }
        r.controller.activate()
        XCTAssertTrue(r.ax.asked.isEmpty, "no dialog during a meeting")
        XCTAssertEqual(r.ticker.running, 1, "but the watch runs")
        r.ticker.fire()
        XCTAssertTrue(r.ax.asked.isEmpty)
        active.value = false
        r.ticker.fire()
        XCTAssertEqual(r.ax.asked, [true], "asked once the run is over")
        r.ticker.fire()
        XCTAssertEqual(r.ax.asked, [true])
    }

    func testAHotKeyPressWithoutThePermissionNeverPrompts() async {
        let r = rig(enabled: true)
        r.keyTap.permitted = false
        let active = Box(true)
        r.controller.isRunActive = { active.value }
        r.controller.activate()          // a run at launch: the prompt is deferred
        active.value = false
        r.registrar.press(DictationController.hotKeyID)
        await waitUntil("recording") { r.controller.phase == .recording }
        XCTAssertTrue(r.ax.asked.isEmpty, "⌃⌥⌘D behaves as before: no prompt on the key")
        r.ticker.fire()
        XCTAssertTrue(r.ax.asked.isEmpty, "nor while the dictation records")
        r.registrar.press(DictationController.hotKeyID)
        await waitUntil("inserted") { r.inserter.calls.count == 1 }
        XCTAssertEqual(r.inserter.calls.first?.mayPrompt, true, "the paste path keeps its own one-time prompt")
    }

    func testAGrantedPermissionStartsNoWatch() {
        let r = rig(enabled: true)
        r.controller.activate()
        XCTAssertTrue(r.controller.fnSpaceActive)
        XCTAssertTrue(r.ax.asked.isEmpty)
        XCTAssertTrue(r.ticker.intervals.isEmpty)
    }

    // MARK: sounds

    func testTheStartCuePlaysOnceTheMicrophoneIsOpenAndTheStopCueAtTheSecondPress() async {
        let r = rig { $0.holdBegin = true; $0.holdFinish = true }
        let start = Task { await r.controller.press() }
        await waitUntil("begin held") { r.last?.beginHeld == true }
        XCTAssertTrue(r.sounds.played.isEmpty, "not before the microphone is open")
        r.last?.releaseBegin()
        await start.value
        XCTAssertEqual(r.sounds.played, [.start])

        let stop = Task { await r.controller.press() }
        await waitUntil("finish held") { r.last?.finishHeld == true }
        XCTAssertEqual(r.sounds.played, [.start, .stop], "once the capture closed, before the engine settles")
        XCTAssertTrue(r.inserter.calls.isEmpty)
        r.last?.releaseFinish()
        await stop.value
        XCTAssertEqual(r.inserter.calls.count, 1)
        XCTAssertEqual(r.sounds.played, [.start, .stop])
    }

    func testAStopWhileTheMicrophoneIsOpeningPlaysOnlyTheStopCue() async {
        let r = rig { $0.holdBegin = true }
        let first = Task { await r.controller.press() }
        await waitUntil("begin held") { r.last?.beginHeld == true }
        let second = Task { await r.controller.press() }
        await waitUntil("finalising") { r.controller.phase == .finalising }
        r.last?.releaseBegin()
        await first.value
        await second.value
        XCTAssertEqual(r.sounds.played, [.stop])
    }

    func testNoCuesWhenTheSettingIsOff() async {
        let r = rig()
        r.settings.sounds = false
        await r.controller.press()
        await r.controller.press()
        XCTAssertEqual(r.inserter.calls.count, 1)
        XCTAssertTrue(r.sounds.played.isEmpty)
    }

    func testNoCueWhileARunIsActiveOnACancelOrOnAFailure() async {
        let busy = rig()
        busy.controller.isRunActive = { true }
        await busy.controller.press()
        XCTAssertTrue(busy.sounds.played.isEmpty, "busy: no cue that could reach the call")

        let cancelled = rig()
        let runs = PassthroughSubject<Bool, Never>()
        cancelled.controller.observeRuns(runs)
        await cancelled.controller.press()
        runs.send(true)
        XCTAssertEqual(cancelled.sounds.played, [.start], "a run starting cancels without a stop cue")

        let openingRun = rig { $0.holdBegin = true }
        let active = Box(false)
        openingRun.controller.isRunActive = { active.value }
        let press = Task { await openingRun.controller.press() }
        await waitUntil("begin held") { openingRun.last?.beginHeld == true }
        active.value = true
        openingRun.last?.releaseBegin()
        await press.value
        XCTAssertTrue(openingRun.sounds.played.isEmpty, "a run that started while the microphone opened: no start cue")

        let failed = rig { $0.beginError = Boom(description: "no mic") }
        await failed.controller.press()
        XCTAssertTrue(failed.sounds.played.isEmpty)

        let midFail = rig()
        await midFail.controller.press()
        midFail.last?.failNow("speech failed")
        XCTAssertEqual(midFail.sounds.played, [.start], "no stop cue on a failure")
    }

    func testTheSynthesisedCuesAreShortPercussiveAndDistinct() {
        let sr = Double(DictationSoundSynth.sampleRate)
        var peaks: [DictationSound: Float] = [:]
        var crossings: [DictationSound: Int] = [:]
        for sound in DictationSound.allCases {
            let s = DictationSoundSynth.samples(sound)
            let ms = Double(s.count) / sr * 1000
            XCTAssertTrue((80...150).contains(ms), "\(sound): \(ms) ms")
            let peak = s.map(abs).max() ?? 0
            peaks[sound] = peak
            XCTAssertTrue(peak > 0.15 && peak <= 0.5, "\(sound): moderate volume, peak \(peak)")
            XCTAssertEqual(s.last ?? 1, 0, accuracy: 0.001, "\(sound): ends silent, no click")
            // Percussive: the first fifth holds far more energy than the last.
            let fifth = s.count / 5
            let head = s.prefix(fifth).map { $0 * $0 }.reduce(0, +), tail = s.suffix(fifth).map { $0 * $0 }.reduce(0, +)
            XCTAssertGreaterThan(head, tail * 20, "\(sound): decays")
            crossings[sound] = zip(s, s.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count

            let wav = DictationSoundSynth.wav(sound)
            XCTAssertEqual(wav.count, 44 + 2 * s.count)
            XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
            XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
            XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
        }
        XCTAssertGreaterThan(peaks[.start]!, peaks[.stop]!, "the stop cue is softer")
        XCTAssertGreaterThan(crossings[.start]!, crossings[.stop]!, "and lower")
    }

    func testSoundsAreOnByDefaultAndPersist() {
        let d = defaults()
        XCTAssertTrue(DictationSettings(defaults: d).sounds)
        DictationSettings(defaults: d).sounds = false
        XCTAssertFalse(DictationSettings(defaults: d).sounds)
        XCTAssertEqual(d.object(forKey: "dictationSounds") as? Bool, false)
    }

    func testThePermissionRowSaysWhetherFnSpaceIsActive() {
        let ready = SettingsDictationSection.permissionDetail(fnSpaceReady: true)
        let missing = SettingsDictationSection.permissionDetail(fnSpaceReady: false)
        XCTAssertTrue(ready.contains("Fn + Space"), ready)
        XCTAssertTrue(missing.contains("Fn + Space") && missing.contains("⌃⌥⌘D"), missing)
        XCTAssertNotEqual(ready, missing)
        XCTAssertEqual(SettingsDictationSection.accessibilityPane.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    // MARK: hot key ids

    /// Every key the app registers through `CarbonRegistrar` shares the signature 'VRHQ' and one action table keyed by id, so
    /// two features on one id would run each other's action (dictation and the earlier-answer key both had 3).
    func testEveryHotKeyIdUnderTheSharedSignatureIsDistinct() async {
        let reg = FakeRegistrar()
        let fired = Box<[String]>([])
        let keys = GlobalHotKeys(registrar: reg, onStartStop: { fired.value.append("startStop") }, onCardNow: {},
                                 onEarlierAnswer: { fired.value.append("earlier") }, lessThanKeyCodes: { [50] })
        keys.registerStartStop()
        keys.registerStartUnprepared()
        keys.setSessionRunning(true)
        let settings = DictationSettings(defaults: defaults(), preferredLanguages: ["en"])
        settings.enabled = true
        let made = Box<[FakeTranscriber]>([])
        let ticker = FakeTicker()
        let dictation = DictationController(settings: settings, registrar: reg, keyTap: FakeKeyTap(), makeTranscriber: {
            let t = FakeTranscriber()
            made.value.append(t)
            return t
        }, inserter: FakeInserter(), notifier: FakeNotifier(), sounds: FakeSounds(),
           accessibility: FakeAccessibility(trusted: true), ticker: { ticker.make($0, $1) },
           history: DictationHistory(fileURL: nil), log: { _ in })
        dictation.activate()

        let ids = reg.live.values.map(\.id)
        XCTAssertEqual(ids.count, 9, "⌥⌘V, ⌥⇧⌘V, the six session keys and ⌃⌥⌘D")
        XCTAssertEqual(Set(ids).count, ids.count, "ids \(ids.sorted()) repeat")
        let declared: [UInt32] = [GlobalHotKeys.startStopID, GlobalHotKeys.cardNowID, GlobalHotKeys.earlierAnswerID,
                                  GlobalHotKeys.newerAnswerID, GlobalHotKeys.earlierAnswerShiftID, GlobalHotKeys.startUnpreparedID,
                                  GlobalHotKeys.regenerateID, GlobalHotKeys.markBadID, DictationController.hotKeyID]
        XCTAssertEqual(Set(declared).count, declared.count)

        // ⌃⌥⌘D during a session presses dictation (its gate then decides), never the earlier answer.
        reg.press(DictationController.hotKeyID)
        await waitUntil("recording") { dictation.phase == .recording }
        XCTAssertEqual(fired.value, [])
        // The session ends: ⌃⌥⌘D keeps its action.
        keys.setSessionRunning(false)
        XCTAssertTrue(reg.live.values.contains { $0.id == DictationController.hotKeyID })
        dictation.deactivate()
        keys.unregisterAll()
    }
}
