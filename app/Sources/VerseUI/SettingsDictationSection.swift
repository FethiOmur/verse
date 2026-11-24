import AppKit
import ApplicationServices
import SwiftUI

/// Settings > Dictation: the on/off switch, the two keys (Fn + Space and ⌃⌥⌘D) and Esc, the dictation language, the
/// start/stop sounds, the vocabulary, and the Accessibility permission (granted, or missing with the way to System Settings: Fn + Space and typing both need it),
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
    static func status(hotKeyRefused: Bool, fnSpaceActive: Bool) -> String {
        let fn = DictationController.fnSpaceLabel, hotKey = DictationController.hotKeyLabel
        if hotKeyRefused && fnSpaceActive {
            return L10n.tr("\(hotKey) is used by another app; \(fn) still works.")
        }
        if hotKeyRefused {
            return L10n.tr("\(hotKey) is used by another app, so dictation cannot start. Free it there and turn dictation off and on.")
        }
        return L10n.tr("Press \(fn) or \(hotKey), speak, press it again: the text goes where the cursor is. On-device; never while Verse is listening.")
    }

    static var shortcutsDetail: String {
        L10n.tr("\(DictationController.fnSpaceLabel) or \(DictationController.hotKeyLabel). If the 🌐 key also switches the input source or opens emoji, set System Settings › Keyboard › “Press 🌐 key to” to “Do Nothing”.")
            + " " + escapeDetail
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
                                                                     fnSpaceActive: dictation.fnSpaceActive),
                          isOn: $settings.enabled)
            HomeRowDivider()
            HomeRow("Dictation shortcuts", verbatimDetail: Self.shortcutsDetail) {
                HomeSecondaryButton("Keyboard Settings…") { NSWorkspace.shared.open(Self.keyboardPane) }
            }
            .disabled(!settings.enabled)
            HomeRowDivider()
            HomeRow("Dictation language") {
                HomePopup(selection: $settings.language,
                          options: DictationSettings.languages.map { HomeOption(verbatim: StartRoutes.languageName($0), $0) })
            }
            .disabled(!settings.enabled)
            HomeRowDivider()
            HomeToggleRow("Dictation sounds", detail: "A short drum when listening starts, a softer one when it stops.",
                          isOn: $settings.sounds)
                .disabled(!settings.enabled)
            HomeRowDivider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Vocabulary", bundle: .module).font(VT.Font.body).foregroundStyle(ink.primary)
                Text(verbatim: Self.vocabularyDetail(lang: settings.language))
                    .font(VT.Font.caption).foregroundStyle(ink.tertiary).fixedSize(horizontal: false, vertical: true)
                HomeTextArea(text: $settings.vocabulary, placeholder: "One term per line", minHeight: 54)
            }
            .padding(14)
            .disabled(!settings.enabled)
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
