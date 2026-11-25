import AppKit
import ApplicationServices
import SwiftUI

/// Settings > Dictation: the on/off switch, the two keys (Fn + Space and ⌃⌥⌘D) and Esc, hold to talk, Return after inserting, the dictation language, the
/// start/stop sounds, the recording indicator (and its live text), the vocabulary, the corrections (G11), smart spacing and
/// capitalisation (G13), the per-app languages set from the menu (G12), and the Accessibility permission (granted, or missing with the way to System Settings: Fn + Space and typing both need it),
/// plus ⌃⌥⌘D held by another app.
struct SettingsDictationSection: View {
    @ObservedObject var dictation: DictationController
    @ObservedObject private var settings: DictationSettings
    /// Read when the page appears (and after the switch is turned on); granting it in System Settings shows on the next visit.
    @State private var accessibilityTrusted = true
    @Environment(\.homeInk) private var ink

    init(dictation: DictationController) {
        self.dictation = dictation
        _settings = ObservedObject(wrappedValue: dictation.settings)
    }

    static let accessibilityPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let keyboardPane = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    /// The switch's description.
    static func status(hotKeyRefused: Bool, fnSpaceActive: Bool, engine: DictationEngine = .apple) -> String {
        let fn = DictationController.fnSpaceLabel, hotKey = DictationController.hotKeyLabel
        if hotKeyRefused && fnSpaceActive {
            return L10n.tr("\(hotKey) is used by another app; \(fn) still works.")
        }
        if hotKeyRefused {
            return L10n.tr("\(hotKey) is used by another app, so dictation cannot start. Free it there and turn dictation off and on.")
        }
        if engine == .groq {
            return L10n.tr("Press \(fn) or \(hotKey), speak, press it again: the text goes where the cursor is. The recording goes to Groq for the final text; never while Verse is listening.")
        }
        return L10n.tr("Press \(fn) or \(hotKey), speak, press it again: the text goes where the cursor is. On-device; never while Verse is listening.")
    }

    /// The engine row's help line: where the audio goes (the privacy rule: it leaves the Mac only with Groq selected).
    static func engineDetail(_ engine: DictationEngine) -> String {
        switch engine {
        case .apple:
            return L10n.tr("On device: the audio never leaves the Mac.")
        case .groq:
            return L10n.tr("The live preview stays on device. When you stop, the recording is sent to Groq (Whisper) for the final text, which handles mixed languages better. Without a key or a connection, the on-device text is used.")
        }
    }

    /// The Groq key's note, with the Terminal command that saves it the same way.
    static var groqKeyNote: String {
        L10n.tr("Kept only in the login Keychain. From Terminal: \(GroqKey.terminalCommand)")
    }

    static var shortcutsDetail: String {
        L10n.tr("\(DictationController.fnSpaceLabel) or \(DictationController.hotKeyLabel). If the 🌐 key also switches the input source or opens emoji, set System Settings › Keyboard › “Press 🌐 key to” to “Do Nothing”.")
            + " " + escapeDetail
    }

    /// Hold to talk (gap G8): Fn + Space held stops on release; ⌃⌥⌘D stays a toggle.
    static var holdToTalkDetail: String {
        L10n.tr("Hold \(DictationController.fnSpaceLabel) while you speak and let go to stop. A short press starts, the next press stops; \(DictationController.hotKeyLabel) always works that way.")
    }

    /// Esc cancels through the Fn + Space event tap only: without the Accessibility permission there is no Esc cancel.
    static var escapeDetail: String {
        L10n.tr("Esc cancels a dictation under way, nothing is typed. Like \(DictationController.fnSpaceLabel), it needs the Accessibility permission.")
    }

    /// The vocabulary field's help: what it does, and that only the Turkish engine uses it (`AppleDictationTranscriber.config`).
    static func vocabularyDetail(lang: String) -> String {
        let what = L10n.tr("Names and terms dictation should know, one per line (up to \(DictationSettings.vocabularyCap)).")
        if AppleDictationTranscriber.vocabularyTakesEffect(lang: lang) {
            return what + " " + L10n.tr("Turkish dictation uses them as hints.")
        }
        return what + " " + L10n.tr("Only Turkish dictation uses them: the English and Italian engine ignores them.")
    }

