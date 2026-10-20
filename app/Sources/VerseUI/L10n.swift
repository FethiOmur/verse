import Combine
import Foundation
import SwiftUI
import os

// Interface language (spec 2.5). One String Catalog (`Resources/Localizable.xcstrings`), English at the source, with Italian
// and Turkish. Views localize through the module bundle (`Text("…", bundle: .module)`, the `Home*` components); strings made in
// models go through `L10n.tr`. The language switches at run time through `L10nState`; nothing here needs a relaunch.

/// What Settings → Appearance → Language offers. Raw values are what `AppSettings.interfaceLanguage` stores.
public enum InterfaceLanguage: String, CaseIterable, Sendable, Identifiable {
    /// Follow macOS: the first of the preferred languages that Verse speaks, else English.
    case system
    case en, it, tr

    public var id: String { rawValue }

    /// The languages the catalog carries, in the order the picker lists them after "System".
    public static let supported: [String] = ["en", "it", "tr"]

    /// The name in its own language (endonym), `nil` for `system` (that row is "System (<resolved name>)").
    public var endonym: String? {
        switch self {
        case .system: nil
        case .en: "English"
        case .it: "Italiano"
        case .tr: "Türkçe"
        }
    }

    /// The language code the UI uses: `en`, `it` or `tr`. `system` is the first entry of `preferred` whose language code
    /// Verse speaks, else `en`.
    public func resolved(preferred: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .system: Self.systemLanguage(preferred: preferred)
        case .en: "en"
        case .it: "it"
        case .tr: "tr"
        }
    }

    /// "System" resolved against a list of preferred languages (`tr-TR`, `it_IT`, `en-US`, …).
    public static func systemLanguage(preferred: [String] = Locale.preferredLanguages) -> String {
        for id in preferred {
            if let code = Locale.Language(identifier: id).languageCode?.identifier, supported.contains(code) { return code }
        }
        return "en"
    }
}

/// The language the interface is in right now, readable from any thread. Written only by `L10nState`.
private let currentCode = OSAllocatedUnfairLock<String>(initialState: "en")

public enum L10n {
    /// The resource bundle that holds the catalog. `VerseApp` and the tests reach it through here.
    public static var bundle: Bundle { Bundle.module }

    /// The current interface language code: `en`, `it` or `tr`.
    public static var code: String { currentCode.withLock { $0 } }

    /// The locale strings are looked up in.
    public static var locale: Locale { Locale(identifier: code) }

    /// The locale dates and numbers are formatted in: `en` keeps 24-hour time (`en_GB`), Italian and Turkish follow their own.
    public static var formatLocale: Locale { formatLocale(for: code) }

    public static func formatLocale(for code: String) -> Locale {
        switch code {
        case "it": Locale(identifier: "it_IT")
        case "tr": Locale(identifier: "tr_TR")
        default: Locale(identifier: "en_GB")
        }
    }

    /// A string from the catalog for code that builds text outside a view (status lines, alerts, save panels, notes, island
    /// texts). `String(localized:bundle:locale:)` would only format with `locale`, so the lookup goes through a
    /// `LocalizedStringResource`, which really selects the language. `locale` overrides the current language (tests).
    public static func tr(_ v: String.LocalizationValue, locale: Locale? = nil) -> String {
        String(localized: LocalizedStringResource(v, locale: locale ?? self.locale, bundle: .atURL(Bundle.module.bundleURL)))
    }

    /// "$1.23" with the number written the way the interface language writes it (decimal comma in Italian and Turkish).
    public static func usd(_ value: Double, digits: Int = 2) -> String {
        "$" + value.formatted(.number.precision(.fractionLength(digits)).locale(formatLocale))
    }

    /// A fraction as a percentage in the interface language ("50%" in English and Italian, "%50" in Turkish).
    public static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)).locale(formatLocale))
    }

    /// The name of a language in its own language, for the pickers that name a call language: "English", "Italiano", "Türkçe".
    public static func endonym(of code: String) -> String {
        InterfaceLanguage(rawValue: code)?.endonym ?? code
    }

    fileprivate static func set(code: String) { currentCode.withLock { $0 = code } }
}

/// The run-time language switch. Each window root applies `.environment(\.locale, L10nState.shared.locale)` and observes this,
/// so a change repaints the open windows at once.
@MainActor
public final class L10nState: ObservableObject {
    public static let shared = L10nState()

    @Published public private(set) var language: InterfaceLanguage = .system
    /// The resolved code: `en`, `it` or `tr`.
    @Published public private(set) var code: String = "en"
    @Published public private(set) var locale: Locale = Locale(identifier: "en")

    public init() {}

    /// Applies a setting. `preferred` is injectable for tests; the app passes nothing and follows macOS.
    public func apply(_ language: InterfaceLanguage, preferred: [String] = Locale.preferredLanguages) {
        let resolved = language.resolved(preferred: preferred)
        self.language = language
        guard resolved != code else { return }
        code = resolved
        locale = Locale(identifier: resolved)
        L10n.set(code: resolved)
    }
}

/// Text matching that ignores case and accents, with Turkish folding: "İstanbul" and "istanbul" are the same word, so are
/// "perché" and "perche". Used by transcript search and folder names.
public enum TextFold {
    public static func fold(_ s: String) -> String {
        // The two Turkish i's first: lowercasing "İ" would leave a combining dot, and "ı" has no accent to strip.
        let i = s.replacingOccurrences(of: "İ", with: "i").replacingOccurrences(of: "ı", with: "i")
        var out = String.UnicodeScalarView()
        for scalar in i.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars
            where scalar.properties.generalCategory != .nonspacingMark {
            out.append(scalar)
        }
        return String(out)
    }
}

/// Applies the interface language to a window root and repaints it when the language changes: the one place the run-time
/// switch (spec 2.5) reaches SwiftUI. Roots: `HomeRoot`, `OverlayView` (island, prompter, practice overlay and meeting prompt),
/// and the menu bar menu.
private struct InterfaceLocale: ViewModifier {
    @ObservedObject private var state = L10nState.shared

    func body(content: Content) -> some View {
        content.environment(\.locale, state.locale)
    }
}

public extension View {
    /// `.environment(\.locale, L10nState.shared.locale)`, observing `L10nState` so a language change repaints this root.
    func interfaceLocale() -> some View { modifier(InterfaceLocale()) }
}
