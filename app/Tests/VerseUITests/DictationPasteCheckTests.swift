import Foundation
@testable import VerseUI
import XCTest

/// The focused element as a test scripts it: each read returns the next snapshot, the last one repeats.
@MainActor
final class FakeFocus: DictationFocusProbing {
    var script: [DictationFocusSnapshot]
    private(set) var reads = 0
    init(_ snapshots: DictationFocusSnapshot...) { script = snapshots }
    func snapshot() -> DictationFocusSnapshot {
        defer { reads += 1 }
        return script[min(reads, script.count - 1)]
    }
}

/// The inserter's sleeps, recorded on the main actor (so the `@Sendable` sleep closure may hold it).
@MainActor
final class SleepLog {
    var value: [Duration] = []
    var onSleep: () -> Void = {}
}

extension DictationFocusSnapshot {
    /// A text area inside a web page: unverifiable, behaves as before the check existed.
    static let unverifiableWeb = DictationFocusSnapshot(kind: .element, role: "AXTextArea", editable: true, web: true, identity: 9)
    static let noFocus = DictationFocusSnapshot(kind: .noFocusedElement)
    /// A native text field with readable counts.
    static func field(chars: Int, at location: Int, selected: Int = 0, id: Int = 1, role: String = "AXTextField") -> Self {
        DictationFocusSnapshot(kind: .element, role: role, editable: true, identity: id, characterCount: chars,
                               selectionLocation: location, selectionLength: selected)
    }
}

/// Gap G2: whether a paste landed. The rule as a table, then the inserter's timing and clipboard handling, then the
/// controller's notice. No Accessibility calls: the focus is scripted.
extension DictationTests {

    // MARK: the rule

    func testPasteCheckVerdictTable() {
        typealias V = DictationPasteCheck.Verdict
        let field = DictationFocusSnapshot.field(chars: 10, at: 10)
        let unchanged = Array(repeating: field, count: DictationPasteCheck.attempts)
        var chromiumNoFocus = DictationFocusSnapshot.noFocus
        chromiumNoFocus.chromium = true
        var terminal = DictationFocusSnapshot.field(chars: 500, at: 500, role: "AXTextArea")
        terminal.terminal = true
        var secure = field
        secure.subrole = "AXSecureTextField"
        var settableGroup = DictationFocusSnapshot.field(chars: 3, at: 3, role: "AXGroup")
        settableGroup.editable = true
        var focusGone = field
        focusGone.kind = .noFocusedElement

        let cases: [(String, DictationFocusSnapshot, [DictationFocusSnapshot], V)] = [
            ("Accessibility did not answer", .unreadable, [], .unverifiable(.accessibilityUnavailable)),
            ("a terminal", terminal, unchanged, .unverifiable(.terminal)),
            ("no focused element", .noFocus, [], .missed(.noFocusedTextElement)),
            ("no focus reported by a Chromium app", chromiumNoFocus, [], .unverifiable(.chromiumNoFocus)),
            ("a field in a web page", .unverifiableWeb, unchanged, .unverifiable(.webContent)),
            ("the web area itself", DictationFocusSnapshot(kind: .element, role: "AXWebArea"), [], .unverifiable(.webContent)),
            ("a password field", secure, unchanged, .unverifiable(.secureField)),
            ("a text field whose counts cannot be read", DictationFocusSnapshot(kind: .element, role: "AXTextArea", editable: true),
             [], .unverifiable(.unreadableField)),
            ("a button has the focus", DictationFocusSnapshot(kind: .element, role: "AXButton"), [], .missed(.noFocusedTextElement)),
            ("a file list has the focus", DictationFocusSnapshot(kind: .element, role: "AXOutline"), [], .unverifiable(.unknownRole)),
            ("a spreadsheet table: a selected cell takes a paste", DictationFocusSnapshot(kind: .element, role: "AXTable"), [],
             .unverifiable(.unknownRole)),
            ("a spreadsheet cell", DictationFocusSnapshot(kind: .element, role: "AXCell"), [], .unverifiable(.unknownRole)),
            ("a list row", DictationFocusSnapshot(kind: .element, role: "AXRow"), [], .unverifiable(.unknownRole)),
            ("a list", DictationFocusSnapshot(kind: .element, role: "AXList"), [], .unverifiable(.unknownRole)),
            ("static text: maybe a custom editor's surface", DictationFocusSnapshot(kind: .element, role: "AXStaticText"), [],
             .unverifiable(.unknownRole)),
            ("a checkbox has the focus", DictationFocusSnapshot(kind: .element, role: "AXCheckBox"), [], .missed(.noFocusedTextElement)),
            ("a group: maybe a custom text view", DictationFocusSnapshot(kind: .element, role: "AXGroup"), [], .unverifiable(.unknownRole)),
            ("the caret moved on the third poll", field, [field, field, .field(chars: 15, at: 15)], .delivered),
            ("a selection was replaced (same length)", .field(chars: 10, at: 2, selected: 5),
             [.field(chars: 10, at: 7)], .delivered),
            ("ten polls, nothing changed", field, unchanged, .missed(.focusedTextUnchanged)),
            ("the app stopped answering after the paste", field, [field, .unreadable], .unverifiable(.accessibilityUnavailable)),
            ("the focus moved to another element", field, [.field(chars: 10, at: 10, id: 2)], .delivered),
            ("the focus went away", field, [focusGone], .delivered),
            ("a settable custom element is polled", settableGroup, [.field(chars: 4, at: 4, role: "AXGroup")], .delivered),
        ]
        for (name, before, after, want) in cases {
            XCTAssertEqual(DictationPasteCheck.verdict(before: before, after: after), want, name)
        }
        XCTAssertEqual(DictationPasteCheck.attempts, 10)
        XCTAssertEqual(DictationPasteCheck.interval, .milliseconds(50))
    }

