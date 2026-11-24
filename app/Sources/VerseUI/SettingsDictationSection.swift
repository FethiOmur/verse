import AppKit
import ApplicationServices
import SwiftUI

/// Settings > Dictation: the on/off switch, the two keys (Fn + Space and ⌃⌥⌘D), the dictation language, and what keeps it from
/// working (⌃⌥⌘D held by another app, the missing Accessibility permission, which Fn + Space and typing both need).
struct SettingsDictationSection: View {
    @ObservedObject var dictation: DictationController
    @ObservedObject private var settings: DictationSettings
    /// Read when the page appears (and after the switch is turned on); granting it in System Settings shows on the next visit.
    @State private var accessibilityTrusted = true

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
    }

    static var accessibilityDetail: String {
        L10n.tr("Missing: dictated text goes to the clipboard instead of being typed, and \(DictationController.fnSpaceLabel) does not work (\(DictationController.hotKeyLabel) does).")
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
            if settings.enabled && (!accessibilityTrusted || dictation.fnSpaceUnavailable) {
                HomeRowDivider()
                HomeRow("Accessibility permission", verbatimDetail: Self.accessibilityDetail) {
                    HomeSecondaryButton("Open System Settings…") { NSWorkspace.shared.open(Self.accessibilityPane) }
                }
            }
        }
        .onAppear { refresh() }
        .onChange(of: settings.enabled) { refresh() }
    }

    /// Reads the permission (no prompt) and installs Fn + Space if it was granted since.
    private func refresh() {
        accessibilityTrusted = AXIsProcessTrusted()
        dictation.refreshFnSpace()
    }
}
