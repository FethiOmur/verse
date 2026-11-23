import AppKit
import ApplicationServices
import SwiftUI

/// Settings > Dictation: the on/off switch, the dictation language, and what keeps it from working (the hot key held by
/// another app, the missing Accessibility permission).
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

    private var status: String {
        if dictation.hotKeyRefused {
            return L10n.tr("\(DictationController.hotKeyLabel) is used by another app, so dictation cannot start. Free it there and turn dictation off and on.")
        }
        return L10n.tr("Press \(DictationController.hotKeyLabel), speak, press it again: the text goes where the cursor is. On-device; never while Verse is listening.")
    }

    var body: some View {
        HomeGroup {
            HomeToggleRow("Dictation", verbatimDetail: status, isOn: $settings.enabled)
            HomeRowDivider()
            HomeRow("Dictation language") {
                HomePopup(selection: $settings.language,
                          options: DictationSettings.languages.map { HomeOption(verbatim: StartRoutes.languageName($0), $0) })
            }
            .disabled(!settings.enabled)
            if settings.enabled && !accessibilityTrusted {
                HomeRowDivider()
                HomeRow("Accessibility permission",
                        verbatimDetail: L10n.tr("Missing: dictated text goes to the clipboard instead of being typed.")) {
                    HomeSecondaryButton("Open System Settings…") { NSWorkspace.shared.open(Self.accessibilityPane) }
                }
            }
        }
        .onAppear { accessibilityTrusted = AXIsProcessTrusted() }
        .onChange(of: settings.enabled) { accessibilityTrusted = AXIsProcessTrusted() }
    }
}