    /// Chromium is found by the bundle's layout, not by a fixed framework name: Chrome-family browsers name the framework
    /// after themselves ("<Name> Framework.framework" with the renderer helper inside), Electron apps put the helpers next to
    /// the frameworks.
    func testChromiumIsFoundInBrowsersThatNameTheFrameworkAfterThemselves() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("verse-chromium-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        func app(_ name: String, _ paths: [String]) throws -> URL {
            let url = root.appendingPathComponent("\(name).app")
            for p in paths {
                try fm.createDirectory(at: url.appendingPathComponent("Contents/Frameworks/\(p)"), withIntermediateDirectories: true)
            }
            return url
        }
        let browser = try app("Some Browser", ["Some Browser Framework.framework/Helpers/Some Browser Helper (Renderer).app",
                                               "Some Browser Framework.framework/Helpers/Some Browser Helper.app"])
        let versioned = try app("Other Browser", ["Other Browser Framework.framework/Versions/Current/Helpers/Other Browser Helper (Renderer).app"])
        let electron = try app("Notes Tool", ["Notes Tool Helper (Renderer).app", "Squirrel.framework"])
        let chrome = try app("Chrome Like", ["Google Chrome Framework.framework"])
        let native = try app("Native Editor", ["Sparkle.framework", "Native Editor Framework.framework/Resources"])
        let bare = root.appendingPathComponent("Bare.app")

