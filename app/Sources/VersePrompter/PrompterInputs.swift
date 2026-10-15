import Foundation
import Synchronization
import VerseSpeech

// Inputs of the prompter, as small protocols so tests need no audio: a clock, a transcript stream, a level stream.
// Adapters at the bottom connect them to `ListenSession`.

/// Seconds on any monotonic timeline. Drivers never read the wall clock themselves.
public protocol PrompterClock: Sendable {
    func now() -> TimeInterval
    func sleep(until deadline: TimeInterval) async throws
}

public struct SystemPrompterClock: PrompterClock {
    private let origin = ContinuousClock.now
    public init() {}
    public func now() -> TimeInterval {
        let d = ContinuousClock.now - origin
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
    public func sleep(until deadline: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(max(0, deadline - now())))
    }
}

/// Partial and final transcripts. `WordTrackingDriver` uses only `Channel.me` events from it.
public protocol TranscriptSource: Sendable {
    /// Starts capture if needed and returns a stream of events. May throw (no mic permission, STT failed to start).
    func events() async throws -> AsyncStream<TranscriptEvent>
    func stop() async
}

/// Linear RMS (0...1) of the microphone, many times per second.
public protocol LevelSource: Sendable {
    func samples() async throws -> AsyncStream<Double>
    func stop() async
}

/// Fan-out of one event stream to any number of late subscribers (a live mode switch subscribes again).
public final class TranscriptBroadcaster: Sendable {
    private struct Subscribers {
        var next = 0
        var continuations: [Int: AsyncStream<TranscriptEvent>.Continuation] = [:]
    }
    private let state = Mutex(Subscribers())

    public init() {}

    public func subscribe() -> AsyncStream<TranscriptEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: TranscriptEvent.self, bufferingPolicy: .unbounded)
        let id = state.withLock { s -> Int in
            s.next += 1
            s.continuations[s.next] = continuation
            return s.next
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    public func yield(_ event: TranscriptEvent) {
        let targets = state.withLock { Array($0.continuations.values) }
        for c in targets { c.yield(event) }
    }

    public func finish() {
        let targets = state.withLock { s -> [AsyncStream<TranscriptEvent>.Continuation] in
            let all = Array(s.continuations.values)
            s.continuations.removeAll()
            return all
        }
        for c in targets { c.finish() }
    }
}

/// For the meeting: the app already runs a `ListenSession`; this wraps its event stream. `stop()` ends only
/// the forwarding, never the session.
public final class ExternalTranscriptSource: TranscriptSource {
    private let stream: AsyncStream<TranscriptEvent>
    private let broadcaster = TranscriptBroadcaster()
    private let pump = Mutex<Task<Void, Never>?>(nil)

    public init(stream: AsyncStream<TranscriptEvent>) { self.stream = stream }

    public func events() async throws -> AsyncStream<TranscriptEvent> {
        let subscription = broadcaster.subscribe()
        pump.withLock { task in
            guard task == nil else { return }
            let stream = self.stream, broadcaster = self.broadcaster
            task = Task {
                for await event in stream { broadcaster.yield(event) }
                broadcaster.finish()
            }
        }
        return subscription
    }

    public func stop() async {
        pump.withLock { $0?.cancel(); $0 = nil }
        broadcaster.finish()
    }
}

/// Polls `ListenSession.levels` (mic channel, dBFS) and publishes linear RMS. Never starts or stops the session.
public final class ListenSessionLevelSource: LevelSource {
    private let session: ListenSession
    private let interval: Duration
    private let window: TimeInterval
    private let task = Mutex<Task<Void, Never>?>(nil)

    public init(session: ListenSession, pollInterval: Duration = .milliseconds(50), window: TimeInterval = 0.1) {
        self.session = session
        interval = pollInterval
        self.window = window
    }

    /// dBFS (as `ListenSession.Level.rmsDbfs`) to linear RMS; nil means no signal.
    public static func linear(fromDbfs db: Double?) -> Double {
        guard let db else { return 0 }
        return min(1, pow(10, db / 20))
    }

    public func samples() async throws -> AsyncStream<Double> {
        let (stream, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(8))
        let session = self.session, interval = self.interval, window = self.window
        let polling = Task {
            while !Task.isCancelled {
                let levels = await session.levels(window: window)
                continuation.yield(Self.linear(fromDbfs: levels[.me]?.rmsDbfs))
                try? await Task.sleep(for: interval)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in polling.cancel() }
        task.withLock { $0?.cancel(); $0 = polling }
        return stream
    }

    public func stop() async { task.withLock { $0?.cancel(); $0 = nil } }
}

/// Standalone use (recording, talk): owns a `ListenSession`, starts it on first use and serves both the
/// transcript and the levels from it. The session stops in `stop()`.
public final class ListenSessionInputs: TranscriptSource, LevelSource {
    private let session: ListenSession
    private let broadcaster = TranscriptBroadcaster()
    private let started = Mutex<Task<Void, any Error>?>(nil)
    private let levelSource: ListenSessionLevelSource

    public init(session: ListenSession) {
        self.session = session
        levelSource = ListenSessionLevelSource(session: session)
    }

    /// A session with the microphone only (no process tap), the default engine for `lang`.
    public static func micOnly(lang: String = "en") -> ListenSessionInputs {
        var environment = ListenEnvironment.system
        environment.makeRemoteSource = { _ in nil }
        let session = ListenSession(config: ListenConfig(lang: lang, remoteBundleIDs: [], micEnabled: true), environment: environment)
        return ListenSessionInputs(session: session)
    }

    private func ensureStarted() async throws {
        let task = started.withLock { existing -> Task<Void, any Error> in
            if let existing { return existing }
            let session = self.session, broadcaster = self.broadcaster
            let created = Task<Void, any Error> {
                let stream = try await session.start()
                Task {
                    for await event in stream { broadcaster.yield(event) }
                    broadcaster.finish()
                }
            }
            existing = created
            return created
        }
        try await task.value
    }

    public func events() async throws -> AsyncStream<TranscriptEvent> {
        try await ensureStarted()
        return broadcaster.subscribe()
    }

    public func samples() async throws -> AsyncStream<Double> {
        try await ensureStarted()
        return try await levelSource.samples()
    }

    public func stop() async {
        await levelSource.stop()
        let wasStarted = started.withLock { s -> Bool in defer { s = nil }; return s != nil }
        if wasStarted { await session.stop() }
        broadcaster.finish()
    }
}
