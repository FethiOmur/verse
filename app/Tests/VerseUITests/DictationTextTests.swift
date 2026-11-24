import Foundation
@testable import VerseUI
import XCTest

/// Gaps G11 (corrections), G12 (dictation language: per app and from the menu) and G13 (smart spacing and capitalisation):
/// the pure rules as tables, then how the controller and the inserter use them. No Accessibility calls: the focus is scripted.
extension DictationTests {

    // MARK: G11 corrections: parsing

    func testCorrectionsAreParsedOnePerLine() {
        let list = DictationCorrections.parse("""
        git hub -> GitHub
          verse   app   →  Verse
        no separator here
         -> nothing heard
        GIT HUB -> repeated, first wins
        um ->
        a->b->c
        """)
        XCTAssertEqual(list, [
            DictationCorrection(heard: "git hub", wanted: "GitHub"),
            DictationCorrection(heard: "verse app", wanted: "Verse"),
            DictationCorrection(heard: "um", wanted: ""),
            DictationCorrection(heard: "a", wanted: "b->c"),
        ])
        XCTAssertEqual(DictationCorrections.parse(""), [])
        let many = (0..<300).map { "w\($0) -> x" }.joined(separator: "\n")
        XCTAssertEqual(DictationCorrections.parse(many).count, DictationCorrections.cap)
    }

    // MARK: G11 corrections: matching

    private func fix(_ text: String, _ lines: String, lang: String = "en") -> String {
        DictationCorrections.apply(DictationCorrections.parse(lines), to: text, language: lang)
    }

    func testCorrectionsMatchWholeWordsCaseInsensitively() {
        XCTAssertEqual(fix("The cat sat on a category.", "cat -> dog"), "The dog sat on a category.", "not inside a word")
        XCTAssertEqual(fix("Cat, CAT and cat.", "cat -> dog"), "dog, dog and dog.", "any capitalisation; replaced verbatim")
        XCTAssertEqual(fix("concatenate", "cat -> dog"), "concatenate")
        XCTAssertEqual(fix("2cat cat2 cat", "cat -> dog"), "2cat cat2 dog", "digits are word characters")
        XCTAssertEqual(fix("I push to git hub daily", "git hub -> GitHub"), "I push to GitHub daily", "a phrase")
        XCTAssertEqual(fix("I push to git\nhub daily", "git hub -> GitHub"), "I push to GitHub daily",
                       "a line break inside the phrase counts as its space")
        XCTAssertEqual(fix("no change", ""), "no change")
        XCTAssertEqual(fix("", "a -> b"), "")
    }

    func testCorrectionsTakeTheLongestPhraseFirstAndNeverChain() {
        XCTAssertEqual(fix("we met in new york today", "york -> Yorkshire\nnew york -> New York"), "we met in New York today",
                       "the longer phrase wins whatever the order")
        XCTAssertEqual(fix("a b", "a -> b\nb -> c"), "b c", "a replacement is not matched again")
        XCTAssertEqual(fix("teh teh", "teh -> the teh"), "the teh the teh", "a replacement that contains the original does not expand")
    }

    func testCorrectionsWithPunctuationAtTheEdgeNeedNoBoundaryThere() {
        XCTAssertEqual(fix("I write c#.", "c# -> C#"), "I write C#.")
        XCTAssertEqual(fix("abc# stays", "c# -> C#"), "abc# stays", "the word edge still needs a boundary")
        XCTAssertEqual(fix("call me at 5 p.m. ok", "p.m. -> PM"), "call me at 5 PM ok")
    }

    func testAnEmptyReplacementRemovesThePhraseAndOneSpace() {
        XCTAssertEqual(fix("so um I think", "um ->"), "so I think")
        XCTAssertEqual(fix("um so", "um ->"), "so")
        XCTAssertEqual(fix("so um.", "um ->"), "so.")
        XCTAssertEqual(fix("um", "um ->"), "", "the whole text removed")
    }

