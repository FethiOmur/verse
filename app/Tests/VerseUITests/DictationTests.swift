import Combine
import Foundation
import VerseSpeech
@testable import VerseUI
import XCTest

/// Dictation (⌃⌥⌘D): the controller's state machine, the run gate, the hot key's registration, the insertion paths and the
/// transcript assembly. Everything is faked: no microphone, no key events, no pasteboard, no recognizer.
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

    struct Boom: Error, CustomStringConvertible { var description: String }

    final class FakeTranscriber: DictationTranscribing {
        var beginError: (any Error)?
        var finishText = "hello"
        var finishError: (any Error)?
        var holdBegin = false
        var holdFinish = false
        private(set) var began: [String] = []
        private(set) var finishCalls = 0
        private(set) var cancelCalls = 0
        private(set) var onFailure: (@MainActor (String) -> Void)?
        private var beginGate: CheckedContinuation<Void, Never>?
        private var finishGate: CheckedContinuation<Void, Never>?
        var beginHeld: Bool { beginGate != nil }
        var finishHeld: Bool { finishGate != nil }

        func begin(lang: String, onFailure: @escaping @MainActor (String) -> Void) async throws {
            began.append(lang)
            self.onFailure = onFailure
            if holdBegin { await withCheckedContinuation { beginGate = $0 } }
            if let beginError { throw beginError }
        }
        func finish() async throws -> String {
            finishCalls += 1
            if holdFinish { await withCheckedContinuation { finishGate = $0 } }
            if let finishError { throw finishError }
            return finishText
        }
        func cancel() async { cancelCalls += 1 }
        func releaseBegin() { beginGate?.resume(); beginGate = nil }
        func releaseFinish() { finishGate?.resume(); finishGate = nil }
        func failNow(_ why: String) { onFailure?(why) }
    }

    final class FakeInserter: DictationTextInserting {
        var outcome = DictationInsertOutcome.pasted
        private(set) var calls: [(text: String, mayPrompt: Bool)] = []
        func insert(_ text: String, mayPromptForPermission: Bool) async -> DictationInsertOutcome {
            calls.append((text, mayPromptForPermission))
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

    private func defaults() -> UserDefaults {
        let name = "verse.dictation.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private struct Rig {
        let controller: DictationController
        let settings: DictationSettings
        let registrar: FakeRegistrar
        let inserter: FakeInserter
        let notifier: FakeNotifier
        let made: Box<[FakeTranscriber]>
        var last: FakeTranscriber? { made.value.last }
    }

    /// A controller with every dependency faked. `prepare` configures each transcriber as it is made.
    private func rig(enabled: Bool = true, lang: String = "en", inserter: (any DictationTextInserting)? = nil,
                     prepare: @escaping (FakeTranscriber) -> Void = { _ in }) -> Rig {
        let settings = DictationSettings(defaults: defaults())
        settings.enabled = enabled
        settings.language = lang
        let reg = FakeRegistrar(), fakeInserter = FakeInserter(), notifier = FakeNotifier()
        let made = Box<[FakeTranscriber]>([])
        let c = DictationController(settings: settings, registrar: reg, makeTranscriber: {
            let t = FakeTranscriber()
            prepare(t)
            made.value.append(t)
            return t
        }, inserter: inserter ?? fakeInserter, notifier: notifier, log: { _ in })
        return Rig(controller: c, settings: settings, registrar: reg, inserter: fakeInserter, notifier: notifier, made: made)
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
        let inserter = PasteboardTextInserter(accessibility: ax, pasteboard: pb, keystroke: keys, sleep: { _ in })
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
        let inserter = PasteboardTextInserter(accessibility: ax, pasteboard: pb, keystroke: keys, sleep: { _ in })

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
        let inserter = PasteboardTextInserter(accessibility: ax, pasteboard: pb, keystroke: keys, sleep: { _ in
            await MainActor.run { pb.externalCopy("newer") }
        })
        _ = await inserter.insert("dictated", mayPromptForPermission: false)
        XCTAssertEqual(pb.string, "newer")
    }

    func testAnEmptyTextInsertsNothing() async {
        let ax = FakeAccessibility(trusted: true), pb = FakePasteboard(), keys = FakeKeystroke()
        let inserter = PasteboardTextInserter(accessibility: ax, pasteboard: pb, keystroke: keys, sleep: { _ in })
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
            XCTAssertNil(try AppleDictationTranscriber.environment.makeRemoteSource(c), "no process tap, no system audio")
        }
    }

    // MARK: settings

    func testSettingsAreOffByDefaultAndPersist() {
        let d = defaults()
        let s = DictationSettings(defaults: d)
        XCTAssertFalse(s.enabled)
        XCTAssertEqual(s.language, "en")
        XCTAssertFalse(s.accessibilityPrompted)
        s.enabled = true
        s.language = "tr"
        s.accessibilityPrompted = true
        let again = DictationSettings(defaults: d)
        XCTAssertTrue(again.enabled)
        XCTAssertEqual(again.language, "tr")
        XCTAssertTrue(again.accessibilityPrompted)
        d.set("de", forKey: "dictationLanguage")
        XCTAssertEqual(DictationSettings(defaults: d).language, "en", "an unknown language falls back")
    }
}
