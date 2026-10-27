import Foundation

/// What the notch says about the time left of a live call's walkthrough.
public enum TimeCue: Equatable, Sendable {
    /// The last minute before the end.
    case soon
    /// The end has come (for a minute and a half).
    case now
}

/// A calm time cue for one call (opt-in): `call.json` in the session folder may carry `walkthrough_end` (wall-clock "HH:MM",
/// 24 h, local time) or `minutes_from_start`. A session without the file, or without these keys, has no cue and nothing changes.
public struct CallCue: Equatable, Sendable {
    /// The end, in epoch seconds.
    public var end: TimeInterval

    public static let soonSeconds: TimeInterval = 60
    public static let nowSeconds: TimeInterval = 90

    public init(end: TimeInterval) { self.end = end }

    /// The cue to show at `now`: `.soon` in the last minute, `.now` for 90 s from the end, nothing before and after.
    public func phase(now: TimeInterval) -> TimeCue? {
        if now >= end - Self.soonSeconds, now < end { return .soon }
        if now >= end, now < end + Self.nowSeconds { return .now }
        return nil
    }

    /// Reads `<sessionDir>/call.json` at session start. nil when there is no file, no time key, or the time is unusable.
    public static func load(sessionDir: URL, now: Date = Date(), calendar: Calendar = .current) -> CallCue? {
        guard let data = try? Data(contentsOf: sessionDir.appendingPathComponent("call.json")),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return parse(obj, now: now, calendar: calendar)
    }

    static func parse(_ obj: [String: Any], now: Date, calendar: Calendar = .current) -> CallCue? {
        if let text = obj["walkthrough_end"] as? String {
            let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m),
                  let at = calendar.date(bySettingHour: h, minute: m, second: 0, of: now) else { return nil }
            return CallCue(end: at.timeIntervalSince1970)
        }
        if let n = obj["minutes_from_start"] as? NSNumber, n.doubleValue > 0, n.doubleValue <= 600 {
            return CallCue(end: now.timeIntervalSince1970 + n.doubleValue * 60)
        }
        return nil
    }
}