    func testAnEmptyReplacementNextToPunctuationLeavesNoDoubleOrLeadingMark() {
        XCTAssertEqual(fix("so, um, I think", "um ->"), "so, I think", "no doubled comma")
        XCTAssertEqual(fix("Um, so I think", "um ->"), "so I think", "no leading comma")
        XCTAssertEqual(fix("so um, I think", "um ->"), "so, I think", "a comma after a word stays")
        XCTAssertEqual(fix("so, um. I think", "um ->"), "so. I think", "the sentence end wins over the comma")
        XCTAssertEqual(fix("Done. Um, next", "um ->"), "Done. next", "no comma after a period")
        XCTAssertEqual(fix("so; um; fine", "um ->"), "so; fine")
    }

    func testAPhraseMatchesARunOfWhitespaceInTheText() {
        XCTAssertEqual(fix("I push to git  hub daily", "git hub -> GitHub"), "I push to GitHub daily", "two spaces")
        XCTAssertEqual(fix("I push to git \t hub daily", "git hub -> GitHub"), "I push to GitHub daily", "mixed whitespace")
        XCTAssertEqual(fix("git hubs", "git hub -> GitHub"), "git hubs", "the word edge still needs a boundary")
    }

    func testCorrectionsFoldCaseTheTurkishWayInTurkish() {
        // Turkish: I/ı and İ/i are pairs, and ı and i are different letters.
        XCTAssertEqual(fix("IRMAK ve Irmak", "ırmak -> nehir", lang: "tr"), "nehir ve nehir")
        XCTAssertEqual(fix("İstanbul", "istanbul -> İSTANBUL", lang: "tr"), "İSTANBUL")
        XCTAssertEqual(fix("Istanbul", "istanbul -> X", lang: "tr"), "Istanbul", "dotless I is ı in Turkish, not i")
        XCTAssertEqual(fix("Kır ve KIR", "kir -> X", lang: "tr"), "Kır ve KIR", "kır is not kir")
        XCTAssertEqual(fix("KİR", "kir -> X", lang: "tr"), "X")
        XCTAssertEqual(fix("çiçek ÇİÇEK", "çiçek -> gül", lang: "tr"), "gül gül")
        XCTAssertEqual(fix("dağ dağlar", "dağ -> tepe", lang: "tr"), "tepe dağlar", "Turkish letters are word characters")
        // Other languages: I folds to i, and İ to i as well.
        XCTAssertEqual(fix("Istanbul İstanbul", "istanbul -> X", lang: "en"), "X X")
        XCTAssertEqual(fix("ID card", "id -> ID", lang: "it"), "ID card")
    }

    // MARK: G13 smart insertion

    private func smart(_ text: String, _ before: String?, _ after: String?, lang: String = "en", keep: [String] = []) -> String {
        DictationSmartInsertion.format(text, before: before, after: after, language: lang, keepCase: keep)
    }

    func testSmartInsertionLeavesTheTextAloneWithoutContext() {
        XCTAssertEqual(smart("Hello there.", nil, nil), "Hello there.", "unreadable field: as today")
        XCTAssertEqual(smart("Hello there.", "word", nil), "Hello there.", "one side unknown is unknown")
        XCTAssertEqual(smart("Hello there.", "", ""), "Hello there.", "an empty field: as dictated")
    }

    func testSmartInsertionAddsALeadingSpaceAfterAWordADigitOrClosingPunctuation() {
        XCTAssertEqual(smart("Done.", "It is", ""), " done.")
        XCTAssertEqual(smart("Apples", "Buy 12", ""), " apples")
        XCTAssertEqual(smart("Next one.", "First one.", ""), " Next one.")
        XCTAssertEqual(smart("Next one.", "(see above)", ""), " Next one.")
        XCTAssertEqual(smart("Next one.", "Really?", ""), " Next one.")
        XCTAssertEqual(smart("Next.", "Ends with a space ", ""), "next.", "a space is already there")
        XCTAssertEqual(smart(", and more", "Apples", ""), ", and more", "punctuation attaches to the word before")
        XCTAssertEqual(smart("Text", "(", ""), "Text", "after an opening bracket")
        XCTAssertEqual(smart("Text", "path/", ""), "Text")
    }

