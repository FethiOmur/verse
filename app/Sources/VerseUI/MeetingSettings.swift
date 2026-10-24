import Combine
import Foundation
import VerseAudio

/// Settings of the meeting-wiring features, in the same `UserDefaults` suite as `AppSettings` (own keys).
@MainActor
public final class MeetingSettings: ObservableObject {
    /// The vault the summary is written to (spec: "vault path" is a setting). From the owner profile; empty without one.
    public static let defaultVaultPath = OwnerProfile.current.vaultPath ?? ""

    private let defaults: UserDefaults

    /// Watch the meeting apps' microphone and offer "Meeting detected · Start Verse?". Reads only Core Audio's
    /// "is running input" flag of known apps; no audio, no permission.
    @Published public var detectMeetings: Bool { didSet { defaults.set(detectMeetings, forKey: "meetingDetect") } }
    /// Match a call (and upcoming meetings) against the calendar. Off until the Calendar permission was granted.
    @Published public var useCalendar: Bool { didSet { defaults.set(useCalendar, forKey: "meetingCalendar") } }
    /// After a meeting, ask "Save summary to vault?". Off by default; even when on, nothing is written without the click.
    @Published public var offerSummaryToVault: Bool { didSet { defaults.set(offerSummaryToVault, forKey: "summaryToVault") } }
    /// "Follow my answer": when the owner leaves the card, the brain watches his speech and updates the card in his direction
    /// (a "following you" card, covered points struck through). Sent to the brain in `start`; takes effect at the next Start.
    @Published public var followMyAnswer: Bool { didSet { defaults.set(followMyAnswer, forKey: "followMyAnswer") } }
    @Published public var vaultPath: String { didSet { defaults.set(vaultPath, forKey: "vaultPath") } }

    public init(defaults: UserDefaults? = nil) {
        let d = defaults ?? (Bundle.main.bundleIdentifier == AppSettings.suiteName ? .standard
                                                                                 : UserDefaults(suiteName: AppSettings.suiteName) ?? .standard)
        self.defaults = d
        detectMeetings = d.object(forKey: "meetingDetect") as? Bool ?? true
        useCalendar = d.bool(forKey: "meetingCalendar")
        offerSummaryToVault = d.bool(forKey: "summaryToVault")
        followMyAnswer = d.object(forKey: "followMyAnswer") as? Bool ?? true
        vaultPath = d.string(forKey: "vaultPath") ?? Self.defaultVaultPath
    }

    public var vaultURL: URL {
        URL(fileURLWithPath: (vaultPath.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath, isDirectory: true)
    }
}
