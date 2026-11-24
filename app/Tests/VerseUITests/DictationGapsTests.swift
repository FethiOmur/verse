import Combine
import CoreGraphics
import Foundation
import VerseSpeech
@testable import VerseUI
import XCTest

/// Dictation's second round (the TypeWhisper comparison): the last dictations (G1), the vocabulary (G3), the release tail (G4),
/// Esc to cancel (G7) and the silent-microphone warning (G10). Same fakes as `DictationTests`: no microphone, no key events,
/// no recognizer; time moves only on the fake clock.
extension DictationTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verse-dictation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func waitFor(_ what: String, _ cond: @escaping () -> Bool) async {
        for _ in 0..<2000 {
            if cond() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// Records for `seconds` (microphone open at 0), then presses stop.
    private func dictate(_ r: Rig, seconds: TimeInterval) async {
        await r.controller.press()
        r.clock.t += seconds
        await r.controller.press()
    }

    // MARK: G1 last dictations

    func testDictationHistoryKeepsTheNewestTenOwnerOnlyAndReloads() async throws {
        let url = try tempDir().appendingPathComponent("sub/dictation-recent.json")
        let h = DictationHistory(fileURL: url)
        XCTAssertNil(h.last)
        for i in 1...12 { h.add(DictationRecord(text: "text \(i)", date: Date(timeIntervalSince1970: Double(i)), app: i == 12 ? "Notes" : nil)) }
        XCTAssertEqual(h.records.count, DictationHistory.capacity)
        XCTAssertEqual(DictationHistory.capacity, 10)
        XCTAssertEqual(h.records.first?.text, "text 12", "newest first")
        XCTAssertEqual(h.records.last?.text, "text 3", "the oldest two dropped")

        await h.waitForWrites()
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, "owner-only")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["dictation-recent.json"], "no temporary file left behind")