    func testSmartInsertionAddsATrailingSpaceBeforeAWord() {
        XCTAssertEqual(smart("big", "the ", "dog"), "big ")
        XCTAssertEqual(smart("Hello.", "", "World"), "Hello. ", "start of the field: a new sentence keeps its period")
        XCTAssertEqual(smart("big", "the ", " dog"), "big", "a space is already there")
        XCTAssertEqual(smart("big", "the ", ".", lang: "en"), "big", "before punctuation")
    }

    func testSmartInsertionLowerCasesTheFirstWordOnlyClearlyMidSentence() {
        XCTAssertEqual(smart("Market today.", "I went to the ", ""), "market today.")
        XCTAssertEqual(smart("Then lunch.", "Coffee, ", ""), "then lunch.", "after a comma")
        XCTAssertEqual(smart("Then lunch.", "Coffee; ", ""), "then lunch.", "after a semicolon")
        XCTAssertEqual(smart("Then lunch.", "Coffee. ", ""), "Then lunch.", "a new sentence")
        XCTAssertEqual(smart("Then lunch.", "Coffee! ", ""), "Then lunch.")
        XCTAssertEqual(smart("Then lunch.", "Coffee: ", ""), "Then lunch.", "a colon may start a sentence")
        XCTAssertEqual(smart("Then lunch.", "Coffee\n", ""), "Then lunch.", "a new line")
        XCTAssertEqual(smart("Then lunch.", "Coffee \n  ", ""), "Then lunch.", "a new line, then spaces")
        XCTAssertEqual(smart("Then lunch.", "  ", ""), "Then lunch.", "only spaces before")
    }

    func testSmartInsertionKeepsNamesCapitalsAndI() {
        XCTAssertEqual(smart("I think so.", "and ", ""), "I think so.", "a lone English I")
        XCTAssertEqual(smart("I'm late.", "and ", ""), "I'm late.")
        XCTAssertEqual(smart("I’ll go.", "and ", ""), "I’ll go.")
        XCTAssertEqual(smart("NASA called.", "and ", ""), "NASA called.", "all capitals")
        XCTAssertEqual(smart("OK then.", "and ", ""), "OK then.")
        XCTAssertEqual(smart("GitHub is down.", "and ", ""), "GitHub is down.", "a capital inside the word")
        XCTAssertEqual(smart("Paris is nice.", "and ", "", keep: ["Paris"]), "Paris is nice.", "a vocabulary term")
        XCTAssertEqual(smart("New York is big.", "and ", "", keep: ["New York"]), "New York is big.", "a vocabulary phrase")
        XCTAssertEqual(smart("A cat.", "and ", ""), "a cat.", "a single capital other than I")
        XCTAssertEqual(smart("42 items.", "and ", ""), "42 items.", "no letter to lower-case")
        XCTAssertEqual(smart("“Quoted”", "and ", ""), "“Quoted”", "not a letter first")
    }

    func testSmartInsertionLowerCasesTheTurkishWayInTurkish() {
        XCTAssertEqual(smart("Işık yandı.", "bugün ", "", lang: "tr"), "ışık yandı.", "I -> ı in Turkish")
        XCTAssertEqual(smart("İyi oldu.", "bence ", "", lang: "tr"), "iyi oldu.", "İ -> i")
        XCTAssertEqual(smart("Çok güzel.", "bence ", "", lang: "tr"), "çok güzel.")
        XCTAssertEqual(smart("Işık yandı.", "today ", "", lang: "en"), "işık yandı.", "other languages: I -> i")
        XCTAssertEqual(smart("İyi oldu.", "today ", "", lang: "en"), "iyi oldu.", "İ -> i, not i with a combining dot")
        XCTAssertEqual(smart("Ciao a tutti.", "e poi ", "", lang: "it"), "ciao a tutti.")
    }

