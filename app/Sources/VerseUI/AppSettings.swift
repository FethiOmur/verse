import Combine
import Foundation
import VerseTurns

/// Overlay text size.
public enum TextScale: String, CaseIterable, Sendable, Identifiable {
    case small = "S", medium = "M", large = "L", extraLarge = "XL"
    public var id: String { rawValue }
    /// SAY line 19 / 22 / 25 / 28 pt (UI redesign spec 2.2).
    public var factor: CGFloat {
        switch self {
        case .small: return 19.0 / 22
        case .medium: return 1.0
        case .large: return 25.0 / 22
        case .extraLarge: return 28.0 / 22
        }
    }
}

/// Everything in Settings except the API key (that lives only in the Keychain). Stored in `UserDefaults` suite
/// `dev.fethiverse.verse`.
@MainActor
public final class AppSettings: ObservableObject {
    public static let suiteName = "dev.fethiverse.verse"
    public static let cardWidthRange: ClosedRange<Double> = 420...960
    public static let cardMaxHeightRange: ClosedRange<Double> = 220...720
    /// Island veil floor (UI redesign spec 2.4). 35 % keeps points >= 7:1 over a white page.
    public static let islandOpacityRange: ClosedRange<Double> = 0.35...1
    /// Window background colour over the window glass; 1 = solid.
    public static let windowOpacityRange: ClosedRange<Double> = 0...1

    private let defaults: UserDefaults

    @Published public var ownerName: String { didSet { defaults.set(ownerName, forKey: "ownerName") } }
    /// Comma-separated spellings the recognizer produces for the owner's name.
    @Published public var ownerAliases: String { didSet { defaults.set(ownerAliases, forKey: "ownerAliases") } }
    /// Comma-separated other participants.
    @Published public var otherParticipants: String { didSet { defaults.set(otherParticipants, forKey: "otherParticipants") } }
    @Published public var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published public var cueEndpointMs: Int { didSet { defaults.set(cueEndpointMs, forKey: "cueEndpointMs") } }
    @Published public var plainEndpointMs: Int { didSet { defaults.set(plainEndpointMs, forKey: "plainEndpointMs") } }
    @Published public var matchThreshold: Double { didSet { defaults.set(matchThreshold, forKey: "matchThreshold") } }
    @Published public var textScale: TextScale { didSet { defaults.set(textScale.rawValue, forKey: "textScale") } }
    @Published public var cardTimeout: Double { didSet { defaults.set(cardTimeout, forKey: "cardTimeoutV2") } }
    @Published public var cardWidth: Double { didSet { defaults.set(cardWidth, forKey: "cardWidth") } }
    @Published public var cardMaxHeight: Double { didSet { defaults.set(cardMaxHeight, forKey: "cardMaxHeight") } }
    @Published public var islandOpacity: Double { didSet { defaults.set(islandOpacity, forKey: "islandOpacity") } }
    @Published public var windowOpacity: Double { didSet { defaults.set(windowOpacity, forKey: "windowOpacity") } }
    /// The session folder name chosen in the menu.
    @Published public var sessionName: String { didSet { defaults.set(sessionName, forKey: "sessionName") } }
    /// Anytime calls (spec 2.2): the permanent "me" layer goes into every session. Off: `start.me` is null and the prompt
    /// prefix is what it was before the layer existed.
    @Published public var useMeProfile: Bool { didSet { defaults.set(useMeProfile, forKey: "useMeProfile") } }
    /// Unprepared calls start from the standing general prep (`sessions/general-core`) when it is built.
    @Published public var useGeneralPrep: Bool { didSet { defaults.set(useGeneralPrep, forKey: "useGeneralPrep") } }
    /// The language a Start by hotkey, menu or island listens in: "auto" (the default; the call switches between en, it and tr by
    /// itself, spec 2.5 "interim AUTO"), or "en", "it", "tr" to pin one. Changed during a session from the island.
    @Published public var defaultCallLanguage: String { didSet { defaults.set(defaultCallLanguage, forKey: "defaultCallLanguage") } }
    /// Room route: cards for questions by themselves (on) or only on ⌥⌘↩ (off).
    @Published public var roomAutoCards: Bool { didSet { defaults.set(roomAutoCards, forKey: "roomAutoCards") } }
    /// What "System" resolves against. Under XCTest it is English, so a test run never depends on the language of the Mac it runs on.
    static var preferredLanguagesForUI: [String] { NSClassFromString("XCTestCase") != nil ? ["en"] : Locale.preferredLanguages }