        let again = DictationHistory(fileURL: url)
        XCTAssertEqual(again.records, h.records, "read back from the file")
        XCTAssertEqual(again.last?.app, "Notes")
    }

    func testAnUnreadableHistoryFileIsMovedAsideOnceAndAMemoryOnlyHistoryWritesNothing() async throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("dictation-recent.json")
        let bak = dir.appendingPathComponent("dictation-recent.json.bak")
        try Data("an older backup".utf8).write(to: bak)
        try Data("not json".utf8).write(to: url)
        let logs = Box<[String]>([])
        let h = DictationHistory(fileURL: url, log: { logs.value.append($0) })
        XCTAssertTrue(h.records.isEmpty)
        XCTAssertEqual(logs.value.count, 1)
        XCTAssertEqual(try String(contentsOf: bak, encoding: .utf8), "not json", "moved aside, replacing the older backup")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        h.add(DictationRecord(text: "fresh", date: Date(), app: nil))
        await h.waitForWrites()
        XCTAssertEqual(DictationHistory(fileURL: url).last?.text, "fresh", "a new list in the real file")
        XCTAssertEqual(try String(contentsOf: bak, encoding: .utf8), "not json", "the unreadable content survives the next write")
        XCTAssertEqual(logs.value.count, 1, "moved once")

        let memory = DictationHistory(fileURL: nil)
        memory.add(DictationRecord(text: "only here", date: Date(), app: nil))
        XCTAssertEqual(memory.last?.text, "only here")
        XCTAssertEqual(DictationHistory.defaultURL.lastPathComponent, "dictation-recent.json")
        XCTAssertTrue(DictationHistory.defaultURL.path.hasSuffix("Application Support/Verse/dictation-recent.json"))
    }

    func testAFinishedDictationIsKeptWithTheAppInFrontBeforeItIsPasted() async throws {
        let url = try tempDir().appendingPathComponent("dictation-recent.json")
        let inserterSawHistory = Box<String?>(nil)
        final class PeekingInserter: DictationTextInserting {
            var peek: () -> Void = {}
            func insert(_ text: String, mayPromptForPermission: Bool) async -> DictationInsertOutcome { peek(); return .pasted }
        }
        let inserter = PeekingInserter()
        let r = rig(inserter: inserter, history: DictationHistory(fileURL: url)) { $0.finishText = "  kept text " }
        inserter.peek = { inserterSawHistory.value = r.history.last?.text }
        r.frontApp.value = "Messages"
        XCTAssertFalse(r.controller.offersLastDictation, "nothing kept yet")

        await r.controller.press()
        await r.controller.press()
        XCTAssertEqual(inserterSawHistory.value, "kept text", "kept before the paste, so a paste that lands nowhere loses nothing")
        XCTAssertEqual(r.controller.lastDictation?.text, "kept text")
        XCTAssertEqual(r.controller.lastDictation?.app, "Messages")
        XCTAssertTrue(r.controller.offersLastDictation)
        await r.history.waitForWrites()
        XCTAssertEqual(DictationHistory(fileURL: url).last?.text, "kept text", "on disk")

        r.settings.enabled = false
        XCTAssertFalse(r.controller.offersLastDictation, "the menu rows only while dictation is on")
    }

    func testCancelledFailedAndEmptyDictationsAreNotKept() async {
        let empty = rig { $0.finishText = "   " }
        await empty.controller.press()
        await empty.controller.press()
        XCTAssertNil(empty.history.last)

        let cancelled = rig()
        await cancelled.controller.press()
        cancelled.controller.cancelByKey()
        XCTAssertEqual(cancelled.notifier.notices, [.cancelled])
        XCTAssertNil(cancelled.history.last)

        let failed = rig { $0.finishError = Boom(description: "flush failed") }
        await failed.controller.press()
        await failed.controller.press()
        XCTAssertNil(failed.history.last)
    }

    func testPasteLastGoesThroughTheInserterAfterTheMenuClosesAndCopyLastUsesTheClipboard() async {
        let r = rig { $0.finishText = "again please" }
        await r.controller.press()
        await r.controller.press()
        XCTAssertEqual(r.inserter.calls.count, 1)
        let sleepsBefore = r.clock.sleeps.count

        await r.controller.pasteLast()
        XCTAssertEqual(r.inserter.calls.map(\.text), ["again please", "again please"])
        XCTAssertEqual(r.inserter.calls.last?.mayPrompt, false, "the menu never shows the permission prompt")
        XCTAssertEqual(Array(r.clock.sleeps.dropFirst(sleepsBefore)), [DictationController.menuCloseDelay])
        XCTAssertEqual(r.controller.phase, .idle)

        r.controller.copyLast()
        XCTAssertEqual(r.pasteboard.string, "again please")
        XCTAssertEqual(r.pasteboard.transientWrites, 0, "a copy the owner asked for is kept by clipboard managers")

        r.inserter.outcome = .copiedToClipboard
        await r.controller.pasteLast()
        XCTAssertEqual(r.notifier.notices, [.copiedToClipboard], "no permission: says it is on the clipboard")
    }

    func testPasteLastDoesNothingWhileADictationIsUnderWayOrWhenOff() async {
        let r = rig { $0.finishText = "first" }
        await r.controller.press()
        await r.controller.press()
        await r.controller.press()
        XCTAssertEqual(r.controller.phase, .recording)
        await r.controller.pasteLast()
        XCTAssertEqual(r.inserter.calls.count, 1, "no paste into a recording")
        r.settings.enabled = false
        await r.controller.pasteLast()
        r.controller.copyLast()
        XCTAssertEqual(r.inserter.calls.count, 1)
        XCTAssertNil(r.pasteboard.string)
    }

    // MARK: G3 vocabulary

    func testVocabularyTermsAreOnePerLineTrimmedUniqueAndCapped() {
        XCTAssertEqual(DictationSettings.terms(fromVocabulary: "  Verse \n\nSwiftUI\r\nswiftui\n\t\nTypeWhisper  "),
                       ["Verse", "SwiftUI", "TypeWhisper"])
        XCTAssertEqual(DictationSettings.terms(fromVocabulary: ""), [])
        let many = (1...150).map { "term\($0)" }.joined(separator: "\n")
        let capped = DictationSettings.terms(fromVocabulary: many)
        XCTAssertEqual(capped.count, DictationSettings.vocabularyCap)
        XCTAssertEqual(DictationSettings.vocabularyCap, 100)
        XCTAssertEqual(capped.last, "term100")

        let d = defaults()
        let s = DictationSettings(defaults: d)
        XCTAssertEqual(s.vocabulary, "")
        s.vocabulary = "Verse\nFluidAudio"
        XCTAssertEqual(DictationSettings(defaults: d).vocabularyTerms, ["Verse", "FluidAudio"])
    }

    func testTheVocabularyReachesOnlyTheEngineThatHonoursIt() {
        let terms = ["Verse", "FluidAudio"]
        XCTAssertEqual(AppleDictationTranscriber.config(lang: "tr", vocabulary: terms).contextualStrings, terms,
                       "DictationTranscriber (Turkish) uses contextual strings")
        for lang in ["en", "it"] {
            XCTAssertEqual(AppleDictationTranscriber.config(lang: lang, vocabulary: terms).contextualStrings, [],
                           "\(lang): SpeechTranscriber ignores them, so they are not passed")
            XCTAssertFalse(AppleDictationTranscriber.vocabularyTakesEffect(lang: lang))
        }
        XCTAssertTrue(AppleDictationTranscriber.vocabularyTakesEffect(lang: "tr"))
        let many = (1...150).map { "t\($0)" }
        XCTAssertEqual(AppleDictationTranscriber.config(lang: "tr", vocabulary: many).contextualStrings.count, 100)
        XCTAssertEqual(AppleDictationTranscriber.config(lang: "tr").contextualStrings, [])
    }

    func testEachDictationStartsWithTheCurrentVocabulary() async {
        let r = rig(lang: "tr")
        r.settings.vocabulary = "Verse\n\nRouteRush"
        await r.controller.press()
        XCTAssertEqual(r.last?.vocabularies, [["Verse", "RouteRush"]])
    }

    func testTheVocabularyHelpSaysWhereItHasNoEffect() {
        let tr = SettingsDictationSection.vocabularyDetail(lang: "tr")
        let en = SettingsDictationSection.vocabularyDetail(lang: "en")
        XCTAssertNotEqual(tr, en)
        XCTAssertTrue(en.contains("English and Italian"), en)
        XCTAssertTrue(en.contains("100") && tr.contains("100"))
        XCTAssertEqual(en, SettingsDictationSection.vocabularyDetail(lang: "it"))
    }

    // MARK: G4 release tail

    func testReleaseTailTable() {
        struct Row { let frames: [Float?]; let closesAt: Int; let why: String }
        let loud: Float = 0.05, quiet: Float = 0.001
        let rows: [Row] = [
            Row(frames: [quiet, quiet, quiet], closesAt: 3, why: "150 ms of quiet at once"),
            Row(frames: [nil, nil, nil], closesAt: 3, why: "no audio counts as quiet"),
            Row(frames: [loud, loud, quiet, quiet, quiet], closesAt: 5, why: "speech, then 150 ms of quiet"),
            Row(frames: [quiet, quiet, loud, quiet, quiet, quiet], closesAt: 6, why: "speech resets the quiet count"),
            Row(frames: Array(repeating: loud, count: 10), closesAt: 7, why: "at most 350 ms"),
            Row(frames: [loud, quiet, loud, quiet, loud, quiet, loud], closesAt: 7, why: "never quiet long enough: 350 ms"),
            Row(frames: [DictationReleaseTail.speechRMSFloor, quiet, quiet, quiet], closesAt: 4, why: "the floor itself counts as sound"),
        ]
        for r in rows {
            var tail = DictationReleaseTail()
            var closed: Int?
            for (i, f) in r.frames.enumerated() where closed == nil {
                if tail.add(frameRMS: f, elapsed: Double(i + 1) * DictationReleaseTail.frameDuration) { closed = i + 1 }
            }
            XCTAssertEqual(closed, r.closesAt, r.why)
        }
        XCTAssertFalse(DictationReleaseTail.applies(recordedFor: 0.29), "a quick tap gets no tail")
        XCTAssertTrue(DictationReleaseTail.applies(recordedFor: 0.3))
        XCTAssertEqual(DictationReleaseTail.maxDuration, 0.35)
        XCTAssertEqual(DictationReleaseTail.quietDuration, 0.15)
        XCTAssertEqual(DictationReleaseTail.frameDuration, 0.05)
    }

    func testTheMicrophoneStaysOpenAfterTheStopPressUntilTheTailEnds() async {
        // Speech for two frames after the press, then quiet: five 50 ms frames.
        let r = rig { t in t.frame = { i in i == 0 ? 0.3 : (i <= 2 ? 0.05 : 0.001) } }
        let duringTail = Box<[[DictationSound]]>([])
        r.clock.onSleep = { _ in
            duringTail.value.append(r.sounds.played)
            XCTAssertEqual(r.last?.finishCalls, 0, "the microphone is not closed during the tail")
            XCTAssertEqual(r.controller.phase, .finalising)
        }
        await dictate(r, seconds: 2)
        XCTAssertEqual(r.clock.sleeps, Array(repeating: .milliseconds(50), count: 5))
        XCTAssertEqual(r.last?.frameCalls, 6, "the drain at the press plus one per frame")
        XCTAssertEqual(r.last?.finishCalls, 1)
        XCTAssertEqual(r.inserter.calls.count, 1)
        XCTAssertTrue(duringTail.value.allSatisfy { $0 == [.start] }, "no stop cue into the open microphone")
        XCTAssertEqual(r.sounds.played, [.start, .stop], "the stop cue once the capture is closed")
    }

    func testALateCaptureReportStillPlaysTheStopCueButNotAfterACancel() async {
        let r = rig { $0.reportCaptureLate = true }
        await dictate(r, seconds: 0.2)
        XCTAssertEqual(r.inserter.calls.count, 1, "the engine settled and the text went in first")
        XCTAssertEqual(r.sounds.played, [.start])
        r.last?.lateCaptureReport?()
        XCTAssertEqual(r.sounds.played, [.start, .stop])

        let c = rig { $0.reportCaptureLate = true; $0.holdFinish = true }
        await c.controller.press()
        let stop = Task { await c.controller.press() }
        await waitFor("finish held") { c.last?.finishHeld == true }
        c.controller.cancelByKey()
        c.last?.lateCaptureReport?()
        c.last?.releaseFinish()
        await stop.value
        XCTAssertEqual(c.sounds.played, [.start], "cancelled: no stop cue")
    }

    func testTheTailIsCappedAtThreeHundredFiftyMilliseconds() async {
        let r = rig { $0.frame = { _ in 0.1 } }
        await dictate(r, seconds: 5)
        XCTAssertEqual(r.clock.sleeps.count, 7)
        XCTAssertEqual(r.inserter.calls.count, 1)
    }

    func testAShortRecordingGetsNoTail() async {
        let r = rig { $0.frame = { _ in 0.1 } }
        await dictate(r, seconds: 0.2)
        XCTAssertTrue(r.clock.sleeps.isEmpty)
        XCTAssertEqual(r.last?.frameCalls, 0)
        XCTAssertEqual(r.inserter.calls.count, 1)
        XCTAssertEqual(r.sounds.played, [.start, .stop])
    }

    func testAStopPressWhileTheMicrophoneIsOpeningGetsNoTail() async {
        let r = rig { $0.holdBegin = true }
        let first = Task { await r.controller.press() }
        await waitFor("begin held") { r.last?.beginHeld == true }
        r.clock.t = 3            // a slow open; the press comes before the microphone is open
        let second = Task { await r.controller.press() }
        await waitFor("finalising") { r.controller.phase == .finalising }
        r.last?.releaseBegin()
        await first.value
        await second.value
        XCTAssertTrue(r.clock.sleeps.isEmpty)
        XCTAssertEqual(r.inserter.calls.count, 1)
    }

    func testEscDuringTheTailCancelsWithoutInsertingOrAStopCue() async {
        let r = rig { $0.frame = { _ in 0.1 } }
        r.controller.activate()
        defer { r.controller.deactivate() }
        r.clock.onSleep = { n in if n == 2 { r.keyTap.onCancel?() } }
        await dictate(r, seconds: 2)
        XCTAssertEqual(r.clock.sleeps.count, 2, "the tail ends with the cancel")
        XCTAssertEqual(r.last?.finishCalls, 0)
        await r.controller.pendingRelease?.value
        XCTAssertEqual(r.last?.cancelCalls, 1)
        XCTAssertTrue(r.inserter.calls.isEmpty)
        XCTAssertEqual(r.notifier.notices, [.cancelled])
        XCTAssertEqual(r.sounds.played, [.start])
        XCTAssertEqual(r.controller.phase, .idle)
    }

    func testAMeterCountsPeakAndFramesAndReportsTheClosedCapture() {
        let m = DictationInputMeter()
        XCTAssertEqual(m.peak, 0)
        XCTAssertNil(m.takeFrameRMS(), "no audio, no frame")
        XCTAssertEqual(m.level, DictationInputLevel(peak: 0, audioSeconds: 0, chunks: 0))
        m.record([0, 0, 0, 0], sampleRate: 16)
        XCTAssertEqual(m.peak, 0, "exact zeros")
        XCTAssertEqual(m.takeFrameRMS(), 0)
        m.record([0.5, -0.5], sampleRate: 16)
        m.record([-0.8], sampleRate: 16)
        XCTAssertEqual(m.peak, 0.8, accuracy: 1e-6)
        XCTAssertEqual(m.takeFrameRMS() ?? -1, Float(((0.25 + 0.25 + 0.64) / 3).squareRoot()), accuracy: 1e-6)
        XCTAssertNil(m.takeFrameRMS(), "each frame starts empty")
        XCTAssertEqual(m.chunks, 3)
        XCTAssertEqual(m.level.audioSeconds, 7.0 / 16, accuracy: 1e-9, "seconds of audio delivered, from the sample rate")

        let calls = OSAllocatedCounter()
        let m2 = DictationInputMeter()
        m2.whenCaptureCloses { calls.increment() }
        m2.markCaptureClosed()
        m2.markCaptureClosed()
        XCTAssertEqual(calls.value, 1, "once")
        m2.whenCaptureCloses { calls.increment() }
        XCTAssertEqual(calls.value, 2, "a late handler runs at once")
    }

    // MARK: G7 Esc

    private static let esc = FnSpaceFilter.escapeKeyCode

    func testEscDecisionTable() {
        struct Row { let armed: Bool; let type: CGEventType; let flags: CGEventFlags; let want: FnSpaceDecision; let why: String }
        let rows: [Row] = [
            Row(armed: true, type: .keyDown, flags: [], want: .cancel, why: "Esc while a dictation is under way"),
            Row(armed: false, type: .keyDown, flags: [], want: .pass, why: "idle: Esc belongs to the app in front"),
            Row(armed: true, type: .keyDown, flags: [.maskCommand, .maskAlternate], want: .pass, why: "⌥⌘Esc is Force Quit"),
            Row(armed: true, type: .keyDown, flags: .maskShift, want: .pass, why: "⇧Esc is another combination"),
            Row(armed: true, type: .keyDown, flags: .maskControl, want: .pass, why: "⌃Esc"),
            Row(armed: true, type: .keyDown, flags: [.maskAlphaShift, .maskNonCoalesced], want: .cancel, why: "Caps Lock does not count"),
            Row(armed: true, type: .keyDown, flags: .maskSecondaryFn, want: .cancel, why: "Fn still held from Fn + Space"),
            Row(armed: true, type: .keyUp, flags: [], want: .pass, why: "a key-up alone is not ours"),
        ]
        for r in rows {
            var f = FnSpaceFilter()
            f.cancelArmed = r.armed
            XCTAssertEqual(f.decide(type: r.type, keyCode: Self.esc, flags: r.flags, isRepeat: false), r.want, r.why)
        }
    }

    func testAHeldEscCancelsOnceAndSwallowsItsRepeatsAndKeyUpEvenAfterDisarming() {
        var f = FnSpaceFilter()
        f.cancelArmed = true
        XCTAssertEqual(f.decide(type: .keyDown, keyCode: Self.esc, flags: [], isRepeat: false), .cancel)
        f.cancelArmed = false       // the controller disarms as the dictation ends
        XCTAssertEqual(f.decide(type: .keyDown, keyCode: Self.esc, flags: [], isRepeat: true), .swallow)
        XCTAssertEqual(f.decide(type: .keyUp, keyCode: Self.esc, flags: [], isRepeat: false), .swallow)
        XCTAssertEqual(f.decide(type: .keyUp, keyCode: Self.esc, flags: [], isRepeat: false), .pass, "only the one key-up")
        XCTAssertEqual(f.decide(type: .keyDown, keyCode: Self.esc, flags: [], isRepeat: false), .pass, "disarmed: passes")
        XCTAssertEqual(f.decide(type: .keyDown, keyCode: Self.esc, flags: [], isRepeat: true), .pass)
        // Space handling is untouched by Esc.
        XCTAssertEqual(f.decide(type: .keyDown, keyCode: FnSpaceFilter.spaceKeyCode, flags: .maskSecondaryFn, isRepeat: false), .toggle)
    }

    func testEscIsArmedOnlyWhileADictationRecordsOrFinishes() async {
        let r = rig { $0.holdFinish = true }
        r.controller.activate()
        XCTAssertTrue(r.keyTap.armed.isEmpty, "idle: not armed")
        await r.controller.press()
        XCTAssertEqual(r.keyTap.armed, [true])
        let stop = Task { await r.controller.press() }
        await waitFor("finish held") { r.last?.finishHeld == true }
        XCTAssertEqual(r.keyTap.armed, [true], "still armed while finishing")
        r.last?.releaseFinish()
        await stop.value
        XCTAssertEqual(r.keyTap.armed, [true, false], "disarmed for the paste and after")
        r.controller.deactivate()
    }

    func testEscWhileRecordingCancelsWithoutInsertingAndWithoutAStopCue() async {
        let r = rig()
        r.controller.activate()
        await r.controller.press()
        r.keyTap.onCancel?()
        XCTAssertEqual(r.controller.phase, .idle)
        await r.controller.pendingRelease?.value
        XCTAssertEqual(r.last?.cancelCalls, 1, "the microphone is released")
        XCTAssertEqual(r.last?.finishCalls, 0)
        XCTAssertTrue(r.inserter.calls.isEmpty)
        XCTAssertEqual(r.notifier.notices, [.cancelled])
        XCTAssertEqual(r.sounds.played, [.start])
        XCTAssertEqual(r.keyTap.armed, [true, false])

        r.keyTap.onCancel?()
        XCTAssertEqual(r.notifier.notices, [.cancelled], "idle: nothing to cancel")
        await r.controller.press()
        XCTAssertEqual(r.controller.phase, .recording, "the next press is a new dictation")
        r.controller.deactivate()
    }

    func testEscWhileTheEngineSettlesDropsTheText() async {
        let r = rig { $0.holdFinish = true; $0.finishText = "never typed" }
        await r.controller.press()
        let stop = Task { await r.controller.press() }
        await waitFor("finish held") { r.last?.finishHeld == true }
        r.controller.cancelByKey()
        XCTAssertEqual(r.controller.phase, .idle)
        r.last?.releaseFinish()
        await stop.value
        XCTAssertTrue(r.inserter.calls.isEmpty)
        XCTAssertEqual(r.notifier.notices, [.cancelled])
        XCTAssertNil(r.history.last)
    }

    func testWithoutTheEventTapThereIsNoEscCancel() async {
        let r = rig()
        r.keyTap.permitted = false
        r.controller.activate()
        XCTAssertNil(r.keyTap.onCancel, "⌃⌥⌘D only: Esc cannot be taken (documented in Settings)")
        XCTAssertTrue(SettingsDictationSection.shortcutsDetail.contains("Esc"))
        XCTAssertTrue(SettingsDictationSection.escapeDetail.contains("Accessibility"))
        r.controller.deactivate()
    }

    // MARK: G10 silent microphone

    func testSilenceRuleTable() {
        func level(_ peak: Float, _ secs: TimeInterval, _ chunks: Int) -> DictationInputLevel {
            DictationInputLevel(peak: peak, audioSeconds: secs, chunks: chunks)
        }
        struct Row { let openFor: TimeInterval; let level: DictationInputLevel; let want: DictationSilence.Reading; let why: String }
        let rows: [Row] = [
            Row(openFor: 1.0, level: level(0, 1.0, 100), want: .silent, why: "a second of exact zeros"),
            Row(openFor: 3, level: level(0.000001, 3, 300), want: .silent, why: "dither under the floor"),
            Row(openFor: 0.99, level: level(0, 0.99, 99), want: .undecided, why: "not before a second of audio"),
            Row(openFor: 5, level: level(0.0003, 5, 500), want: .sound, why: "a quiet room is not a muted microphone"),
            Row(openFor: 1.0, level: level(0, 0, 0), want: .noAudio, why: "no callbacks at all is not silence"),
            Row(openFor: 0.9, level: level(0, 0, 0), want: .undecided, why: "no callbacks, but not for a second yet"),
            Row(openFor: 3, level: level(0, 0.4, 40), want: .undecided, why: "a gap: open 3 s, only 0.4 s of audio arrived"),
            Row(openFor: 3, level: level(0.2, 0.4, 40), want: .sound, why: "a gap after real sound"),
        ]
        for r in rows {
            XCTAssertEqual(DictationSilence.reading(openFor: r.openFor, level: r.level), r.want, r.why)
            XCTAssertEqual(DictationSilence.isSilent(r.level), r.want == .silent, r.why)
        }
        XCTAssertEqual(DictationSilence.minimumDuration, 1.0)
    }

    func testASilentMicrophoneIsReportedOncePerDictationAndRecordingGoesOn() async {
        let r = rig { $0.peak = 0 }
        await r.controller.press()
        XCTAssertEqual(r.ticker.intervals, [DictationSilence.checkInterval])
        r.clock.t = 0.75
        r.ticker.fire()
        XCTAssertTrue(r.notifier.notices.isEmpty, "not before a second")
        r.clock.t = 1.0
        r.ticker.fire()
        XCTAssertEqual(r.notifier.notices, [.microphoneSilent])
        XCTAssertEqual(r.ticker.running, 0, "the watch ends after the warning")
        r.ticker.fire()
        XCTAssertEqual(r.notifier.notices, [.microphoneSilent], "once")
        XCTAssertEqual(r.controller.phase, .recording, "a warning, not an auto-stop")
        XCTAssertEqual(DictationNotice.microphoneSilent.text, "No sound from the microphone. Is it muted?")
    }

    func testAWorkingMicrophoneShowsNoWarningAndTheWatchEndsWithTheDictation() async {
        let r = rig()
        await r.controller.press()
        r.clock.t = 5
        r.ticker.fire()
        XCTAssertTrue(r.notifier.notices.isEmpty)
        XCTAssertEqual(r.ticker.running, 1)
        await r.controller.press()
        XCTAssertEqual(r.ticker.running, 0, "no watch after the stop press")
        XCTAssertEqual(r.inserter.calls.count, 1)
    }

    func testAWholeSilentClipInsertsNothingAndSaysTheMicrophoneGaveNoSound() async {
        let r = rig { $0.peak = 0; $0.finishText = "" }
        await r.controller.press()
        r.clock.t = 1.5
        r.ticker.fire()
        await r.controller.press()
        XCTAssertTrue(r.inserter.calls.isEmpty)
        XCTAssertEqual(r.notifier.notices, [.microphoneSilent, .microphoneSilentNothingInserted])
        XCTAssertNil(r.history.last)

        let short = rig { $0.peak = 0; $0.finishText = "" }
        await dictate(short, seconds: 0.5)
        XCTAssertEqual(short.notifier.notices, [.nothingHeard], "under a second: the usual notice")
    }

    func testTextFromAMicrophoneThatReadSilentIsStillInserted() async {
        let r = rig { $0.peak = 0; $0.finishText = "still here" }
        await dictate(r, seconds: 2)
        XCTAssertEqual(r.inserter.calls.map(\.text), ["still here"], "never lose text over a level reading")
    }

    func testTheNewNoticesHaveTheirOwnTexts() {
        let texts = [DictationNotice.cancelled, .microphoneSilent, .microphoneSilentNothingInserted, .nothingHeard].map(\.text)
        XCTAssertEqual(Set(texts).count, texts.count)
        XCTAssertEqual(DictationNotice.cancelled.text, "Dictation cancelled")
    }
}

