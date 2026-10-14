import Foundation

/// A meeting app Verse watches. `bundleIDs` also match sub-bundles (`com.brave.Browser.helper.renderer`).
public struct MeetingApp: Sendable, Equatable {
    public var name: String
    public var bundleIDs: [String]

    public init(name: String, bundleIDs: [String]) {
        self.name = name
        self.bundleIDs = bundleIDs
    }

    public static let known: [MeetingApp] = [
        MeetingApp(name: "Brave", bundleIDs: ["com.brave.Browser"]),
        MeetingApp(name: "Comet", bundleIDs: ["ai.perplexity.comet"]),
        MeetingApp(name: "Chrome", bundleIDs: ["com.google.Chrome"]),
        // Safari's page processes are WebKit helpers; unverified on a live Safari call.
        MeetingApp(name: "Safari", bundleIDs: ["com.apple.Safari", "com.apple.WebKit.GPU", "com.apple.WebKit.WebContent"]),
        MeetingApp(name: "Arc", bundleIDs: ["company.thebrowser.Browser"]),
        MeetingApp(name: "Zoom", bundleIDs: ["us.zoom.xos"]),
        MeetingApp(name: "Teams", bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"]),
    ]

    public func matches(_ bundleID: String?) -> Bool {
        guard let b = bundleID, !b.isEmpty else { return false }
        return bundleIDs.contains { b == $0 || b.hasPrefix($0 + ".") }
    }
}

public struct MeetingInfo: Sendable, Equatable {
    public var bundleID: String
    public var appName: String
    /// When the microphone input of the app started (not when the detector noticed).
    public var since: Date
    public var event: MeetingEvent?

    public init(bundleID: String, appName: String, since: Date, event: MeetingEvent? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.since = since
        self.event = event
    }
}

public enum MeetingSignal: Sendable, Equatable {
    case started(MeetingInfo)
    case ended(MeetingInfo)
}

public struct MeetingDetectorConfig: Sendable {
    /// Microphone input must run this long before a call counts.
    public var minInput: TimeInterval = 3
    /// No input for this long ends the call.
    public var endAfter: TimeInterval = 10
    /// An event within this distance of now (before its start or after its end) is attached.
    public var eventMargin: TimeInterval = 10 * 60
    /// Polling period; never faster than 1 s.
    public var pollInterval: TimeInterval = 1
    public var apps: [MeetingApp] = MeetingApp.known

    public init() {}
}

/// Tells when a call starts and ends from one fact only: a known meeting app has microphone input running
/// (`kAudioProcessPropertyIsRunningInput`). A browser that only plays audio never counts. No audio is read.
public actor MeetingDetector {
    private struct AppState {
        var inputSince: Date?
        var lastInput: Date?
        var active: MeetingInfo?
    }

    private let table: any AudioProcessTable
    private let config: MeetingDetectorConfig
    private let eventLookup: @Sendable (Date) async -> [MeetingEvent]
    private var states: [String: AppState] = [:]
    private var pollTask: Task<Void, Never>?

    /// - Parameter eventLookup: events near a time, called once per detected call start.
    public init(table: any AudioProcessTable = CoreAudioProcessTable(),
                config: MeetingDetectorConfig = MeetingDetectorConfig(),
                eventLookup: @escaping @Sendable (Date) async -> [MeetingEvent] = { _ in [] }) {
        self.table = table
        self.config = config
        self.eventLookup = eventLookup
    }

    /// Calls in progress right now.
    public var activeMeetings: [MeetingInfo] { states.values.compactMap(\.active).sorted { $0.since < $1.since } }

    /// One polling step at time `now`; returns the signals it produced. `signals()` calls this once per period.
    public func tick(at now: Date) async -> [MeetingSignal] {
        let processes = table.snapshot()
        var out: [MeetingSignal] = []
        for app in config.apps {
            let input = processes.first { $0.isRunningInput && app.matches($0.bundleID) }
            var s = states[app.name] ?? AppState()
            if let input {
                if s.inputSince == nil { s.inputSince = now }
                s.lastInput = now
                if s.active == nil, let since = s.inputSince, now.timeIntervalSince(since) >= config.minInput {
                    let event = await attach(at: now)
                    let info = MeetingInfo(bundleID: Self.root(of: input.bundleID, app: app), appName: app.name,
                                           since: since, event: event)
                    s.active = info
                    out.append(.started(info))
                }
            } else if let active = s.active {
                if let last = s.lastInput, now.timeIntervalSince(last) >= config.endAfter {
                    out.append(.ended(active))
                    s = AppState()
                }
            } else {
                s = AppState()  // input stopped before the debounce passed
            }
            states[app.name] = s
        }
        return out
    }

    /// Signals as a stream, polled at `config.pollInterval` (at least 1 s). Stops when the consumer stops listening.
    public func signals() -> AsyncStream<MeetingSignal> {
        pollTask?.cancel()
        let period = max(1, config.pollInterval)
        return AsyncStream { continuation in
            let task = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { break }
                    for sig in await self.tick(at: Date()) { continuation.yield(sig) }
                    try? await Task.sleep(for: .seconds(period))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
            self.pollTask = task
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// The event that overlaps `now` (±margin); the one running now wins, else the one starting nearest.
    private func attach(at now: Date) async -> MeetingEvent? {
        let margin = config.eventMargin
        let near = await eventLookup(now).filter {
            $0.start <= now.addingTimeInterval(margin) && $0.end >= now.addingTimeInterval(-margin)
        }
        return near.min { a, b in
            let ra = a.start <= now && a.end > now, rb = b.start <= now && b.end > now
            if ra != rb { return ra }
            return abs(a.start.timeIntervalSince(now)) < abs(b.start.timeIntervalSince(now))
        }
    }

    private static func root(of bundleID: String?, app: MeetingApp) -> String {
        guard let b = bundleID else { return app.bundleIDs[0] }
        return app.bundleIDs.first { b == $0 || b.hasPrefix($0 + ".") } ?? b
    }
}