    func testSmartInsertionKeepsATurkishProperNounWithASuffix() {
        XCTAssertEqual(smart("Ankara'ya gittim.", "Dün ", "", lang: "tr"), "Ankara'ya gittim.", "an apostrophe suffix: a name")
        XCTAssertEqual(smart("İstanbul’da kaldım.", "Dün ", "", lang: "tr"), "İstanbul’da kaldım.", "a typographic apostrophe")
        XCTAssertEqual(smart("Ahmet'e söyledim.", "bence ", "", lang: "tr"), "Ahmet'e söyledim.")
        XCTAssertEqual(smart("Bugün geldi.", "Dün ", "", lang: "tr"), "bugün geldi.", "no apostrophe: lower-cased as before")
        XCTAssertEqual(smart("That's it.", "and ", "", lang: "en"), "that's it.", "only Turkish reads the apostrophe as a name")
        XCTAssertEqual(smart("Ankara' dedi.", "Dün ", "", lang: "tr"), "ankara' dedi.", "an apostrophe without a suffix")
    }

    func testSmartInsertionDropsTheFinalPeriodWhereItDoesNotBelong() {
        XCTAssertEqual(smart("Hello.", "I said ", ", then left"), "hello", "punctuation follows")
        XCTAssertEqual(smart("Hello.", "", "!"), "Hello", "punctuation follows, even at the start")
        XCTAssertEqual(smart("Report.", "Send the ", " tomorrow"), "report", "mid-sentence before more text")
        XCTAssertEqual(smart("Report.", "Send the ", "tomorrow"), "report ", "and a space before the word")
        XCTAssertEqual(smart("Report.", "Send the ", " \nNext line"), "report.", "more text only on the next line")
        XCTAssertEqual(smart("Report.", "Send the ", ""), "report.", "nothing after: kept")
        XCTAssertEqual(smart("Report.", "Done. ", " Next"), "Report.", "not mid-sentence: kept")
        XCTAssertEqual(smart("Wait...", "and ", ", then"), "wait...", "an ellipsis stays")
        XCTAssertEqual(smart("Wait…", "and ", ", then"), "wait…")
        XCTAssertEqual(smart("Really?", "and ", ", then"), "really?", "only a period goes")
        XCTAssertEqual(smart(".", "and ", ","), ".", "a lone period stays")
    }

    // MARK: G12 language

    func testLanguageResolutionPrefersThePerAppChoice() {
        let R = DictationLanguageChoice.self
        let apps = ["com.example.chat": "tr", "com.example.code": "en", "com.example.bad": "de"]
        XCTAssertEqual(R.resolve(defaultLanguage: "it", perApp: apps, bundleID: "com.example.chat"), "tr")
        XCTAssertEqual(R.resolve(defaultLanguage: "it", perApp: apps, bundleID: "com.example.code"), "en")
        XCTAssertEqual(R.resolve(defaultLanguage: "it", perApp: apps, bundleID: "com.example.other"), "it", "no choice: the default")
        XCTAssertEqual(R.resolve(defaultLanguage: "it", perApp: apps, bundleID: nil), "it", "no app in front")
        XCTAssertEqual(R.resolve(defaultLanguage: "it", perApp: apps, bundleID: "com.example.bad"), "it", "unknown language ignored")
        XCTAssertEqual(R.resolve(defaultLanguage: "xx", perApp: [:], bundleID: nil), "en")
        XCTAssertEqual(R.shortCode("tr"), "TR")
    }

    func testNewDictationSettingsPersist() {
        let d = defaults()
        let s = DictationSettings(defaults: d, preferredLanguages: ["en-US"])
        XCTAssertTrue(s.smartInsertion, "smart insertion is on by default")
        XCTAssertEqual(s.corrections, "")
        XCTAssertEqual(s.appLanguages, [:])
        s.smartInsertion = false
        s.corrections = "git hub -> GitHub"
        s.setLanguage("tr", forApp: "com.example.chat")
        s.setLanguage("it", forApp: "com.example.mail")
        s.setLanguage("de", forApp: "com.example.code")
        XCTAssertEqual(s.appLanguages, ["com.example.chat": "tr", "com.example.mail": "it"], "an unknown language is not stored")
        s.setLanguage(nil, forApp: "com.example.mail")

        let again = DictationSettings(defaults: d, preferredLanguages: ["en-US"])
        XCTAssertFalse(again.smartInsertion)
        XCTAssertEqual(again.correctionList, [DictationCorrection(heard: "git hub", wanted: "GitHub")])
        XCTAssertEqual(again.appLanguages, ["com.example.chat": "tr"])
        XCTAssertEqual(again.language(forApp: "com.example.chat"), "tr")
        XCTAssertEqual(again.language(forApp: "com.example.mail"), "en")

        d.set(["com.example.x": "xx", "com.example.y": "it"], forKey: "dictationAppLanguages")
        XCTAssertEqual(DictationSettings(defaults: d).appLanguages, ["com.example.y": "it"], "stored junk is dropped")
    }

