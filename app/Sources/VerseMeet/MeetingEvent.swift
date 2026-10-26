import Foundation

public enum MeetingProvider: String, Sendable, Codable, Equatable, CaseIterable {
    case meet, zoom, teams, other

    public var displayName: String {
        switch self {
        case .meet: return "Google Meet"
        case .zoom: return "Zoom"
        case .teams: return "Microsoft Teams"
        case .other: return "Other"
        }
    }
}

public struct Attendee: Sendable, Codable, Equatable {
    public var name: String?
    public var email: String?

    public init(name: String? = nil, email: String? = nil) {
        self.name = name
        self.email = email
    }
}

/// One calendar event as Verse sees it. Notes and attendee emails are personal: print titles and counts only.
public struct MeetingEvent: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var attendees: [Attendee]
    public var notes: String?
    public var url: URL?
    public var provider: MeetingProvider
    /// The attendee that is the calendar's owner (EventKit's `isCurrentUser`). Absent in JSON written before memory existed (it
    /// decodes as nil), and absent when the owner is not on the invite. The brain's `prep/event.py` reads the event with `.get`
    /// and ignores this key.
    public var currentUser: Attendee?

    public init(id: String, title: String, start: Date, end: Date, attendees: [Attendee] = [],
                notes: String? = nil, url: URL? = nil, provider: MeetingProvider = .other, currentUser: Attendee? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.notes = notes
        self.url = url
        self.provider = provider
        self.currentUser = currentUser
    }

    /// The JSON the brain reads with `--from-event`: ISO 8601 dates with the local UTC offset.
    public func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .custom { date, encoder in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            f.timeZone = .current
            var c = encoder.singleValueContainer()
            try c.encode(f.string(from: date))
        }
        return try enc.encode(self)
    }
}

/// Finds the video-call link of an event: `event.url` first, then the location, then the notes.
public enum MeetingLink {
    private static let patterns: [(MeetingProvider, String)] = [
        (.meet, #"https?://meet\.google\.com/[a-z0-9][a-z0-9_\-/?=&.%]*"#),
        (.zoom, #"https?://(?:[a-z0-9\-]+\.)*zoom\.us/(?:j|my|s|wc/join)/[^\s"'<>)\]]+"#),
        (.teams, #"https?://teams\.(?:microsoft|live)\.com/(?:l/meetup-join|meet)/[^\s"'<>)\]]+"#),
    ]

    /// The first meeting link found, in the order url, location, notes. With none, provider is `.other` and the
    /// returned URL is the event's own URL (which may be nil).
    public static func extract(url: URL?, location: String?, notes: String?) -> (url: URL?, provider: MeetingProvider) {
        for text in [url?.absoluteString, location, notes] {
            guard let text, !text.isEmpty else { continue }
            if let hit = firstMatch(in: text) { return hit }
        }
        return (url, .other)
    }

    private static func firstMatch(in text: String) -> (url: URL?, provider: MeetingProvider)? {
        // Earliest link in the text wins, whatever its provider.
        var best: (offset: Int, url: URL, provider: MeetingProvider)?
        let ns = text as NSString
        for (provider, pattern) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
            var s = ns.substring(with: m.range)
            while let last = s.last, ".,;:!?".contains(last) { s.removeLast() }
            guard let u = URL(string: s) else { continue }
            if best == nil || m.range.location < best!.offset { best = (m.range.location, u, provider) }
        }
        return best.map { ($0.url, $0.provider) }
    }
}
