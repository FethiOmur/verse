import Darwin
import Foundation

/// Which side of the conversation a stream or transcript belongs to.
public enum Channel: String, Sendable, Codable, CaseIterable {
    /// The meeting app's audio (the other participants).
    case remote
    /// the owner's microphone.
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

    public var description: String {
        switch self {
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
        }
    }
}