        XCTAssertTrue(SystemFocusProbe.embedsChromium(bundleURL: browser, fileManager: fm), "a Chrome-family browser")
        XCTAssertTrue(SystemFocusProbe.embedsChromium(bundleURL: versioned, fileManager: fm), "helpers under Versions/Current")
        XCTAssertTrue(SystemFocusProbe.embedsChromium(bundleURL: electron, fileManager: fm), "Electron helpers")
        XCTAssertTrue(SystemFocusProbe.embedsChromium(bundleURL: chrome, fileManager: fm))
        XCTAssertFalse(SystemFocusProbe.embedsChromium(bundleURL: native, fileManager: fm), "a framework without a renderer helper")
        XCTAssertFalse(SystemFocusProbe.embedsChromium(bundleURL: bare, fileManager: fm), "no Frameworks folder")
    }

    // MARK: the inserter

    private func checkedInserter(_ focus: FakeFocus, pb: FakePasteboard, keys: FakeKeystroke, sleeps: SleepLog,
                                 logs: Box<[String]>) -> PasteboardTextInserter {
        PasteboardTextInserter(accessibility: FakeAccessibility(trusted: true), pasteboard: pb, keystroke: keys, focus: focus,
                               sleep: { d in await MainActor.run { sleeps.value.append(d); sleeps.onSleep() } },
                               log: { logs.value.append($0) })
    }

    func testADeliveredPasteStopsPollingAtTheChangeAndRestoresTheClipboardOnTime() async {
        let pb = FakePasteboard(), keys = FakeKeystroke(), sleeps = SleepLog(), logs = Box<[String]>([])
        pb.externalCopy("old")
        let focus = FakeFocus(.field(chars: 4, at: 4), .field(chars: 4, at: 4), .field(chars: 12, at: 12))
        let inserter = checkedInserter(focus, pb: pb, keys: keys, sleeps: sleeps, logs: logs)

        let outcome = await inserter.insert("dictated", mayPromptForPermission: false)
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(focus.reads, 3, "one read before the paste, polls until the change")
        XCTAssertEqual(sleeps.value, [.milliseconds(50), .milliseconds(50), .milliseconds(500)])
        XCTAssertEqual(sleeps.value.reduce(.zero, +), PasteboardTextInserter.defaultRestoreDelay, "the restore keeps its timing")
        XCTAssertEqual(pb.string, "old", "restored")
        XCTAssertEqual(logs.value, ["dictation: paste check delivered"])
    }

    func testNoFocusedTextElementLeavesTheTextOnTheClipboardAndSkipsTheRestore() async {
        let pb = FakePasteboard(), keys = FakeKeystroke(), sleeps = SleepLog(), logs = Box<[String]>([])
        pb.externalCopy("old")
        let focus = FakeFocus(.noFocus)
        let inserter = checkedInserter(focus, pb: pb, keys: keys, sleeps: sleeps, logs: logs)

        let outcome = await inserter.insert("Lost words", mayPromptForPermission: false)
        XCTAssertEqual(outcome, .notInserted)
        XCTAssertEqual(keys.posted, 1, "the paste was still tried")
        XCTAssertEqual(focus.reads, 1, "nothing to poll")
        XCTAssertTrue(sleeps.value.isEmpty, "no wait: nothing will be restored")
        XCTAssertEqual(pb.string, "Lost words", "left on the clipboard")
        XCTAssertEqual(pb.transientWrites, 1, "rewritten without the transient marker, so clipboard managers keep it")
        XCTAssertEqual(logs.value, ["dictation: paste check missed (noFocusedTextElement)"])
        XCTAssertFalse(logs.value.joined().contains("Lost"), "the log has the kind, never the text")
    }

    func testAnUnchangedFieldIsPolledTenTimesThenMissed() async {
        let pb = FakePasteboard(), keys = FakeKeystroke(), sleeps = SleepLog(), logs = Box<[String]>([])
        pb.externalCopy("old")
        let focus = FakeFocus(.field(chars: 4, at: 4))
        let inserter = checkedInserter(focus, pb: pb, keys: keys, sleeps: sleeps, logs: logs)

        let outcome = await inserter.insert("dictated", mayPromptForPermission: false)
        XCTAssertEqual(outcome, .notInserted)
        XCTAssertEqual(focus.reads, 11)
        XCTAssertEqual(sleeps.value, Array(repeating: .milliseconds(50), count: 10))
        XCTAssertEqual(pb.string, "dictated")
        XCTAssertEqual(logs.value, ["dictation: paste check missed (focusedTextUnchanged)"])
    }

    func testAnUnverifiablePasteBehavesAsBefore() async {
        let pb = FakePasteboard(), keys = FakeKeystroke(), sleeps = SleepLog(), logs = Box<[String]>([])
        pb.externalCopy("old")
        let focus = FakeFocus(.unverifiableWeb)
        let inserter = checkedInserter(focus, pb: pb, keys: keys, sleeps: sleeps, logs: logs)

        let outcome = await inserter.insert("dictated", mayPromptForPermission: false)
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(focus.reads, 1)
        XCTAssertEqual(sleeps.value, [PasteboardTextInserter.defaultRestoreDelay])
        XCTAssertEqual(pb.string, "old", "restored as before")
        XCTAssertEqual(logs.value, ["dictation: paste check unverifiable (webContent)"])
    }

    func testAMissedPasteDoesNotOverwriteSomethingCopiedMeanwhile() async {
        let pb = FakePasteboard(), keys = FakeKeystroke(), sleeps = SleepLog(), logs = Box<[String]>([])
        let focus = FakeFocus(.field(chars: 4, at: 4))
        let inserter = checkedInserter(focus, pb: pb, keys: keys, sleeps: sleeps, logs: logs)
        sleeps.onSleep = { if sleeps.value.count == 5 { pb.externalCopy("newer") } }
        let outcome = await inserter.insert("dictated", mayPromptForPermission: false)
        XCTAssertEqual(pb.string, "newer")
        XCTAssertEqual(outcome, .notInsertedClipboardChanged,
                       "not on the clipboard any more, so no 'press ⌘V' notice (it is in the recent list), and not logged as pasted")
        XCTAssertEqual(logs.value, ["dictation: paste check missed (focusedTextUnchanged)"])
    }

    // MARK: the controller

    func testANotInsertedPasteShowsTheClipboardNoticeAfterADictationAndForPasteLast() async {
        let r = rig { $0.finishText = "words that went nowhere" }
        r.inserter.outcome = .notInserted
        await r.controller.press()
        await r.controller.press()
        XCTAssertEqual(r.notifier.notices, [.notInserted])
        XCTAssertEqual(r.controller.lastDictation?.text, "words that went nowhere", "still kept in the recent list")
        XCTAssertTrue(r.logs.value.contains("dictation: notInserted chars=23"))
        XCTAssertEqual(r.controller.phase, .idle)

        await r.controller.pasteLast()
        XCTAssertEqual(r.notifier.notices, [.notInserted, .notInserted], "Paste last dictation uses the same check")
        XCTAssertEqual(DictationNotice.notInserted.text, "Not inserted. It is on the clipboard: press ⌘V")
    }
}