    /// The corrections field's help (gap G11).
    static var correctionsDetail: String {
        L10n.tr("Fix words dictation keeps getting wrong, one per line as “heard -> wanted”. Whole words only, any capitalisation, in every language (up to \(DictationCorrections.cap)).")
    }

    /// The per-app languages' help (gap G12).
    static var appLanguagesDetail: String {
        L10n.tr("Set in the menu bar: Dictation language › Always use … in the app in front. Dictation listens in that language whenever the app is in front.")
    }

    /// An app's name from its bundle id, else the bundle id. Looked up once per bundle id: the view body asks on every render.
    @MainActor static func appName(bundleID: String) -> String {
        if let known = appNames[bundleID] { return known }
        var name = bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let display = FileManager.default.displayName(atPath: url.path)
            name = display.hasSuffix(".app") ? String(display.dropLast(4)) : display
        }
        appNames[bundleID] = name
        return name
    }
    @MainActor private static var appNames: [String: String] = [:]

    static var accessibilityDetail: String {
        L10n.tr("Missing: dictated text goes to the clipboard instead of being typed, and \(DictationController.fnSpaceLabel) does not work (\(DictationController.hotKeyLabel) does).")
    }

    /// The permission row's line: granted (Fn + Space is live), or what is missing and that granting it is enough.
    static func permissionDetail(fnSpaceReady: Bool) -> String {
        let fn = DictationController.fnSpaceLabel
        if fnSpaceReady { return L10n.tr("Granted: \(fn) is active.") }
        return accessibilityDetail + " " + L10n.tr("Once it is granted, \(fn) works within a few seconds; no restart needed.")
    }

    var body: some View {
        HomeGroup {
            HomeToggleRow("Dictation", verbatimDetail: Self.status(hotKeyRefused: dictation.hotKeyRefused,
                                                                     fnSpaceActive: dictation.fnSpaceActive,
                                                                     engine: settings.engine),
                          isOn: $settings.enabled)
            HomeRowDivider()
            HomeRow("Dictation shortcuts", verbatimDetail: Self.shortcutsDetail) {
                HomeSecondaryButton("Keyboard Settings…") { NSWorkspace.shared.open(Self.keyboardPane) }
            }
            .disabled(!settings.enabled)
            HomeRowDivider()
            HomeToggleRow("Hold to talk", verbatimDetail: Self.holdToTalkDetail, isOn: $settings.holdToTalk)
                .disabled(!settings.enabled)
            HomeRowDivider()
            HomeToggleRow("Press Return after inserting",
                          detail: "After the text is pasted, Return is pressed too, so a chat message is sent. Not after “Paste last dictation”, and not in a terminal, where it would run the text as a command.",
                          isOn: $settings.pressReturnAfterInsert)
                .disabled(!settings.enabled)
            HomeRowDivider()
            HomeRow("Dictation language") {
                HomePopup(selection: $settings.language,
                          options: DictationSettings.languages.map { HomeOption(verbatim: StartRoutes.languageName($0), $0) })
            }
            .disabled(!settings.enabled)
            HomeRowDivider()
            HomeRow("Dictation engine", verbatimDetail: Self.engineDetail(settings.engine)) {
                HomePopup(selection: $settings.engine,
                          options: [HomeOption("Apple (on device)", DictationEngine.apple),
                                    HomeOption("Groq Whisper (cloud)", DictationEngine.groq)])
            }
            .disabled(!settings.enabled)
            if settings.engine == .groq {
                HomeRowDivider()
                HomeKeyRows(name: L10n.tr("Groq API key"), placeholder: "gsk_…",
                            removeNote: L10n.tr("Dictation uses the on-device text until a key is saved again."),
                            status: { (GroqKey.hasKey, GroqKey.last4) },
                            save: { try GroqKey.save($0) },
                            remove: { try GroqKey.remove() })
                    .padding(.leading, 16)
                HomeNote(verbatim: Self.groqKeyNote, isError: false).padding(.horizontal, 30).padding(.bottom, 10)
                    .textSelection(.enabled)
            }
            HomeRowDivider()
            HomeToggleRow("Dictation sounds", detail: "A short drum when listening starts, a softer one when it stops.",
                          isOn: $settings.sounds)
                .disabled(!settings.enabled)
            HomeRowDivider()
            HomeToggleRow("Show indicator while dictating",
                          detail: "A small capsule at the top of the screen with the level and the time while you dictate.",
                          isOn: $settings.showIndicator)
                .disabled(!settings.enabled)
            HomeRowDivider()
            HomeToggleRow("Show live text", detail: "The indicator shows the last words recognised so far.",
                          isOn: $settings.indicatorLiveText)
                .padding(.leading, 16)
                .disabled(!settings.enabled || !settings.showIndicator)
            HomeRowDivider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Vocabulary", bundle: .module).font(VT.Font.body).foregroundStyle(ink.primary)
                Text(verbatim: Self.vocabularyDetail(lang: settings.language))
                    .font(VT.Font.caption).foregroundStyle(ink.tertiary).fixedSize(horizontal: false, vertical: true)
                HomeTextArea(text: $settings.vocabulary, placeholder: "One term per line", minHeight: 54)
            }
            .padding(14)
            .disabled(!settings.enabled)
            HomeRowDivider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Corrections", bundle: .module).font(VT.Font.body).foregroundStyle(ink.primary)
                Text(verbatim: Self.correctionsDetail)
                    .font(VT.Font.caption).foregroundStyle(ink.tertiary).fixedSize(horizontal: false, vertical: true)
                HomeTextArea(text: $settings.corrections, placeholder: "heard -> wanted", minHeight: 54)
            }
            .padding(14)
            .disabled(!settings.enabled)
            HomeRowDivider()
            HomeToggleRow("Smart spacing and capitalisation",
                          detail: "Adds a space, lower-cases the first word mid-sentence and drops a stray final period, from the text around the cursor. Apps whose text cannot be read get the text as it is.",
                          isOn: $settings.smartInsertion)
                .disabled(!settings.enabled)
            if !settings.appLanguages.isEmpty {
                HomeRowDivider()
                HomeRow("Per-app languages", verbatimDetail: Self.appLanguagesDetail) { EmptyView() }
                ForEach(settings.appLanguages.keys.sorted(), id: \.self) { bundleID in
                    HomeRow(verbatim: Self.appName(bundleID: bundleID),
                            detail: StartRoutes.languageName(settings.appLanguages[bundleID] ?? settings.language)) {
                        HomeSecondaryButton("Remove") { settings.setLanguage(nil, forApp: bundleID) }
                    }
                    .padding(.leading, 16)
                }
                .disabled(!settings.enabled)
            }
            if settings.enabled {
                let ready = accessibilityTrusted && dictation.fnSpaceActive
                HomeRowDivider()
                HomeRow("Accessibility permission", verbatimDetail: Self.permissionDetail(fnSpaceReady: ready)) {
                    if ready {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(ink.secondary)
                            .accessibilityHidden(true)
                    } else {
                        HomeSecondaryButton("Open System Settings…") { NSWorkspace.shared.open(Self.accessibilityPane) }
                    }
                }
            }
        }
        .onAppear { refresh() }
        .onChange(of: settings.enabled) { refresh() }
        // The controller's permission watch installs Fn + Space the moment the permission is granted: follow it here.
        .onChange(of: dictation.fnSpaceActive) { accessibilityTrusted = AXIsProcessTrusted() }
    }

    /// Reads the permission and installs Fn + Space if it was granted since (the controller may show the system prompt, once
    /// per launch, if it has not yet).
    private func refresh() {
        accessibilityTrusted = AXIsProcessTrusted()
        dictation.refreshFnSpace()
    }
}
