import Foundation

/// The language a call starts in (owner decisions 7 and 8, 24 Nov 2026). Every start path (Start, Start unprepared, the meeting
/// prompt, autostart, Retry) asks Settings' "Default call language": Auto (the default) or a pinned language, kept for the case
/// detection gets it wrong. The menu has no language row.
///
/// In Auto the recognizers start in the session's prepared language (else English) and follow the spoken language from then on
/// (`AutoLanguageDetector`, VerseSpeech); the cards follow the call's dominant language (brain runtime/lang.py), which starts at the
/// same prepared language. The prepared language is a hint for the first seconds, never a lock.
public enum CallLanguage {
    /// `AppSettings.autoLanguage` and `AppSettings.pinnableLanguages`, readable off the main actor.
    static let auto = "auto"
    static let pinnable = ["en", "it", "tr"]

    public struct Start: Equatable, Sendable {
        /// The language the recognizers start in.
        public var engine: String
        /// Auto: the call follows the spoken language.
        public var auto: Bool
        /// Auto only: where the brain's dominant (answer) language begins, the session's prepared language. nil: `engine`.
        public var hint: String?

        public init(engine: String, auto: Bool, hint: String?) {
            self.engine = engine
            self.auto = auto
            self.hint = hint
        }
    }

    /// `requested`: "auto" or a pinned language (Settings). `prepared`: the session's prepared language, nil for none.
    public static func start(requested: String, prepared: String?) -> Start {
        guard requested == auto else {
            return Start(engine: pinnable.contains(requested) ? requested : "en", auto: false, hint: nil)
        }
        let p = prepared.flatMap { pinnable.contains($0) ? $0 : nil }
        return Start(engine: p ?? "en", auto: true, hint: p)
    }

    /// The language a session folder was prepared in: `meta.json` `languages[0]` (a prep), else its `lang` (an unprepared folder,
    /// where "auto" means none). nil when the file is missing or names none of en, it, tr.
    public static func prepared(sessionDir: URL) -> String? {
        guard let d = try? Data(contentsOf: sessionDir.appendingPathComponent("meta.json")),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        let first = (o["languages"] as? [Any])?.first as? String ?? o["lang"] as? String
        guard let l = first?.lowercased(), pinnable.contains(l) else { return nil }
        return l
    }
}
