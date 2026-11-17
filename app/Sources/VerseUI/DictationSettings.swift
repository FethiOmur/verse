import Combine
import Foundation

/// Settings of dictation (⌃⌥⌘D: speak, and the text is typed into the app in front), in the same `UserDefaults` suite as
/// `AppSettings` (own keys), the way `MeetingSettings` keeps its own.
@MainActor
public final class DictationSettings: ObservableObject {
    /// The languages dictation can listen in: the on-device Apple engines (`EngineFactory.defaultKind`).
    public static let languages = ["en", "it", "tr"]

    private let defaults: UserDefaults

    /// Off by default. Off: the hot key is not registered at all, so ⌃⌥⌘D belongs to other apps.
    @Published public var enabled: Bool { didSet { defaults.set(enabled, forKey: "dictationEnabled") } }
    /// "en", "it" or "tr". Takes effect at the next dictation.
    @Published public var language: String { didSet { defaults.set(language, forKey: "dictationLanguage") } }
    /// The system's Accessibility prompt was asked for once (the first dictation that needed the permission). It is never
    /// asked for again; Settings shows the missing permission instead.
    @Published public var accessibilityPrompted: Bool { didSet { defaults.set(accessibilityPrompted, forKey: "dictationAXPrompted") } }

    public init(defaults: UserDefaults? = nil) {
        let d = defaults ?? (Bundle.main.bundleIdentifier == AppSettings.suiteName ? .standard
                                                                                 : UserDefaults(suiteName: AppSettings.suiteName) ?? .standard)
        self.defaults = d
        enabled = d.bool(forKey: "dictationEnabled")
        let stored = d.string(forKey: "dictationLanguage") ?? "en"
        language = Self.languages.contains(stored) ? stored : "en"
        accessibilityPrompted = d.bool(forKey: "dictationAXPrompted")
    }
}
