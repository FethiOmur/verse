import Foundation

/// What counts as a real meeting for the pickers (Prepare's Up next, Practice's Upcoming): someone besides the calendar's
/// owner is on the invite, or the event carries a video-call link (Zoom, Google Meet, Teams, Webex, FaceTime) in its url,
/// location or notes. Focus blocks, reminders and solo entries are not. All-day events never count.
public enum RealMeeting {
    public static func isReal(_ e: CalendarEntry) -> Bool {
        if e.isAllDay { return false }
        return hasOtherAttendee(e) || hasMeetingLink(url: e.url, location: e.location, notes: e.notes)
    }

    /// The same test for an event already read from the calendar (all-day entries never become one). The location is not kept on
    /// `MeetingEvent`; a Zoom, Meet or Teams link found there is its `url`.
    public static func isReal(_ e: MeetingEvent) -> Bool {
        e.attendees.contains { !isSamePerson($0, e.currentUser) } || hasMeetingLink(url: e.url, location: nil, notes: e.notes)
    }

    /// An attendee who is not the owner. Matched by email (case-insensitive), or by name when neither side has an email.
    public static func hasOtherAttendee(_ e: CalendarEntry) -> Bool {
        e.attendees.contains { !isSamePerson($0, e.currentUser) }
    }

    public static func hasMeetingLink(url: URL?, location: String?, notes: String?) -> Bool {
        if MeetingLink.extract(url: url, location: location, notes: notes).provider != .other { return true }
        for text in [url?.absoluteString, location, notes] {
            guard let text, !text.isEmpty else { continue }
            let range = NSRange(location: 0, length: (text as NSString).length)
            for re in extraLinkPatterns where re.firstMatch(in: text, range: range) != nil { return true }
        }
        return false
    }

    /// `events` without the ones that are not real meetings, unless none is: then all of them (G13). The call detector attaches
    /// a real meeting over a focus block that overlaps it, and still names an event when the calendar holds nothing else.
    public static func preferReal(_ events: [MeetingEvent]) -> [MeetingEvent] {
        let real = events.filter { isReal($0) }
        return real.isEmpty ? events : real
    }

    /// The first Webex or FaceTime link in `text` (a location, say), for the events whose link `MeetingLink` does not read.
    public static func callLink(in text: String?) -> URL? {
        guard let text, !text.isEmpty else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        for re in extraLinkPatterns {
            if let m = re.firstMatch(in: text, range: range), let u = URL(string: ns.substring(with: m.range)) { return u }
        }
        return nil
    }

    /// Webex and FaceTime; Zoom, Meet and Teams come from `MeetingLink`.
    private static let extraLinkPatterns: [NSRegularExpression] = [
        #"https?://(?:[a-z0-9\-]+\.)*webex\.com/[^\s"'<>)\]]+"#,
        #"https?://facetime\.apple\.com/join[^\s"'<>)\]]*"#,
        #"facetime://[^\s"'<>)\]]+"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static func isSamePerson(_ a: Attendee, _ me: Attendee?) -> Bool {
        guard let me else { return false }
        if let x = a.email?.lowercased(), let y = me.email?.lowercased() { return x == y }
        if a.email == nil, me.email == nil, let x = a.name?.lowercased(), let y = me.name?.lowercased() { return x == y }
        return false
    }
}