    // MARK: the controller

    func testADictationListensInTheLanguageOfTheAppInFront() async {
        let r = rig(lang: "en") { $0.finishText = "ciao" }
        r.settings.setLanguage("it", forApp: "com.example.notes")
        await r.controller.press()
        XCTAssertEqual(r.last?.began, ["it"], "the per-app language")
        XCTAssertEqual(r.controller.indicator.content?.language, "it", "shown in the indicator")
        XCTAssertTrue(r.logs.value.contains("dictation: recording lang=it (app) vocabulary=0"))
        await r.controller.press()
        XCTAssertEqual(r.inserter.formattings, [DictationInsertFormatting(language: "it")], "smart insertion in that language")

        r.frontBundle.value = "com.example.other"
        await r.controller.press()
        XCTAssertEqual(r.last?.began, ["en"], "another app: the default")
        XCTAssertTrue(r.logs.value.contains("dictation: recording lang=en vocabulary=0"))
        // A change of the default while recording applies to the next dictation.
        r.settings.language = "tr"
        await r.controller.press()
        XCTAssertEqual(r.inserter.formattings.last, DictationInsertFormatting(language: "en"))
        await r.controller.press()
        XCTAssertEqual(r.last?.began, ["tr"])
        r.controller.cancelByKey()
    }

    func testCorrectionsApplyBeforeInsertionAndToTheRecentList() async {
        let r = rig(lang: "tr") { $0.finishText = "  Bunu git hub üzerinden KIR değil kır olarak yaz  " }
        r.settings.corrections = "git hub -> GitHub\nkır -> çayır"
        r.settings.vocabulary = "GitHub"
        await r.controller.press()
        await r.controller.press()
        let expected = "Bunu GitHub üzerinden çayır değil çayır olarak yaz"
        XCTAssertEqual(r.inserter.calls.map(\.text), [expected])
        XCTAssertEqual(r.controller.lastDictation?.text, expected, "the recent list keeps the corrected text")
        XCTAssertEqual(r.inserter.formattings, [DictationInsertFormatting(language: "tr", keepCase: ["GitHub"])],
                       "vocabulary terms keep their case mid-sentence")
    }

    func testATranscriptTheCorrectionsEmptyInsertsNothing() async {
        let r = rig { $0.finishText = "um" }
        r.settings.corrections = "um ->"
        await r.controller.press()
        await r.controller.press()
        XCTAssertTrue(r.inserter.calls.isEmpty)
        XCTAssertNil(r.controller.lastDictation)
        XCTAssertEqual(r.notifier.notices, [.nothingHeard])
    }

    func testSmartInsertionOffInsertsAsDictatedAndPasteLastFollowsTheAppInFront() async {
        let r = rig(lang: "en") { $0.finishText = "hello" }
        r.settings.smartInsertion = false
        await r.controller.press()
        await r.controller.press()
        XCTAssertEqual(r.inserter.formattings, [nil])

        r.settings.smartInsertion = true
        r.settings.setLanguage("tr", forApp: "com.example.chat")
        r.frontBundle.value = "com.example.chat"
        await r.controller.pasteLast()
        XCTAssertEqual(r.inserter.calls.map(\.text), ["hello", "hello"])
        XCTAssertEqual(r.inserter.formattings.last, DictationInsertFormatting(language: "tr"),
                       "paste last: smart insertion in the language of the app it goes to")
    }

    // MARK: the inserter

    private func contextField(chars: Int, before: String?, after: String?, id: Int = 1) -> DictationFocusSnapshot {
        DictationFocusSnapshot(kind: .element, role: "AXTextField", editable: true, identity: id, characterCount: chars,
                               selectionLocation: chars, selectionLength: 0, textBefore: before, textAfter: after)
    }

