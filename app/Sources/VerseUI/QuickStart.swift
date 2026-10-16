import Foundation
import VerseMeet
import VerseTurns

/// Start anytime (anytime-calls spec 2.1): what ⌥⌘V, the menu's "Start now" and the island's idle state decide. Pure
/// functions and small value types, so the choices are tested without audio, a calendar or a window.
public enum QuickStart {
    // MARK: route

    /// What the Mac knows when Start is pressed.
    public struct RouteFacts: Sendable, Equatable {
        /// A Continuity (iPhone) call is active on this Mac. Always false until phase B detects it.
        public var phoneCallActive: Bool
        /// A known meeting app has microphone input running right now (the detector's own fact).
        public var meetingAppHoldsMic: Bool

        public init(phoneCallActive: Bool = false, meetingAppHoldsMic: Bool = false) {
            self.phoneCallActive = phoneCallActive
            self.meetingAppHoldsMic = meetingAppHoldsMic
        }
    }

    /// phone, then meeting, then room (spec 2.1 "Audio route").
    public static func pickRoute(_ facts: RouteFacts) -> AudioRoute {
        if facts.phoneCallActive { return .phone }
        if facts.meetingAppHoldsMic { return .meeting }
        return .room
    }

    /// The phone route needs its tap source (phase B). Until that ships it is not started: a phone call is heard through
    /// the room route (the call on the Mac speaker).
    public static func runnableRoute(_ route: AudioRoute) -> AudioRoute {
        route == .phone ? .room : route
    }

    /// True when a process that is a known meeting app has microphone input running. Reads Core Audio flags only.
    public static func meetingAppHoldsMic(_ processes: [AudioProcessInfo], apps: [MeetingApp] = MeetingApp.known) -> Bool {
        processes.contains { p in p.isRunningInput && apps.contains { $0.matches(p.bundleID) } }
    }

    // MARK: session

    public enum SessionChoice: Sendable, Equatable {
        /// A prepared session linked to a calendar event around now.
        case prepared(String)
        /// Nothing prepared for now: an unprepared (adhoc) session is created.
        case adhoc
    }

    /// A prepared session is used when it is linked (`EventSessionMap`) to an event within this long of now.
    public static let eventWindow: TimeInterval = 15 * 60

    /// An event counts when it overlaps `[now - 15 min, now + 15 min]` (so a call that is already running counts too). The
    /// one running now wins, else the one starting nearest to now; the first of those with a remembered session that still
    /// exists decides. No such event: adhoc.
    public static func pickSession(now: Date, events: [MeetingEvent], remembered: [String: String], sessions: [String]) -> SessionChoice {
        let near = events.filter {
            $0.start <= now.addingTimeInterval(eventWindow) && $0.end >= now.addingTimeInterval(-eventWindow)
        }
        let ordered = near.sorted { a, b in
            let ra = a.start <= now && a.end > now, rb = b.start <= now && b.end > now
            if ra != rb { return ra }
            let da = abs(a.start.timeIntervalSince(now)), db = abs(b.start.timeIntervalSince(now))
            return da != db ? da < db : a.id < b.id
        }
        for e in ordered {
            if let name = remembered[e.id], sessions.contains(name) { return .prepared(name) }
        }
        return .adhoc
    }

    // MARK: plan

    /// What one Start will run.
    public struct Plan: Sendable, Equatable {
        public var route: AudioRoute
        public var mode: SessionMode
        /// The session folder name under `SessionCatalog.root`.
        public var session: String
        public var lang: String
    }

    /// Decides route and session and, for an unprepared call, creates its folder. Nothing is prepared and nothing waits.
    public static func plan(now: Date, facts: RouteFacts, events: [MeetingEvent], remembered: [String: String],
                            sessions: [String], lang: String, root: URL = SessionCatalog.root,
                            timeZone: TimeZone = .current, routeOverride: AudioRoute? = nil) throws -> Plan {
        // A route picked by hand (the menu's Route submenu) beats the automatic pick.
        let route = runnableRoute(routeOverride ?? pickRoute(facts))
        switch pickSession(now: now, events: events, remembered: remembered, sessions: sessions) {
        case .prepared(let name):
            return Plan(route: route, mode: .prepared, session: name, lang: lang)
        case .adhoc:
            let name = try SessionCatalog.createAdhoc(now: now, route: route, lang: lang, root: root, timeZone: timeZone)
            return Plan(route: route, mode: .unprepared, session: name, lang: lang)
        }
    }
}

// MARK: adhoc sessions

/// `meta.json` of an unprepared session folder.
public struct AdhocMeta: Codable, Sendable, Equatable {
    public var kind = "adhoc"
    public var mode = "unprepared"
    public var route: String
    public var lang: String

    public init(route: AudioRoute, lang: String) {
        self.route = route.rawValue
        self.lang = lang
    }

    /// The meta of an adhoc session folder, or nil for any other folder.
    public static func read(sessionDir: URL) -> AdhocMeta? {
        guard let d = try? Data(contentsOf: sessionDir.appendingPathComponent("meta.json")),
              let m = try? JSONDecoder().decode(AdhocMeta.self, from: d), m.kind == "adhoc" else { return nil }
        return m
    }
}

public extension SessionCatalog {
    /// `adhoc-20261016-1432-room`.
    static func adhocName(now: Date, route: AudioRoute, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmm"
        return "adhoc-\(f.string(from: now))-\(route.rawValue)"
    }

    static func isAdhoc(_ name: String) -> Bool { name.hasPrefix("adhoc-") }

    /// Creates `sessions/adhoc-YYYYMMDD-HHMM-<route>/` with `meta.json` and an empty `pack.md` (the brain and the runner
    /// need a pack file; an unprepared call has no content for it). A second call in the same minute gets `-2`, `-3`.
    /// Returns the folder name.
    @discardableResult
    static func createAdhoc(now: Date, route: AudioRoute, lang: String, root: URL = SessionCatalog.root,
                            timeZone: TimeZone = .current) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let base = adhocName(now: now, route: route, timeZone: timeZone)
        var name = base, n = 1
        while fm.fileExists(atPath: root.appendingPathComponent(name).path) {
            n += 1
            name = "\(base)-\(n)"
        }
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        try enc.encode(AdhocMeta(route: route, lang: lang)).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        try Data().write(to: dir.appendingPathComponent("pack.md"), options: .atomic)
        return name
    }
}

// MARK: stopping with ⌥⌘V

/// ⌥⌘V while a session runs: the first press arms the stop (the island says "Press ⌥⌘V again to stop"), a second press
/// inside the window stops it. One stray press never ends a call. Time comes in with each press, so tests drive it.
public struct StopConfirm: Sendable, Equatable {
    public static let window: TimeInterval = 2

    public enum Action: Sendable, Equatable {
        /// Nothing runs: start a session.
        case start
        /// First press: show the confirmation for `window` seconds.
        case arm
        /// Second press inside the window: stop.
        case stop
    }

    private var armedAt: Date?

    public init() {}

    public mutating func press(running: Bool, now: Date) -> Action {
        guard running else {
            armedAt = nil
            return .start
        }
        if let t = armedAt, now.timeIntervalSince(t) <= Self.window {
            armedAt = nil
            return .stop
        }
        armedAt = now
        return .arm
    }

    /// Is the confirmation showing at `now`?
    public func isArmed(now: Date) -> Bool {
        armedAt.map { now.timeIntervalSince($0) <= Self.window } ?? false
    }

    /// The session ended or the user moved on.
    public mutating func reset() { armedAt = nil }
}
