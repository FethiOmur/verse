import Foundation

/// A process tap that keeps calling back with exact digital zero while the meeting app sends audio to an output: the tap may be
/// broken (it lost the app's processes, the route stopped following a helper) or the other side may simply be silent (everyone
/// muted, which WebRTC renders as exact zeros too). Core Audio has no per-process level, so the two cannot be told apart from
/// here; `kAudioProcessPropertyIsRunningOutput` only says the app's output IO is running, which a browser in a call keeps on
/// during silence.
///
/// So this never diagnoses. It decides when a cheap, quiet probe is worth it: rebuilding a tap that delivers only zeros loses
/// nothing (the few-ms gap falls in digital silence). The probe is reported to the user only when it visibly helped (audio came
/// back within `confirmWindow` of it); otherwise nothing is said and `DeadStreamDetector`'s `dead_stream` issue stands.
///
/// Evidence for a probe, all of it at once:
/// - the tap is calling back (a tap that stopped calling back is the stall watchdog's case),
/// - every buffer since `zeroSince` was exact zero,
/// - the meeting app reported running output at every check since the zero run began (unknown counts as no),
/// - that combination lasted `firstProbeAfter`.
/// At most `probeBackoff.count + 1` probes per zero run, spaced by `probeBackoff`; a non-zero buffer ends the run and the budget.
/// Pure state machine: the caller supplies the time and the probes.
public struct SilentTapWatch: Sendable, Equatable {
    public var firstProbeAfter: TimeInterval = 10
    /// Delay before probe n+1, measured from probe n. Its count + 1 is the probe budget per zero run.
    public var probeBackoff: [TimeInterval] = [30]
    /// Audio within this long after a probe counts as the probe having repaired the tap.
    public var confirmWindow: TimeInterval = 5
    /// No buffer for this long means the tap is not calling back (not this watch's case).
    public var callbackGrace: TimeInterval = 2

    public private(set) var zeroSince: TimeInterval?
    public private(set) var producingSince: TimeInterval?
    public private(set) var probes = 0
    public private(set) var lastProbeAt: TimeInterval?
    private var confirmed = false

    public init() {}

    public enum Action: Sendable, Equatable {
        case none
        /// Rebuild the tap quietly. `silentFor`: seconds of exact zero so far.
        case probe(attempt: Int, silentFor: TimeInterval)
        /// Audio came back right after a probe: the rebuild repaired the tap (say so once).
        case recovered
    }

    /// Every IOProc buffer: whether it was exact zero, at host seconds `t`.
    public mutating func buffer(zero: Bool, at t: TimeInterval) {
        if zero {
            if zeroSince == nil { zeroSince = t }
            return
        }
        if let p = lastProbeAt, t - p <= confirmWindow { confirmed = true }
        zeroSince = nil
        producingSince = nil
        probes = 0
        lastProbeAt = nil
    }

    /// Periodic check (about once a second). `lastCallback`: host seconds of the newest buffer. `producing` is asked only during
    /// a zero run of a tap that calls back.
    public mutating func check(now: TimeInterval, lastCallback: TimeInterval?, producing: () -> Bool?) -> Action {
        if confirmed {
            confirmed = false
            return .recovered
        }
        guard let z = zeroSince, let last = lastCallback, now - last < callbackGrace else {
            producingSince = nil
            return .none
        }
        guard producing() == true else {
            producingSince = nil
            return .none
        }
        let since = producingSince ?? now
        producingSince = since
        let due: TimeInterval
        if probes == 0 {
            due = max(z, since) + firstProbeAfter
        } else if probes <= probeBackoff.count, let p = lastProbeAt {
            due = p + probeBackoff[probes - 1]
        } else {
            return .none
        }
        guard now >= due else { return .none }
        probes += 1
        lastProbeAt = now
        return .probe(attempt: probes, silentFor: now - z)
    }
}
