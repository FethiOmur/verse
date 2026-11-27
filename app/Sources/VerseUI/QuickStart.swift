import Foundation
import VerseAudio
import VerseMeet
import VerseTurns

/// Start anytime (anytime-calls spec 2.1): what ⌥⌘V, the menu's Start row and the island's idle state decide. Pure
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

    /// A call started on the room route because no meeting app held the microphone when Start was pressed, and a meeting app
    /// takes it afterwards (joined a few seconds late): the call moves to the meeting route in place (`switchListening`), so the
    /// other side is captured and the turns are `me` / `remote` again. One value per run, kept by the controller.
    ///
    /// Moves only a room route that the automatic pick chose: a route picked by hand (the Audio source override before Start, or
    /// a route change during the call) is never changed, a call already on the meeting route is left alone, and a rehearsal
    /// (typed lines, no audio) is not a call. At most one move per run, so a detection that fires again (a mic pause, a second
    /// meeting app) never loops; a detection while another route or language change is under way is skipped without using it up.
    public struct MeetingRouteUpgrade: Sendable, Equatable {
        /// The run's route came from the automatic pick, and nothing was picked by hand since.
        public private(set) var autoPicked: Bool
        public let rehearsal: Bool
        /// The one move of this run was asked for.
        public private(set) var attempted = false

        public init(autoPicked: Bool, rehearsal: Bool) {
            self.autoPicked = autoPicked
            self.rehearsal = rehearsal
        }

        /// He changed the route during the call himself: from then on it is his.
        public mutating func routeChosenByHand() { autoPicked = false }

        /// A meeting app was detected while the call runs on `route`. True: switch the call to the meeting route now (and this
        /// run's one move is used). `switching`: a route or language change is already under way.
        public mutating func meetingDetected(route: AudioRoute, switching: Bool = false) -> Bool {
            guard autoPicked, !rehearsal, !attempted, route == .room, !switching else { return false }
            attempted = true
            return true
        }
    }

    /// True when a process that is a known meeting app has microphone input running. Reads Core Audio flags only.
    public static func meetingAppHoldsMic(_ processes: [AudioProcessInfo], apps: [MeetingApp] = MeetingApp.known) -> Bool {
        processes.contains { p in p.isRunningInput && apps.contains { $0.matches(p) } }
    }

    // MARK: session

    public enum SessionChoice: Sendable, Equatable {
        /// A prepared session: the one of a calendar event around now, or the session he picked by hand.
        case prepared(String)
        /// Nothing prepared for now: an unprepared (adhoc) session is created.
        case adhoc
    }

    /// A meeting's prepared session is used from this long before the meeting starts (owner decision 2, 24 Nov 2026; was 15 min) ...
    public static let leadTime: TimeInterval = 60 * 60
    /// ... until this long after it ended.
    public static let afterEnd: TimeInterval = 15 * 60
    /// How far around now the calendar is read for a Start.
    public static var eventMargin: TimeInterval { max(leadTime, afterEnd) }

    /// Which session Start runs (G4), first that holds:
    /// 1. an event that starts within `leadTime` (60 min) or is running, or ended less than `afterEnd` (15 min) ago, has a session
    ///    (`MeetingSessionResolver.match`); events ranked by `MeetingRanking` (the running one, else the nearest start; the next one
    ///    at a back-to-back handover), the first with a session decides;
    /// 2. `manualSession`: the session he picked by hand while that pick still holds;
    /// 3. adhoc. An automatic selection for a meeting hours away never takes an impromptu call.
    ///
    /// The menu's Start row is labelled from this same function with the same inputs (`VerseController.startChoice`), so the
    /// label says exactly what ⌥⌘V will do.
    public static func pickSession(now: Date, events: [MeetingEvent], matcher: SessionMatcher, manualSession: String? = nil) -> SessionChoice {
        let near = events.filter {
            $0.start <= now.addingTimeInterval(leadTime) && $0.end >= now.addingTimeInterval(-afterEnd)
        }
        for e in MeetingRanking.ordered(near, now: now) {
            if let m = matcher.match(e) { return .prepared(m.session) }
        }
        if let manualSession, matcher.sessions.contains(manualSession) { return .prepared(manualSession) }
        return .adhoc
    }

    /// The same with only the links of `event-sessions.json` (no folder `event.json` files, no manual pick).
    public static func pickSession(now: Date, events: [MeetingEvent], remembered: [String: String], sessions: [String]) -> SessionChoice {
        pickSession(now: now, events: events, matcher: SessionMatcher(sessions: sessions, links: remembered))
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
                            timeZone: TimeZone = .current, routeOverride: AudioRoute? = nil,
                            useGeneralPrep: Bool = false) throws -> Plan {
        try plan(now: now, facts: facts, events: events, matcher: SessionMatcher(sessions: sessions, links: remembered), lang: lang,
                 root: root, timeZone: timeZone, routeOverride: routeOverride, useGeneralPrep: useGeneralPrep)
    }

    public static func plan(now: Date, facts: RouteFacts, events: [MeetingEvent], matcher: SessionMatcher, manualSession: String? = nil,
                            lang: String, root: URL = SessionCatalog.root, timeZone: TimeZone = .current,
                            routeOverride: AudioRoute? = nil, useGeneralPrep: Bool = false) throws -> Plan {
        try plan(choice: pickSession(now: now, events: events, matcher: matcher, manualSession: manualSession), now: now, facts: facts,
                 lang: lang, root: root, timeZone: timeZone, routeOverride: routeOverride, useGeneralPrep: useGeneralPrep)
    }

    /// The plan for a session choice made already (`pickSession`, or `.adhoc` for Start unprepared): the route, and for an
    /// unprepared call its new folder.
    public static func plan(choice: SessionChoice, now: Date, facts: RouteFacts, lang: String, root: URL = SessionCatalog.root,
                            timeZone: TimeZone = .current, routeOverride: AudioRoute? = nil, useGeneralPrep: Bool = false) throws -> Plan {
        // A route picked by hand (the menu's Audio source submenu) beats the automatic pick.
        let route = runnableRoute(routeOverride ?? pickRoute(facts))
        switch choice {
        case .prepared(let name):
            return Plan(route: route, mode: .prepared, session: name, lang: lang)
        case .adhoc:
            let name = try SessionCatalog.createAdhoc(now: now, route: route, lang: lang, root: root, timeZone: timeZone,
                                                       useGeneralPrep: useGeneralPrep)
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
    /// The standing prep this folder was seeded from (`persona-core` or `general-core`), or nil for an empty pack.
    public var base: String?

    public init(route: AudioRoute, lang: String, base: String? = nil) {
        self.route = route.rawValue
        self.lang = lang
        self.base = base
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

    /// Creates `sessions/adhoc-YYYYMMDD-HHMM-<route>/` with `meta.json` and an empty `pack.md`, or, when `useGeneralPrep`, the
    /// files of the standing prep (`GeneralPrep.source`: the compiled persona when `personaOn` and compiled, else the general
    /// prep). The brain and the runner need a pack file; an unprepared call has no content for it. A second call in the same
    /// minute gets `-2`, `-3`. Returns the folder name.
    @discardableResult
    static func createAdhoc(now: Date, route: AudioRoute, lang: String, root: URL = SessionCatalog.root,
                            timeZone: TimeZone = .current, useGeneralPrep: Bool = false,
                            personaOn: Bool = OwnerProfile.current.personaURL != nil) throws -> String {
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
        // The standing prep, when wanted and built: its files are copied in and the meta records which folder was the base.
        let source = useGeneralPrep ? GeneralPrep.seed(into: dir, root: root, personaOn: personaOn) : .none
        try enc.encode(AdhocMeta(route: route, lang: lang, base: source.folder))
            .write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        if source == .none { try Data().write(to: dir.appendingPathComponent("pack.md"), options: .atomic) }
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
