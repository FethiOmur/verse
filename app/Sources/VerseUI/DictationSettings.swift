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
    /// The short start and stop cues (`DictationSound`). On by default.
    @Published public var sounds: Bool { didSet { defaults.set(sounds, forKey: "dictationSounds") } }

    /// The small recording indicator at the top of the screen while a dictation is under way (gap G5). On by default.
    @Published public var showIndicator: Bool { didSet { defaults.set(showIndicator, forKey: "dictationIndicator") } }
    /// The indicator shows the words recognised so far. On by default; only matters while `showIndicator` is on.
    @Published public var indicatorLiveText: Bool { didSet { defaults.set(indicatorLiveText, forKey: "dictationIndicatorLiveText") } }

    /// The custom vocabulary as typed in Settings: one term per line (gap G3). `vocabularyTerms` is what the engine gets.
    @Published public var vocabulary: String { didSet { defaults.set(vocabulary, forKey: "dictationVocabulary") } }

    /// At most this many terms reach the engine (TypeWhisper's SpeechAnalyzer plugin uses the same cap).
    nonisolated public static let vocabularyCap = 100

    /// The vocabulary's terms: one per line, trimmed, empty lines dropped, the first spelling of a repeated term kept
    /// (case-insensitive), at most `vocabularyCap`.
    nonisolated public static func terms(fromVocabulary text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let term = line.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            out.append(term)
            if out.count == vocabularyCap { break }
        }
        return out
    }

    public var vocabularyTerms: [String] { Self.terms(fromVocabulary: vocabulary) }

    public init(defaults: UserDefaults? = nil, preferredLanguages: [String] = Locale.preferredLanguages) {
        let d = defaults ?? (Bundle.main.bundleIdentifier == AppSettings.suiteName ? .standard
                                                                                 : UserDefaults(suiteName: AppSettings.suiteName) ?? .standard)
        self.defaults = d
        enabled = d.bool(forKey: "dictationEnabled")
        let fallback = Self.defaultLanguage(preferred: preferredLanguages)
        let stored = d.string(forKey: "dictationLanguage") ?? fallback
        language = Self.languages.contains(stored) ? stored : fallback
        accessibilityPrompted = d.bool(forKey: "dictationAXPrompted")
        sounds = d.object(forKey: "dictationSounds") as? Bool ?? true
        showIndicator = d.object(forKey: "dictationIndicator") as? Bool ?? true
        indicatorLiveText = d.object(forKey: "dictationIndicatorLiveText") as? Bool ?? true
        vocabulary = d.string(forKey: "dictationVocabulary") ?? ""
    }
}