/// The review fixes of the second round: Esc delivered in the same step it is swallowed, the run gate on "Paste last", the
/// unreadable history file kept aside, the silent-microphone rule on delivered audio, history writes off the main actor and
/// "Clear recent dictations".
extension DictationTests {

    // MARK: Esc race

    func testTheTapCancelsBeforeItDropsTheEscItSwallowed() {
        let cancels = OSAllocatedCounter(), toggles = OSAllocatedCounter()
        let box = FnSpaceTapBox(onToggle: { toggles.increment() }, onCancel: { cancels.increment() })
        box.filter.cancelArmed = true
        XCTAssertTrue(box.handle(type: .keyDown, keyCode: Self.esc, flags: [], isRepeat: false), "swallowed")
        XCTAssertEqual(cancels.value, 1, "the cancel has run by the time the tap drops the Esc")
        XCTAssertTrue(box.handle(type: .keyUp, keyCode: Self.esc, flags: [], isRepeat: false))
        XCTAssertEqual(cancels.value, 1, "the key-up is only swallowed")
        box.filter.cancelArmed = false
        XCTAssertFalse(box.handle(type: .keyDown, keyCode: Self.esc, flags: [], isRepeat: false), "disarmed: it passes")
        XCTAssertFalse(box.handle(type: .keyDown, keyCode: 0, flags: [], isRepeat: false), "other keys pass")
        XCTAssertEqual(cancels.value, 1)
        XCTAssertEqual(toggles.value, 0)
    }

