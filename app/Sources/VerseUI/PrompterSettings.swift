import Combine
import Foundation
import VersePrompter

/// The prompter's own settings, stored next to `AppSettings` in the same `UserDefaults` suite under `prompter.*` keys.
/// A separate object so the shared `AppSettings` stays untouched.
@MainActor
public final class PrompterSettings: ObservableObject {
    public static let wordsPerMinuteRange = PrompterSession.speedRange
    public static let fontSizeRange = PrompterGeometry.fontSizeRange

    private let defaults: UserDefaults

    /// Word tracking (default), voice-paced or classic.
    @Published public var mode: PrompterMode { didSet { defaults.set(mode.rawValue, forKey: "prompter.mode") } }
    /// Speed for classic and voice-paced reading.
    @Published public var wordsPerMinute: Double {
        didSet {
            let clamped = wordsPerMinute.clamped(to: Self.wordsPerMinuteRange)
            if clamped != wordsPerMinute { wordsPerMinute = clamped; return }
            defaults.set(wordsPerMinute, forKey: "prompter.wordsPerMinute")
        }
    }
    @Published public var fontSize: Double {
        didSet {
            let clamped = fontSize.clamped(to: Self.fontSizeRange)
            if clamped != fontSize { fontSize = clamped; return }
            defaults.set(fontSize, forKey: "prompter.fontSize")
        }
    }
    /// Flip the text left to right (for a teleprompter glass).
    @Published public var mirror: Bool { didSet { defaults.set(mirror, forKey: "prompter.mirror") } }
    /// Keep the panel out of screen shares while the prompter is open.
    @Published public var hideFromShare: Bool { didSet { defaults.set(hideFromShare, forKey: "prompter.hideFromShare") } }
    /// During a meeting, the current card's SAY text becomes the script.
    @Published public var followMeetingCards: Bool { didSet { defaults.set(followMeetingCards, forKey: "prompter.followMeetingCards") } }

    public init(defaults: UserDefaults? = nil) {
        // Same rule as AppSettings: inside the bundle the standard defaults are that suite already.
        let d = defaults ?? (Bundle.main.bundleIdentifier == AppSettings.suiteName ? .standard
                             : UserDefaults(suiteName: AppSettings.suiteName) ?? .standard)
        self.defaults = d
        mode = PrompterMode(rawValue: d.string(forKey: "prompter.mode") ?? "") ?? .wordTracking
        wordsPerMinute = (d.object(forKey: "prompter.wordsPerMinute") as? Double ?? 150).clamped(to: Self.wordsPerMinuteRange)
        fontSize = (d.object(forKey: "prompter.fontSize") as? Double ?? 26).clamped(to: Self.fontSizeRange)
        mirror = d.bool(forKey: "prompter.mirror")
        hideFromShare = d.object(forKey: "prompter.hideFromShare") as? Bool ?? true
        followMeetingCards = d.bool(forKey: "prompter.followMeetingCards")
    }
}

extension PrompterMode {
    /// The name in Settings.
    public var title: String {
        switch self {
        case .wordTracking: return "Word tracking"
        case .voicePaced: return "Voice-paced"
        case .classic: return "Classic (timer)"
        }
    }

    public var explanation: String {
        switch self {
        case .wordTracking: return "Follows the words you say. Needs the microphone."
        case .voicePaced: return "Moves at the set speed while you speak and stops when you stop."
        case .classic: return "Moves at the set speed. No microphone."
        }
    }
}
