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
    /// Prepare a session in the background for an upcoming real meeting that has none (owner decision 3): once per occurrence,
    /// never while a call or practice runs. On by default; it only acts while "Use my calendar" is on.
    @Published public var autoPrepare: Bool { didSet { defaults.set(autoPrepare, forKey: "meetingAutoPrepare") } }
    /// The one-time "Turn on" row (menu and Home) was used or put away: it is not shown again.
    @Published public var calendarNudgeDone: Bool { didSet { defaults.set(calendarNudgeDone, forKey: "calendarNudgeDone") } }
    /// Occurrence key -> when the background prep was tried for it (success or not), so a relaunch never pays for it twice.
    /// Not published: writing it must not re-run the watchers.
    public var autoPrepAttempted: [String: Date] {
        get {
            (defaults.dictionary(forKey: "meetingAutoPrepAttempted") as? [String: Double] ?? [:])
                .mapValues { Date(timeIntervalSince1970: $0) }
        }
        set { defaults.set(newValue.mapValues(\.timeIntervalSince1970), forKey: "meetingAutoPrepAttempted") }
    }
    /// When each background prep started (not the ones started by hand), for the daily cap (`AutoPrepGate.dailyCap`); kept
    /// across relaunches so a relaunch does not reset the count. Not published, like `autoPrepAttempted`.
    public var autoPrepBackgroundRuns: [Date] {
        get { (defaults.array(forKey: "meetingAutoPrepRuns") as? [Double] ?? []).map { Date(timeIntervalSince1970: $0) } }
        set { defaults.set(newValue.map(\.timeIntervalSince1970), forKey: "meetingAutoPrepRuns") }
    }

    public init(defaults: UserDefaults? = nil) {
        let d = defaults ?? (Bundle.main.bundleIdentifier == AppSettings.suiteName ? .standard
                                                                                 : UserDefaults(suiteName: AppSettings.suiteName) ?? .standard)
        self.defaults = d
        detectMeetings = d.object(forKey: "meetingDetect") as? Bool ?? true
        useCalendar = d.bool(forKey: "meetingCalendar")
        offerSummaryToVault = d.bool(forKey: "summaryToVault")
        followMyAnswer = d.object(forKey: "followMyAnswer") as? Bool ?? true
        vaultPath = d.string(forKey: "vaultPath") ?? Self.defaultVaultPath
        autoPrepare = d.object(forKey: "meetingAutoPrepare") as? Bool ?? true
        calendarNudgeDone = d.bool(forKey: "calendarNudgeDone")
    }

    public var vaultURL: URL {
        URL(fileURLWithPath: (vaultPath.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath, isDirectory: true)
    }
}