    func testAnEscSwallowedRightAfterTheEngineReturnedStillCancelsAndNothingIsInserted() async {
        let r = rig { $0.holdFinish = true; $0.finishText = "never typed" }
        r.controller.activate()
        defer { r.controller.deactivate() }
        guard let toggle = r.keyTap.onToggle, let cancel = r.keyTap.onCancel else { return XCTFail("tap not installed") }
        // The real tap as the system drives it, with the controller's handlers (the fake tap does not forward arming).
        let box = FnSpaceTapBox(onToggle: toggle, onCancel: cancel)
        box.filter.cancelArmed = true
        await r.controller.press()
        let stop = Task { await r.controller.press() }
        await waitFor("finish held") { r.last?.finishHeld == true }
        XCTAssertEqual(r.keyTap.armed.last, true, "armed while finishing")
        r.last?.releaseFinish()     // the engine has returned; the controller has not resumed yet
        XCTAssertTrue(box.handle(type: .keyDown, keyCode: Self.esc, flags: [], isRepeat: false), "the tap swallows the Esc")
        await stop.value
        XCTAssertTrue(r.inserter.calls.isEmpty, "a swallowed Esc never lets the text through")
        XCTAssertNil(r.history.last, "and nothing is kept")
        XCTAssertEqual(r.notifier.notices, [.cancelled])
        XCTAssertEqual(r.controller.phase, .idle)
        XCTAssertEqual(r.sounds.played, [.start, .stop], "the capture had closed before the Esc")
    }

