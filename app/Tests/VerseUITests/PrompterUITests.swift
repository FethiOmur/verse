import AppKit
import Foundation
import Synchronization
import Testing
import VersePrompter
import VerseSpeech
@testable import VerseUI

// T-UI: state mapping, settings, editor, the meeting-card wiring and the brain `script` contract. No audio, no window.

final class ManualPrompterClock: PrompterClock {
    private let time = Mutex(0.0)
    func now() -> TimeInterval { time.withLock { $0 } }
    func set(_ t: TimeInterval) { time.withLock { $0 = t } }
    func sleep(until deadline: TimeInterval) async throws { try await Task.sleep(for: .milliseconds(5)) }
}

func micEvent(_ text: String, channel: Channel = .me, final: Bool = false) -> TranscriptEvent {
    TranscriptEvent(channel: channel, text: text, isFinal: final, audioStart: 0, audioEnd: 0, emittedAt: 0, lang: "en")
}

/// Polls until `condition` holds (input pumps are asynchronous). False after ~3 s.
@MainActor
func waitUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<600 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("VerseUITests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
func scratchDefaults() -> UserDefaults {
    let suite = "dev.fethiverse.verse.tests.\(UUID().uuidString)"
    return UserDefaults(suiteName: suite)!
}

// MARK: - state mapping

@Suite("Prompter state mapping")
struct PrompterMappingTests {
    @Test
    func rangesSplitReadCurrentAndUpcoming() {
        let start = PrompterWordRanges(wordCount: 10, wordPosition: 0)
        #expect(start.read == 0..<0 && start.current == 0 && start.upcoming == 1..<10)

        let middle = PrompterWordRanges(wordCount: 10, wordPosition: 3.4)
        #expect(middle.read == 0..<3 && middle.current == 3 && middle.upcoming == 4..<10)
        #expect(middle.style(ofWord: 2) == .read && middle.style(ofWord: 3) == .current && middle.style(ofWord: 4) == .upcoming)

        let end = PrompterWordRanges(wordCount: 10, wordPosition: 10)
        #expect(end.read == 0..<10 && end.current == nil && end.upcoming.isEmpty)
    }

    @Test
    func doneReadsEverythingAndOddPositionsClamp() {
        #expect(PrompterWordRanges(wordCount: 5, wordPosition: 4.5, isDone: true).read == 0..<5)
        #expect(PrompterWordRanges(wordCount: 5, wordPosition: -2).read == 0..<0)
        #expect(PrompterWordRanges(wordCount: 5, wordPosition: 99).read == 0..<5)
        let empty = PrompterWordRanges(wordCount: 0, wordPosition: 0)
        #expect(empty.read.isEmpty && empty.current == nil && empty.upcoming.isEmpty)
    }

    @Test
    func rangesComeFromAState() {
        var state = PrompterState()
        state.wordCount = 8
        state.wordPosition = 2.0
        #expect(PrompterWordRanges(state: state).current == 2)
        state.isDone = true
        #expect(PrompterWordRanges(state: state).read == 0..<8)
    }

    @Test
    func hintsFollowTheState() {
        var state = PrompterState()
        #expect(PrompterHint(state: state) == nil)

        state.mode = .wordTracking
        state.isLost = true
        #expect(PrompterHint(state: state) == .lost)
        #expect(PrompterHint.lost.text == "Lost: click a word")

        state.mode = .classic       // lost only means something while tracking
        #expect(PrompterHint(state: state) == nil)

        state.notice = .fellBackToClassic(reason: "No microphone access.")
        #expect(PrompterHint(state: state) == .fellBack(reason: "No microphone access."))
        #expect(PrompterHint(state: state)?.text == "Classic mode: No microphone access.")

        state.notice = nil
        state.isLost = false
        state.isDone = true
        #expect(PrompterHint(state: state) == .done)

        let long = PrompterHint.fellBack(reason: String(repeating: "x", count: 300)).text
        #expect(long.count < 120)
    }

    @Test
    func displayKeyIgnoresFractionsOfAWord() {
        var a = PrompterState()
        a.wordCount = 10
        a.wordPosition = 3.1
        var b = a
        b.wordPosition = 3.9
        #expect(a.displayKey == b.displayKey)
        b.wordPosition = 4.0
        #expect(a.displayKey != b.displayKey)
    }
}

@Suite("Prompter layout")
struct PrompterLayoutTests {
    @Test
    func wordsWrapAtTheWidth() {
        // slots of 30 (20 + 10 space): three fit in 100, a fourth would make 120
        let layout = PrompterLayout.make(wordWidths: Array(repeating: 20, count: 7), spaceWidth: 10, maxWidth: 100)
        #expect(layout.lines == [0..<3, 3..<6, 6..<7])
        #expect(layout.lineOfWord == [0, 0, 0, 1, 1, 1, 2])
    }

    @Test
    func aWordWiderThanTheLineStandsAlone() {
        let layout = PrompterLayout.make(wordWidths: [20, 400, 20], spaceWidth: 10, maxWidth: 100)
        #expect(layout.lines == [0..<1, 1..<2, 2..<3])
    }

    @Test
    func emptyPageHasNoLines() {
        let layout = PrompterLayout.make(wordWidths: [], spaceWidth: 10, maxWidth: 100)
        #expect(layout.lines.isEmpty && layout.line(ofWordPosition: 0) == 0)
    }

    @Test
    func theCurrentLineIsAlwaysHeldOnTheEyeLine() {
        let layout = PrompterLayout.make(wordWidths: Array(repeating: 20, count: 30), spaceWidth: 10, maxWidth: 100)
        let height = PrompterGeometry.lineHeight(fontSize: 26)
        let eye = PrompterGeometry.eyeLineY(lineHeight: height)
        for position in stride(from: 0.0, through: 30.0, by: 0.5) {
            let line = layout.line(ofWordPosition: position)
            // the top of the current line, after the block moved, is the eye line
            #expect(PrompterGeometry.offset(forLine: line, lineHeight: height) + CGFloat(line) * height == eye)
        }
        #expect(layout.line(ofWordPosition: 30) == layout.lines.count - 1)     // done: the last line
        #expect(eye < height)                                                   // just under the camera, not a line down
        #expect(PrompterGeometry.viewportHeight(lineHeight: height) == eye + height * CGFloat(PrompterGeometry.visibleLines))
    }

    @Test
    @MainActor
    func measuredWidthsGrowWithTheFontSize() {
        let small = PrompterTextMeasure.widths(of: ["wonderful"], fontSize: 20)[0]
        let large = PrompterTextMeasure.widths(of: ["wonderful"], fontSize: 40)[0]
        #expect(large > small * 1.8)
    }

    @Test
    func shortcutsAreDistinctAndOffTheSimulatorKey() {
        let keys = PrompterCommand.allCases.map(\.keyCode)
        #expect(Set(keys).count == keys.count)
        #expect(PrompterCommand.allCases.allSatisfy { $0.shortcut.hasPrefix("⌃⌥") })
    }

    @Test
    func sharingTypeIsNoneOnlyWhileOpenAndHidingIsOn() {
        #expect(NotchPanelController.sharingType(prompterOpen: true, hideFromShare: true) == .none)
        #expect(NotchPanelController.sharingType(prompterOpen: true, hideFromShare: false) == .readOnly)
        #expect(NotchPanelController.sharingType(prompterOpen: false, hideFromShare: true) == .readOnly)
    }
}

// MARK: - settings

@Suite("Prompter settings")
@MainActor
struct PrompterSettingsTests {
    @Test
    func defaults() {
        let s = PrompterSettings(defaults: scratchDefaults())
        #expect(s.mode == .wordTracking)
        #expect(s.wordsPerMinute == 150 && s.fontSize == 26)
        #expect(s.mirror == false && s.hideFromShare == true && s.followMeetingCards == false)
    }

    @Test
    func valuesSurviveANewInstance() {
        let defaults = scratchDefaults()
        let a = PrompterSettings(defaults: defaults)
        a.mode = .voicePaced
        a.wordsPerMinute = 180
        a.fontSize = 32
        a.mirror = true
        a.hideFromShare = false
        a.followMeetingCards = true

        let b = PrompterSettings(defaults: defaults)
        #expect(b.mode == .voicePaced)
        #expect(b.wordsPerMinute == 180 && b.fontSize == 32)
        #expect(b.mirror && !b.hideFromShare && b.followMeetingCards)
    }

    @Test
    func outOfRangeValuesAreClampedWhenSetAndWhenRead() {
        let defaults = scratchDefaults()
        let a = PrompterSettings(defaults: defaults)
        a.wordsPerMinute = 5000
        a.fontSize = 3
        #expect(a.wordsPerMinute == PrompterSession.speedRange.upperBound)
        #expect(a.fontSize == PrompterGeometry.fontSizeRange.lowerBound)

        defaults.set("nonsense", forKey: "prompter.mode")
        defaults.set(1.0, forKey: "prompter.wordsPerMinute")
        let b = PrompterSettings(defaults: defaults)
        #expect(b.mode == .wordTracking)
        #expect(b.wordsPerMinute == PrompterSession.speedRange.lowerBound)
    }
}

// MARK: - editor

private struct FakeWriter: ScriptWriting {
    var result: Result<ScriptDraft, ScriptWriteError>
    func write(topic: String, seconds: Int, use: ScriptUse) async throws -> ScriptDraft { try result.get() }
}

@Suite("Script editor")
@MainActor
struct ScriptEditorTests {
    private func editor(writer: ScriptWriting = FakeWriter(result: .failure(.badOutput))) throws -> (ScriptEditorModel, URL) {
        let dir = try tempDirectory()
        return (ScriptEditorModel(store: ScriptStore(directory: dir.appendingPathComponent("scripts")), writer: writer), dir)
    }

    @Test
    func saveThenOpenGivesTheSameText() throws {
        let (e, _) = try editor()
        e.name = "Demo opener"
        e.text = "Hello there.\n\n---\n\nSecond page [pause] goes here."
        #expect(e.isDirty)
        #expect(e.save())
        #expect(!e.isDirty)
        #expect(e.entries.map(\.name) == ["Demo opener"])
        #expect(e.pageCount == 2 && e.script.pages[1].words.contains { $0.isCue })

        e.newScript()
        #expect(e.text.isEmpty && e.name == ScriptEditorModel.untitled)
        e.open(e.entries[0])
        #expect(e.text == "Hello there.\n\n---\n\nSecond page [pause] goes here." && e.name == "Demo opener" && !e.isDirty)
    }

    @Test
    func editingAfterSaveMakesItDirtyAndSavingOverwritesThatFile() throws {
        let (e, _) = try editor()
        e.name = "A"
        e.text = "one two"
        e.save()
        e.text = "one two three"
        #expect(e.isDirty)
        e.save()
        #expect(e.entries.count == 1)
        e.open(e.entries[0])
        #expect(e.text == "one two three")
    }

    @Test
    func aNewScriptNeverOverwritesAnExistingFile() throws {
        let (e, _) = try editor()
        e.text = "first"
        e.save()                       // Untitled
        e.newScript()
        e.text = "second"
        e.save()                       // Untitled 2
        #expect(Set(e.entries.map(\.name)) == ["Untitled", "Untitled 2"])
        e.open(e.entries.first { $0.name == "Untitled" }!)
        #expect(e.text == "first")
    }

    @Test
    func readingTimeUsesTheSpeed() throws {
        let (e, _) = try editor()
        e.text = Array(repeating: "word", count: 150).joined(separator: " ")
        #expect(e.wordCount == 150)
        #expect(e.readingSeconds(wordsPerMinute: 150) == 60)
    }

    @Test
    func importKeepsParagraphsOfMarkdownAndPagesOfSlides() throws {
        let (e, dir) = try editor()
        let md = dir.appendingPathComponent("talk.md")
        try "First paragraph.\n\nSecond paragraph.\n\n---\n\nPage two.".write(to: md, atomically: true, encoding: .utf8)
        e.importFile(md)
        #expect(e.name == "talk" && e.text.contains("First paragraph.\n\nSecond paragraph.") && e.pageCount == 2)
        #expect(e.isDirty)             // imported, not saved yet

        let deck = try PPTXMaker.make(slides: [["Open with the weather app."], ["Show the demo."]], in: dir)
        e.importFile(deck)
        #expect(e.name == "deck" && e.pageCount == 2)
        #expect(e.script.pages.map(\.text) == ["Open with the weather app.", "Show the demo."])
    }

    @Test
    func importErrorsAreShownAndTheTextStays() throws {
        let (e, dir) = try editor()
        e.text = "keep me"
        let odd = dir.appendingPathComponent("notes.docx")
        try "x".write(to: odd, atomically: true, encoding: .utf8)
        e.importFile(odd)
        #expect(e.text == "keep me" && e.message?.isError == true)
        let empty = dir.appendingPathComponent("empty.txt")
        try "   \n".write(to: empty, atomically: true, encoding: .utf8)
        e.importFile(empty)
        #expect(e.text == "keep me" && e.message?.isError == true)
    }

    @Test
    func writeWithVerseFillsTheEditorAndKeepsTheOldText() async throws {
        let draft = ScriptDraft(text: "Fresh script text.\n\n---\n\nPage two.", words: 5, pages: 2, targetWords: 150, usedVoiceProfile: true)
        let (e, _) = try editor(writer: FakeWriter(result: .success(draft)))
        e.text = "my old notes"
        await e.write(topic: "why I built Verse, in plain words", seconds: 60, use: .recording)
        #expect(e.text == draft.text && e.previousText == "my old notes")
        #expect(e.name == "why I built Verse, in plain")
        #expect(e.message?.isError == false && e.message?.text.contains("5 words on 2 pages") == true)
        e.restorePreviousText()
        #expect(e.text == "my old notes" && e.previousText == nil)
    }

    @Test
    func aBrainFailureIsShownInTheEditorAndChangesNothing() async throws {
        let (e, _) = try editor(writer: FakeWriter(result: .failure(.failed("no API key in the Keychain"))))
        e.text = "keep me"
        await e.write(topic: "anything", seconds: 60, use: .talk)
        #expect(e.text == "keep me" && e.previousText == nil)
        #expect(e.message == .error("no API key in the Keychain"))
        #expect(!e.isWriting)
    }

    @Test
    func anEmptyTopicDoesNotCallTheBrain() async throws {
        let (e, _) = try editor(writer: FakeWriter(result: .failure(.failed("must not run"))))
        await e.write(topic: "  \n", seconds: 60, use: .recording)
        #expect(e.message == nil)
    }
}

/// Builds a minimal .pptx (a ZIP with ppt/notesSlides/notesSlideN.xml) with the system `zip`.
enum PPTXMaker {
    static func make(slides: [[String]], in directory: URL) throws -> URL {
        let work = directory.appendingPathComponent("pptx-src")
        let notes = work.appendingPathComponent("ppt/notesSlides")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        for (i, paragraphs) in slides.enumerated() {
            let body = paragraphs.map { "<a:p><a:r><a:t>\($0)</a:t></a:r></a:p>" }.joined()
            let xml = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:notes xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree>\
            <p:sp><p:nvSpPr><p:nvPr><p:ph type="sldImg"/></p:nvPr></p:nvSpPr></p:sp>\
            <p:sp><p:nvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:txBody>\(body)</p:txBody></p:sp>\
            <p:sp><p:nvSpPr><p:nvPr><p:ph type="sldNum"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>\(i + 1)</a:t></a:r></a:p></p:txBody></p:sp>\
            </p:spTree></p:cSld></p:notes>
            """
            try xml.write(to: notes.appendingPathComponent("notesSlide\(i + 1).xml"), atomically: true, encoding: .utf8)
        }
        let out = directory.appendingPathComponent("deck.pptx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = work
        zip.arguments = ["-r", "-q", out.path, "ppt"]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw NSError(domain: "zip", code: Int(zip.terminationStatus)) }
        return out
    }
}

// MARK: - the brain `script` command from Swift

@Suite("Script writer (brain contract)")
struct ScriptWriterTests {
    @Test
    func parsesTheBrainsJSON() throws {
        let json = #"{"text":"Hello.\n\n---\n\nBye.","words":2,"pages":2,"target_words":150,"voice":true,"attempts":1,"warnings":["w"],"model":"m","usage":{},"spend_usd":0.02}"#
        let draft = try ScriptDraft.parse(Data(json.utf8))
        #expect(draft == ScriptDraft(text: "Hello.\n\n---\n\nBye.", words: 2, pages: 2, targetWords: 150, usedVoiceProfile: true,
                                     spendUSD: 0.02, warnings: ["w"]))
        #expect(throws: ScriptWriteError.badOutput) { try ScriptDraft.parse(Data("not json".utf8)) }
        #expect(throws: ScriptWriteError.badOutput) { try ScriptDraft.parse(Data(#"{"text":"  "}"#.utf8)) }
    }

    @Test
    func commandLine() {
        let args = BrainScriptWriter.arguments(topicFile: URL(fileURLWithPath: "/tmp/t.txt"), seconds: 90, use: .talk, fake: true)
        #expect(args == ["-u", "-m", "verse_brain.prep", "script", "--topic-file", "/tmp/t.txt", "--seconds", "90", "--use", "talk",
                         "--json", "--fake"])
    }

    /// The real child process with the brain's offline `--fake` model: no key, no network.
    @Test
    func runsTheBrainCommandOffline() async throws {
        let brain = URL(fileURLWithPath: #filePath)           // app/Tests/VerseUITests/<this file>
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("brain")
        guard FileManager.default.isExecutableFile(atPath: brain.appendingPathComponent(".venv/bin/python").path) else { return }
        let writer = BrainScriptWriter(brainDir: { brain }, fake: true, timeout: 60)
        let draft = try await writer.write(topic: "why I built Verse", seconds: 60, use: .recording)
        #expect(draft.pages >= 2 && (135...165).contains(draft.words) && draft.targetWords == 150)
        #expect(draft.text.contains("\n\n---\n\n"))
        #expect(ScriptParser.parse(draft.text).pages.count == draft.pages)    // the app reads the pages the brain counted
    }

    @Test
    func aBrainErrorBecomesTheMessage() async throws {
        let brain = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("brain")
        guard FileManager.default.isExecutableFile(atPath: brain.appendingPathComponent(".venv/bin/python").path) else { return }
        let writer = BrainScriptWriter(brainDir: { brain }, fake: true, timeout: 60)
        await #expect(throws: ScriptWriteError.failed("the length must be 15 to 1800 seconds, not 3")) {
            _ = try await writer.write(topic: "x", seconds: 3, use: .recording)
        }
    }

    @Test
    func missingBrainIsReported() async {
        let writer = BrainScriptWriter(brainDir: { nil })
        await #expect(throws: ScriptWriteError.brainMissing("set VERSE_BRAIN_DIR")) {
            _ = try await writer.write(topic: "x", seconds: 60, use: .recording)
        }
    }
}

// MARK: - the prompter model and the meeting card (T4)

@Suite("Prompter model")
@MainActor
struct PrompterModelTests {
    private func make(follow: Bool = true, mode: PrompterMode = .classic) -> (PrompterModel, ManualPrompterClock, Box) {
        let settings = PrompterSettings(defaults: scratchDefaults())
        settings.followMeetingCards = follow
        settings.mode = mode
        let model = PrompterModel(settings: settings)
        model.registersHotKeys = false
        let clock = ManualPrompterClock()
        let box = Box()
        model.makeSession = { script, source in
            let session: PrompterSession
            switch source {
            case .script:
                session = PrompterSession(script: script, mode: settings.mode, wordsPerMinute: 60, clock: clock, autoTick: false)
            case .meetingCard(let tap):
                session = PrompterSession(script: script, mode: .wordTracking,
                                          transcript: ExternalTranscriptSource(stream: tap.stream()), clock: clock, autoTick: false)
            }
            box.sessions.append(session)
            return session
        }
        return (model, clock, box)
    }

    final class Box { var sessions: [PrompterSession] = [] }

    private func card(_ turn: String, _ say: String?) -> OverlayCard {
        var c = OverlayCard(turnID: turn, question: "q")
        c.say = say
        return c
    }

    private let twoPages = ScriptParser.parse("The quick brown fox jumps over the lazy dog.\n\n---\n\nSecond page has more words to read aloud.")

    @Test
    func openStartsAndControlsMoveThePrompter() async {
        let (model, clock, box) = make()
        await model.open(script: twoPages)
        #expect(model.isOpen && model.page.text == "The quick brown fox jumps over the lazy dog.")
        #expect(await waitUntil { !model.state.isPaused })

        await model.jump(toWord: 4)
        #expect(await waitUntil { model.wordRanges.current == 4 })
        #expect(model.wordRanges.read == 0..<4)

        await model.nextPage()
        #expect(await waitUntil { model.state.pageIndex == 1 && model.page.text.hasPrefix("Second page") })

        await model.faster()
        #expect(await waitUntil { model.state.wordsPerMinute == 70 })
        #expect(model.settings.wordsPerMinute == 70)            // the preference follows the buttons

        await model.toggle()                                     // pause
        #expect(await waitUntil { model.state.isPaused })
        clock.set(100)                                           // paused: time passes, nothing moves
        await box.sessions[0].tick()
        #expect(await box.sessions[0].state.wordPosition == 0)

        await model.close()
        #expect(!model.isOpen)
    }

    @Test
    func aFinishedScriptStartsOverOnToggle() async {
        let (model, clock, box) = make()
        await model.open(script: ScriptParser.parse("Just a few words here."))
        clock.set(500)
        await box.sessions[0].tick()
        #expect(await waitUntil { model.state.isDone })
        #expect(model.hint == .done)
        await model.toggle()
        #expect(await waitUntil { !model.state.isDone })
    }

    @Test
    func theFirstCardOpensThePrompterAndANewCardKeepsWhatWasRead() async {
        let (model, clock, box) = make()
        let tap = model.meetingStarted()
        let first = "Sure, the clearest example is the weather app I built for my family."
        await model.handleMeetingCard(card("r1", first))
        #expect(model.isOpen && model.page.text == first)
        guard let session = box.sessions.last else { Issue.record("no session"); return }

        // He reads the first four words aloud (cumulative partials, as a recognizer sends them).
        clock.set(1)
        tap.ingest(micEvent("sure the clearest example"))
        #expect(await waitUntil { await session.state.wordPosition >= 4 })

        // The next card replaces the unread tail. What he read stays.
        let second = "It took one evening and my family used it every morning."
        await model.handleMeetingCard(card("r2", second))
        #expect(model.page.text == "Sure, the clearest example " + second)
        #expect(await session.state.wordPosition == 4)

        // Remote speech never moves it: these words are the new tail, said by the interviewer.
        clock.set(2)
        tap.ingest(micEvent("it took one evening and my family", channel: .remote))
        tap.ingest(micEvent("it took one evening and my family", channel: .remote, final: true))
        // Then he says the first three words of the new tail.
        clock.set(3)
        tap.ingest(micEvent("sure the clearest example it took one"))
        #expect(await waitUntil { await session.state.wordPosition >= 7 })
        let position = await session.state.wordPosition
        #expect(position >= 7 && position < 8)                   // only his three words moved it
        await model.close()
    }

    @Test
    func theSameSayTextTwiceDoesNothingAndAClosedCardStaysClosed() async {
        let (model, _, box) = make()
        _ = model.meetingStarted()
        await model.handleMeetingCard(card("r1", "Alpha beta gamma delta."))
        await model.handleMeetingCard(card("r1", "Alpha beta gamma delta."))
        #expect(box.sessions.count == 1)

        await model.close()
        await model.handleMeetingCard(card("r1", "Alpha beta gamma delta. And more."))   // same question, text grew
        #expect(!model.isOpen)
        await model.handleMeetingCard(card("r2", "A different answer entirely."))
        #expect(model.isOpen && box.sessions.count == 2)
        await model.close()
    }

    @Test
    func cardsAreIgnoredWhenOffAndNeverInterruptAScript() async {
        let (off, _, offBox) = make(follow: false)
        _ = off.meetingStarted()
        await off.handleMeetingCard(card("r1", "Some answer here."))
        #expect(!off.isOpen && offBox.sessions.isEmpty)

        let (on, _, onBox) = make()
        _ = on.meetingStarted()
        await on.open(script: twoPages)                          // a script being read
        await on.handleMeetingCard(card("r1", "Some answer here."))
        #expect(onBox.sessions.count == 1 && on.page.text.hasPrefix("The quick"))
        await on.close()

        let (noSay, _, noSayBox) = make()
        _ = noSay.meetingStarted()
        await noSay.handleMeetingCard(card("r1", nil))           // "Listening to the question…"
        await noSay.handleMeetingCard(nil)
        #expect(!noSay.isOpen && noSayBox.sessions.isEmpty)
    }

    @Test
    func theMeetingEndingClosesACardPrompter() async {
        let (model, _, _) = make()
        _ = model.meetingStarted()
        await model.handleMeetingCard(card("r1", "An answer to read."))
        #expect(model.isOpen)
        model.meetingEnded()
        #expect(await waitUntil { !model.isOpen })
    }

    @Test
    func theTapKeepsOnlyHisOwnChannel() async {
        let tap = MeetingMicTap()
        let stream = tap.stream()
        tap.ingest(micEvent("interviewer words", channel: .remote))
        tap.ingest(micEvent("my words", channel: .me))
        tap.finish()
        var seen: [String] = []
        for await event in stream { seen.append(event.text) }
        #expect(seen == ["my words"])
    }
}
