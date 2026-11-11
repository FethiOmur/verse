import Darwin
import Foundation

/// Which side of the conversation a stream or transcript belongs to.
public enum Channel: String, Sendable, Codable, CaseIterable {
    /// The meeting app's audio (the other participants).
    case remote
    /// The owner's microphone.
    case me
}

/// One block of mono Float32 samples. `startTime` is the session time (seconds since the session started) of the
/// first sample. Chunks only ever live in memory; nothing in VerseAudio writes samples to disk.
public struct AudioChunk: Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    public var startTime: TimeInterval

    public init(samples: [Float], sampleRate: Double, startTime: TimeInterval) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.startTime = startTime
    }

    public var duration: TimeInterval { Double(samples.count) / sampleRate }
    public var endTime: TimeInterval { startTime + duration }
    /// True when every sample is exactly 0.0 (what a tap delivers for silence or a missing permission).
    public var isExactZero: Bool { samples.allSatisfy { $0 == 0 } }
}

/// Session time base: seconds since `start`, derived from the host clock so tap, mic and recognizer agree.
public struct SessionClock: Sendable {
    public let originHostSeconds: Double

    public init() { originHostSeconds = HostTime.nowSeconds() }
    public init(originHostSeconds: Double) { self.originHostSeconds = originHostSeconds }

    /// Seconds since the session started.
    public func now() -> TimeInterval { HostTime.nowSeconds() - originHostSeconds }
    /// Converts a mach host time (e.g. `AudioTimeStamp.mHostTime`) to session seconds.
    public func sessionTime(hostTime: UInt64) -> TimeInterval { HostTime.seconds(hostTime) - originHostSeconds }
}

public enum HostTime {
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    @inline(__always) public static func seconds(_ t: UInt64) -> Double {
        Double(t) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    @inline(__always) public static func nowSeconds() -> Double { seconds(mach_absolute_time()) }
}

public enum PermissionKind: String, Sendable, Codable {
    /// "Screen & System Audio Recording" (process taps), TCC service kTCCServiceAudioCapture.
    case audioCapture
    case microphone
}

public enum ListenError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The user (or policy) denied the permission. Distinct from silence.
    case permissionDenied(PermissionKind)
    /// Exact-zero audio (or no callbacks) for >= 1 s on a running stream while the target app is producing output.
    case deadStream(Channel)
    case tapFailed(String)
    case micFailed(String)
    case speechUnavailable(lang: String, reason: String)
    case sourceFailed(String)
    case alreadyStarted
    /// Runtime (review H5): a live source rebuilt itself after an audio device or format change and delivers audio again.
    case captureRecovered(Channel, String)
    /// Runtime (review H5): a live source stopped (device change) and could not rebuild itself; the channel is silent.
    case captureFailed(Channel, String)
    /// Runtime (review H8): a channel's recognizer failed mid-call and a fresh engine took over from that point.
    case speechRecovered(Channel, String)
    /// Runtime (review H8): a channel's recognizer failed mid-call and could not be replaced; the channel gets no text.
    case speechFailed(Channel, String)

    private static func side(_ c: Channel) -> String { c == .me ? "your microphone channel" : "the meeting audio channel" }

    /// The channel a runtime capture/speech issue is about (nil for issues that are not about one channel).
    public var channel: Channel? {
        switch self {
        case .captureRecovered(let c, _), .captureFailed(let c, _), .speechRecovered(let c, _), .speechFailed(let c, _): return c
        case .deadStream(let c): return c
        default: return nil
        }
    }

    /// The channel named in an issue's `description` (VerseRunner forwards an issue as code + message only). The first
    /// channel named wins, so a reason text quoted later in the message cannot flip it. Nil when the text names none.
    public static func channel(inIssueMessage message: String) -> Channel? {
        let hits = Channel.allCases.compactMap { c in message.range(of: side(c)).map { (c, $0.lowerBound) } }
        return hits.min { $0.1 < $1.1 }?.0
    }

    public var description: String {
        switch self {
        case .captureRecovered(let c, let m): return "audio capture on \(Self.side(c)) restarted after a device change (\(m))"
        case .captureFailed(let c, let m): return "audio capture on \(Self.side(c)) stopped and could not be restarted: \(m)"
        case .speechRecovered(let c, let m): return "speech recognition on \(Self.side(c)) failed and was restarted: \(m)"
        case .speechFailed(let c, let m): return "speech recognition on \(Self.side(c)) failed and could not be restarted: \(m)"
        case .permissionDenied(let k): return "permission denied: \(k.rawValue)"
        case .deadStream(let c): return "dead stream on \(c.rawValue): exact-zero audio while the app is playing"
        case .tapFailed(let m): return "process tap failed: \(m)"
        case .micFailed(let m): return "microphone failed: \(m)"
        case .speechUnavailable(let l, let r): return "speech recognition unavailable for \(l): \(r)"
        case .sourceFailed(let m): return "audio source failed: \(m)"
        case .alreadyStarted: return "session already started"
        }
    }

    /// Short machine-readable code for logs and JSON.
    public var code: String {
        switch self {
        case .permissionDenied: return "permission_denied"
        case .deadStream: return "dead_stream"
        case .tapFailed: return "tap_failed"
        case .micFailed: return "mic_failed"
        case .speechUnavailable: return "speech_unavailable"
        case .sourceFailed: return "source_failed"
        case .alreadyStarted: return "already_started"
        case .captureRecovered: return "capture_recovered"
        case .captureFailed: return "capture_failed"
        case .speechRecovered: return "speech_recovered"
        case .speechFailed: return "speech_failed"
        }
    }
}