    // MARK: run gate on the last dictation

    func testPasteLastAndTheMenuRowsAreOffWhileARunIsActive() async {
        let r = rig { $0.finishText = "kept" }
        await r.controller.press()
        await r.controller.press()
        XCTAssertTrue(r.controller.offersLastDictation)
        let runs = PassthroughSubject<Bool, Never>()
        r.controller.observeRuns(runs)
        let changes = Box(0)
        let sub = r.controller.objectWillChange.sink { changes.value += 1 }
        runs.send(true)
        XCTAssertTrue(r.controller.runActive)
        XCTAssertGreaterThan(changes.value, 0, "the menu hears of the run")
        XCTAssertFalse(r.controller.offersLastDictation, "rows hidden during a run")
        await r.controller.pasteLast()
        XCTAssertEqual(r.inserter.calls.count, 1, "never pasted into a call")
        XCTAssertEqual(r.notifier.notices, [.busy])
        r.controller.clearRecent()
        XCTAssertNotNil(r.history.last, "no clearing during a run either")
        runs.send(false)
        XCTAssertTrue(r.controller.offersLastDictation)
        await r.controller.pasteLast()
        XCTAssertEqual(r.inserter.calls.count, 2)
        sub.cancel()

        // The gate alone, with a run that starts while the menu closes.
        let g = rig { $0.finishText = "kept" }
        await g.controller.press()
        await g.controller.press()
        let active = Box(false)
        g.controller.isRunActive = { active.value }
        g.clock.onSleep = { _ in active.value = true }
        await g.controller.pasteLast()
        XCTAssertEqual(g.inserter.calls.count, 1, "a run that started while the menu closed: no paste")
        XCTAssertEqual(g.notifier.notices, [.busy])
        XCTAssertFalse(g.controller.offersLastDictation)
    }

