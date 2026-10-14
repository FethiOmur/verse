import Combine
import Foundation
import VerseTurns

/// Overlay text size.
public enum TextScale: String, CaseIterable, Sendable, Identifiable {
    case small = "S", medium = "M", large = "L"
    public var id: String { rawValue }
    public var factor: CGFloat {
        switch self {
        case .small: return 0.88
        case .medium: return 1.0
        case .large: return 1.16
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
    @Published public var budgetUSD: Double { didSet { defaults.set(budgetUSD, forKey: "budgetUSD") } }
    @Published public var textScale: TextScale { didSet { defaults.set(textScale.rawValue, forKey: "textScale") } }
    @Published public var cardTimeout: Double { didSet { defaults.set(cardTimeout, forKey: "cardTimeout") } }
    @Published public var cardWidth: Double { didSet { defaults.set(cardWidth, forKey: "cardWidth") } }
    @Published public var cardMaxHeight: Double { didSet { defaults.set(cardMaxHeight, forKey: "cardMaxHeight") } }
    /// The session folder name chosen in the menu.
    @Published public var sessionName: String { didSet { defaults.set(sessionName, forKey: "sessionName") } }
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
        budgetUSD = d.object(forKey: "budgetUSD") as? Double ?? 3.0
        textScale = TextScale(rawValue: d.string(forKey: "textScale") ?? "") ?? .medium
        cardTimeout = d.object(forKey: "cardTimeout") as? Double ?? 45
        cardWidth = (d.object(forKey: "cardWidth") as? Double ?? 560).clamped(to: Self.cardWidthRange)
        cardMaxHeight = (d.object(forKey: "cardMaxHeight") as? Double ?? 460).clamped(to: Self.cardMaxHeightRange)
        sessionName = d.string(forKey: "sessionName") ?? ""
        fakeBrain = d.bool(forKey: "fakeBrain")
        testAudioPath = d.string(forKey: "testAudioPath") ?? ""
    }

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
        OverlayConfig(cardTimeout: cardTimeout, otherNames: Self.list(otherParticipants))
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