    /// The interface language (spec 2.5): `system` (the default, follows macOS), `en`, `it` or `tr`. Changing it repaints the open
    /// windows at once through `L10nState`; call and answer languages are unaffected.
    @Published public var interfaceLanguage: InterfaceLanguage {
        didSet {
            defaults.set(interfaceLanguage.rawValue, forKey: "interfaceLanguage")
            L10nState.shared.apply(interfaceLanguage, preferred: Self.preferredLanguagesForUI)
        }
    }
    /// The model Ask this meeting answers with (spec 2.2): Haiku, Sonnet (default) or Opus, remembered app-wide.
    @Published public var askModel: AskModel { didSet { defaults.set(askModel.rawValue, forKey: "askModel") } }
    /// Testing: canned brain replies (no network, no key).
    @Published public var fakeBrain: Bool { didSet { defaults.set(fakeBrain, forKey: "fakeBrain") } }
    /// Testing: play this audio file as the meeting instead of listening live. Empty: live.
    @Published public var testAudioPath: String { didSet { defaults.set(testAudioPath, forKey: "testAudioPath") } }

    public init(defaults: UserDefaults? = nil) {
        // Inside the bundle (id dev.fethiverse.verse) the standard defaults are that suite already.
        let d = defaults ?? (Bundle.main.bundleIdentifier == Self.suiteName ? .standard : UserDefaults(suiteName: Self.suiteName) ?? .standard)
        self.defaults = d
        ownerName = d.string(forKey: "ownerName") ?? "Alex"
        ownerAliases = d.string(forKey: "ownerAliases") ?? ""
        otherParticipants = d.string(forKey: "otherParticipants") ?? ""
        language = d.string(forKey: "language") ?? "en"
        cueEndpointMs = d.object(forKey: "cueEndpointMs") as? Int ?? 300
        plainEndpointMs = d.object(forKey: "plainEndpointMs") as? Int ?? 600
        matchThreshold = d.object(forKey: "matchThreshold") as? Double ?? 0.55
        textScale = TextScale(rawValue: d.string(forKey: "textScale") ?? "") ?? .medium
        cardTimeout = d.object(forKey: "cardTimeoutV2") as? Double ?? 0
        cardWidth = (d.object(forKey: "cardWidth") as? Double ?? 600).clamped(to: Self.cardWidthRange)
        cardMaxHeight = (d.object(forKey: "cardMaxHeight") as? Double ?? 460).clamped(to: Self.cardMaxHeightRange)
        islandOpacity = (d.object(forKey: "islandOpacity") as? Double ?? 0.62).clamped(to: Self.islandOpacityRange)
        windowOpacity = (d.object(forKey: "windowOpacity") as? Double ?? 0.34).clamped(to: Self.windowOpacityRange)
        sessionName = d.string(forKey: "sessionName") ?? ""
        useMeProfile = d.object(forKey: "useMeProfile") as? Bool ?? true
        useGeneralPrep = d.object(forKey: "useGeneralPrep") as? Bool ?? true
        let callLang = d.string(forKey: "defaultCallLanguage") ?? Self.autoLanguage
        defaultCallLanguage = Self.callLanguages.contains(callLang) ? callLang : Self.autoLanguage
        roomAutoCards = d.object(forKey: "roomAutoCards") as? Bool ?? true
        let uiLanguage = InterfaceLanguage(rawValue: d.string(forKey: "interfaceLanguage") ?? "") ?? .system
        interfaceLanguage = uiLanguage
        L10nState.shared.apply(uiLanguage, preferred: Self.preferredLanguagesForUI)
        askModel = AskModel(rawValue: d.string(forKey: "askModel") ?? "") ?? .sonnet
        fakeBrain = d.bool(forKey: "fakeBrain")
        testAudioPath = d.string(forKey: "testAudioPath") ?? ""
    }

    /// The value of "Default call language" that follows the spoken language.
    public static let autoLanguage = "auto"
    /// The languages a call can be pinned to.
    public static let pinnableLanguages = ["en", "it", "tr"]
    /// Every value of "Default call language", AUTO first.
    public static let callLanguages = [autoLanguage] + pinnableLanguages

    /// The brain's `start.room_auto`.
    public var roomAuto: RoomAuto { roomAutoCards ? .questions : .off }

    public static func list(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public var turnConfig: TurnConfig {
        var t = TurnConfig()
        t.ownerName = ownerName.trimmingCharacters(in: .whitespaces).isEmpty ? "Alex" : ownerName
        t.ownerAliases = Self.list(ownerAliases)
        t.otherNames = Self.list(otherParticipants)
        t.cueEndpointMs = cueEndpointMs
        t.plainEndpointMs = plainEndpointMs
        t.matchThreshold = matchThreshold
        t.lang = language
        return t
    }

    public var overlayConfig: OverlayConfig {
        OverlayConfig(cardTimeout: cardTimeout > 0 ? cardTimeout : .infinity, otherNames: Self.list(otherParticipants))
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