    // MARK: history writes and clear

    func testHistoryWritesLeaveTheMainActorAndKeepTheirOrder() async throws {
        let url = try tempDir().appendingPathComponent("dictation-recent.json")
        let queue = DispatchQueue(label: "verse.tests.history-writes")
        queue.suspend()
        let h = DictationHistory(fileURL: url, writeQueue: queue)
        h.add(DictationRecord(text: "a", date: Date(timeIntervalSince1970: 1), app: nil))
        h.add(DictationRecord(text: "b", date: Date(timeIntervalSince1970: 2), app: nil))
        h.clear()
        h.add(DictationRecord(text: "c", date: Date(timeIntervalSince1970: 3), app: nil))
        XCTAssertEqual(h.records.map(\.text), ["c"], "memory changes at once")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing was written on the caller's thread")
        queue.resume()
        await h.waitForWrites()
        XCTAssertEqual(DictationHistory(fileURL: url).records.map(\.text), ["c"], "the latest change is the file: writes kept their order")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path),
                       ["dictation-recent.json"], "no temporary file left behind")
    }

    func testClearRecentEmptiesMemoryAndTheFile() async throws {
        let url = try tempDir().appendingPathComponent("dictation-recent.json")
        let r = rig(history: DictationHistory(fileURL: url)) { $0.finishText = "private words" }
        await r.controller.press()
        await r.controller.press()
        await r.history.waitForWrites()
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("private words"))
        r.controller.clearRecent()
        XCTAssertNil(r.history.last)
        XCTAssertFalse(r.controller.offersLastDictation, "the rows go with the list")
        await r.history.waitForWrites()
        XCTAssertEqual(DictationHistory(fileURL: url).records, [])
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("private words"), "gone from the file")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        r.history.add(DictationRecord(text: "again", date: Date(), app: nil))
        r.settings.enabled = false
        r.controller.clearRecent()
        XCTAssertEqual(r.history.last?.text, "again", "dictation off: the row is not there and clear does nothing")
    }

    // MARK: silent microphone on delivered audio

    func testNoAudioCallbacksIsLoggedNotShownAsAMutedMicrophone() async {
        let r = rig { $0.audioSeconds = 0; $0.finishText = "" }
        await r.controller.press()
        r.clock.t = 1.0
        r.ticker.fire()
        r.clock.t = 2.0
        r.ticker.fire()
        XCTAssertTrue(r.notifier.notices.isEmpty, "no callbacks is not \"Is it muted?\"")
        XCTAssertEqual(r.logs.value.filter { $0.contains("no callbacks") }.count, 1, "logged once")
        XCTAssertEqual(r.ticker.running, 1, "still watching: audio may still arrive")
        await r.controller.press()
        XCTAssertEqual(r.notifier.notices, [.nothingHeard], "the end notice does not blame a muted microphone either")
        XCTAssertTrue(r.logs.value.contains("dictation: the microphone delivered no audio"))
    }

    func testAGapInTheCallbacksIsNotSilenceUntilASecondOfAudioArrived() async {
        let r = rig { $0.peak = 0; $0.audioSeconds = 0.4 }
        await r.controller.press()
        r.clock.t = 3
        r.ticker.fire()
        XCTAssertTrue(r.notifier.notices.isEmpty, "open 3 s but only 0.4 s of audio: undecided")
        r.last?.audioSeconds = 1.2
        r.ticker.fire()
        XCTAssertEqual(r.notifier.notices, [.microphoneSilent], "a second of delivered zeros")
    }
}

/// A thread-safe counter for handlers that may run off the main actor.
final class OSAllocatedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