    private func smartInserter(_ focus: FakeFocus, pb: FakePasteboard, keys: FakeKeystroke,
                               logs: Box<[String]>) -> PasteboardTextInserter {
        PasteboardTextInserter(accessibility: FakeAccessibility(trusted: true), pasteboard: pb, keystroke: keys, focus: focus,
                               sleep: { _ in }, log: { logs.value.append($0) })
    }

    func testTheInserterPastesTheTextAdjustedToTheCaret() async {
        let pb = FakePasteboard(), keys = FakeKeystroke(), logs = Box<[String]>([])
        pb.externalCopy("old")
        let focus = FakeFocus(contextField(chars: 13, before: "I went to the", after: ""), .field(chars: 21, at: 21))
        let inserter = smartInserter(focus, pb: pb, keys: keys, logs: logs)
        var pasted: String?
        keys.onPost = { pasted = pb.string }

        let outcome = await inserter.insert("Market today.", mayPromptForPermission: false,
                                            formatting: DictationInsertFormatting(language: "en"))
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(pasted, " market today.", "a space, mid-sentence lower case")
        XCTAssertEqual(pb.string, "old", "restored")
        XCTAssertEqual(focus.reads, 2, "the context comes from the same read before the paste")
        XCTAssertEqual(logs.value, ["dictation: smart insertion adjusted the text", "dictation: paste check delivered"])
    }

    func testAMissedPasteLeavesTheAdjustedTextOnTheClipboard() async {
        let pb = FakePasteboard(), keys = FakeKeystroke(), logs = Box<[String]>([])
        let focus = FakeFocus(contextField(chars: 9, before: "Send the ", after: " tomorrow"),
                              .field(chars: 9, at: 9))
        let inserter = smartInserter(focus, pb: pb, keys: keys, logs: logs)
        let outcome = await inserter.insert("Report.", mayPromptForPermission: false,
                                            formatting: DictationInsertFormatting(language: "en"))
        XCTAssertEqual(outcome, .notInserted)
        XCTAssertEqual(pb.string, "report", "the text that was pasted, not the transcript")
    }

    func testUnreadableContextOrNoFormattingInsertsTheTextAsItIs() async {
        for (snapshot, formatting) in [
            (DictationFocusSnapshot.unverifiableWeb, DictationInsertFormatting(language: "en")),
            (contextField(chars: 5, before: nil, after: nil), DictationInsertFormatting(language: "en")),
            (contextField(chars: 5, before: "Hello", after: ""), nil),
        ] {
            let pb = FakePasteboard(), keys = FakeKeystroke(), logs = Box<[String]>([])
            let focus = FakeFocus(snapshot, .field(chars: 20, at: 20))
            let inserter = smartInserter(focus, pb: pb, keys: keys, logs: logs)
            var pasted: String?
            keys.onPost = { pasted = pb.string }
            _ = await inserter.insert("Market today.", mayPromptForPermission: false, formatting: formatting)
            XCTAssertEqual(pasted, "Market today.")
            XCTAssertFalse(logs.value.contains("dictation: smart insertion adjusted the text"))
        }
        // Without the permission: the transcript on the clipboard, untouched.
        let pb = FakePasteboard()
        let inserter = PasteboardTextInserter(accessibility: FakeAccessibility(trusted: false), pasteboard: pb,
                                              keystroke: FakeKeystroke(), focus: FakeFocus(.unverifiableWeb), sleep: { _ in },
                                              log: { _ in })
        let outcome = await inserter.insert("Market today.", mayPromptForPermission: false,
                                            formatting: DictationInsertFormatting(language: "en"))
        XCTAssertEqual(outcome, .copiedToClipboard)
        XCTAssertEqual(pb.string, "Market today.")
    }

    // MARK: the indicator

    func testTheIndicatorMakesRoomForTheLanguageCode() {
        let plain = DictationIndicatorContent(stage: .recording)
        var withLanguage = plain
        withLanguage.language = "tr"
        XCTAssertEqual(DictationIndicatorView.layoutWidth(plain), DictationIndicatorView.width)
        XCTAssertEqual(DictationIndicatorView.layoutWidth(withLanguage),
                       DictationIndicatorView.width + DictationIndicatorView.languageWidth + 10)
    }
}
