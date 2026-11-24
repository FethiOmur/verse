import Combine
import Foundation

/// Settings of dictation (Fn + Space or ⌃⌥⌘D: speak, and the text is typed into the app in front), in the same `UserDefaults` suite as
/// `AppSettings` (own keys), the way `MeetingSettings` keeps its own.
@MainActor
public final class DictationSettings: ObservableObject {
    /// The languages dictation can listen in: the on-device Apple engines (`EngineFactory.defaultKind`: `SpeechTranscriber` for
    /// en/it, `DictationTranscriber` for tr).
    public static let languages = ["en", "it", "tr"]

    /// The language a first dictation uses: the first of the system's preferred languages (`tr-TR`, `en-GB`, …) that dictation
    /// can listen in, else English.
    public static func defaultLanguage(preferred: [String] = Locale.preferredLanguages) -> String {
        for id in preferred {
            if let code = Locale.Language(identifier: id).languageCode?.identifier, languages.contains(code) { return code }
        }
        return "en"
    }

    private let defaults: UserDefaults

    /// Off by default. Off: no key is registered and no event tap installed, so ⌃⌥⌘D and Fn + Space belong to other apps.
    @Published public var enabled: Bool { didSet { defaults.set(enabled, forKey: "dictationEnabled") } }
    /// "en", "it" or "tr". Takes effect at the next dictation. Until it is chosen: `defaultLanguage()`.
    @Published public var language: String { didSet { defaults.set(language, forKey: "dictationLanguage") } }
    /// The system's Accessibility prompt was asked for once (the first dictation that needed the permission). It is never
    /// asked for again; Settings shows the missing permission instead.
    @Published public var accessibilityPrompted: Bool { didSet { defaults.set(accessibilityPrompted, forKey: "dictationAXPrompted") } }

    public init(defaults: UserDefaults? = nil, preferredLanguages: [String] = Locale.preferredLanguages) {
        let d = defaults ?? (Bundle.main.bundleIdentifier == AppSettings.suiteName ? .standard
                                                                                 : UserDefaults(suiteName: AppSettings.suiteName) ?? .standard)
        self.defaults = d
        enabled = d.bool(forKey: "dictationEnabled")
        let fallback = Self.defaultLanguage(preferred: preferredLanguages)
        let stored = d.string(forKey: "dictationLanguage") ?? fallback
        language = Self.languages.contains(stored) ? stored : fallback
        accessibilityPrompted = d.bool(forKey: "dictationAXPrompted")
    }
}
