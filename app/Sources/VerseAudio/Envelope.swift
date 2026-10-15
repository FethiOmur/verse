import Foundation
import os

/// 10 ms RMS envelope on the session clock. Holds loudness numbers only (one Double per 10 ms), never samples.
/// Keeps the most recent `retainSeconds`.
public final class EnvelopeTrack: @unchecked Sendable {
    public static let binSeconds = 0.01
    public let retainSeconds: TimeInterval
    private let lock = OSAllocatedUnfairLock()
    private var baseBin = 0                 // absolute bin index of sumsq[0]
    private var sumsq: [Double] = []
    private var count: [Int] = []

    public init(retainSeconds: TimeInterval = 120) { self.retainSeconds = retainSeconds }

    public func add(_ chunk: AudioChunk) {
        guard !chunk.samples.isEmpty else { return }
        let sr = chunk.sampleRate
        lock.lock(); defer { lock.unlock() }
        var f = 0
        let n = chunk.samples.count
        while f < n {
            let t = chunk.startTime + Double(f) / sr
            let bin = Int((t / EnvelopeTrack.binSeconds).rounded(.down))
            // Frames until the next bin boundary.
            let nextBoundary = Double(bin + 1) * EnvelopeTrack.binSeconds
            let framesInBin = max(1, min(n - f, Int(((nextBoundary - t) * sr).rounded(.up))))
            var s = 0.0
            for k in f..<(f + framesInBin) { let v = Double(chunk.samples[k]); s += v * v }
            accumulate(bin: bin, sumsq: s, count: framesInBin)
            f += framesInBin
        }
        prune()
    }

    private func accumulate(bin: Int, sumsq s: Double, count c: Int) {
        if sumsq.isEmpty { baseBin = bin }
        if bin < baseBin { return }
        let idx = bin - baseBin
        if idx >= sumsq.count {
            let grow = idx - sumsq.count + 1
            sumsq.append(contentsOf: repeatElement(0, count: grow))
            count.append(contentsOf: repeatElement(0, count: grow))
        }
        sumsq[idx] += s
        count[idx] += c
    }

    private func prune() {
        let keep = Int(retainSeconds / EnvelopeTrack.binSeconds)
        let excess = sumsq.count - keep
        if excess > keep / 4 {   // drop in batches
            sumsq.removeFirst(excess)
            count.removeFirst(excess)
            baseBin += excess
        }
    }

    /// Linear RMS per 10 ms bin for absolute bins [from, to). Bins without data are 0.
    public func rms(fromBin: Int, toBin: Int) -> [Double] {
        lock.lock(); defer { lock.unlock() }
        guard toBin > fromBin else { return [] }
        return (fromBin..<toBin).map { b in
            let i = b - baseBin
            guard i >= 0, i < sumsq.count, count[i] > 0 else { return 0 }
            return (sumsq[i] / Double(count[i])).squareRoot()
        }
    }

    public static func bin(_ t: TimeInterval) -> Int { Int((t / binSeconds).rounded(.down)) }
}

/// What the echo gate measures for one mic range (loudness numbers only).
public struct GateFeatures: Sendable, Equatable {
    /// Highest Pearson correlation of the 10 ms envelopes over lag 0...maxLag.
    public var score: Double
    public var lagMs: Double
    public var window: GateLevels
}

/// Level comparison of mic and remote over one (lag-aligned) window.
public struct GateLevels: Sendable, Equatable {
    /// Mic RMS (dBFS) over the bins where the remote channel is active; nil when no bin qualifies.
    public var meDb: Double?
    /// Remote RMS (dBFS) over the same bins.
    public var remoteDb: Double?
    /// `meDb - remoteDb`: about -25 for a -25 dB echo, around 0 or above for a voice at the mic that is as loud as the remote.
    public var ratioDb: Double?
    /// Share of the mic's active bins (>= 10 % of its peak) with no remote activity under them. An echo has none.
    public var micOnlyShare: Double
    /// Share of the window's bins in which the remote channel is active.
    public var remoteActiveShare: Double
}

/// Echo gate for the mic channel (spec §5.7): mic speech is discarded when its 10 ms envelope correlates
/// >= `threshold` with the remote envelope delayed by 0...`maxLag` (the remote sound reaching the mic later).
public struct BleedGate: Sendable {
    public var threshold: Double = 0.6
    public var maxLag: TimeInterval = 0.08
    /// Ranges shorter than this are widened symmetrically so the correlation has enough bins.
    public var minWindow: TimeInterval = 0.3
    /// Remote RMS below this everywhere in the window means there is nothing to echo.
    public var remoteFloor: Double = 1e-4
    /// A correlated mic range is an echo when its level next to the remote is at most this (dB). A speaker echo in a room is
    /// 20 dB or more below the remote (measured cells: -30, -25, -15); the owner's own voice at the mic was within 8 dB of it.
    public var maxEchoRatioDb: Double = -15
    /// Correlation this tight is not a different speaker (the real double-talk events topped out at 0.73)...
    public var strongScore: Double = 0.9
    /// ...so with it a louder echo is still dropped, up to this level (dB).
    public var maxStrongEchoRatioDb: Double = -6

    public init() {}

    /// Highest Pearson correlation between mic[t] and remote[t - lag] over the window, for lag in 0...maxLag.
    /// `nil` when either side has no usable signal (then it cannot be echo).
    public func echoScore(mic: EnvelopeTrack, remote: EnvelopeTrack, start: TimeInterval, end: TimeInterval) -> Double? {
        features(mic: mic, remote: remote, start: start, end: end)?.score
    }

    /// Everything the gate can see about a mic range: the best envelope correlation and, at that lag, how loud the mic is
    /// compared with the remote channel and how much of the mic's activity has no remote activity under it.
    public func features(mic: EnvelopeTrack, remote: EnvelopeTrack, start: TimeInterval, end: TimeInterval) -> GateFeatures? {
        var s = start, e = end
        if e - s < minWindow { let mid = (s + e) / 2; s = mid - minWindow / 2; e = mid + minWindow / 2 }
        let b0 = EnvelopeTrack.bin(s), b1 = EnvelopeTrack.bin(e) + 1
        let maxLagBins = Int((maxLag / EnvelopeTrack.binSeconds).rounded())
        let m = mic.rms(fromBin: b0, toBin: b1)
        let r = remote.rms(fromBin: b0 - maxLagBins, toBin: b1)   // r[i + maxLagBins] is remote at bin b0 + i
        guard r.contains(where: { $0 > remoteFloor }) else { return nil }
        var best: Double? = nil
        var bestLag = 0
        for lag in 0...maxLagBins {
            // remote at (bin - lag) -> index (i + maxLagBins - lag)
            let shifted = (0..<m.count).map { r[$0 + maxLagBins - lag] }
            if let c = BleedGate.pearson(m, shifted), best == nil || c > best! { best = c; bestLag = lag }
        }
        guard let score = best else { return nil }
        let shifted = (0..<m.count).map { r[$0 + maxLagBins - bestLag] }
        return GateFeatures(score: score, lagMs: Double(bestLag) * EnvelopeTrack.binSeconds * 1000,
                            window: BleedGate.levels(mic: m, remote: shifted, remoteFloor: remoteFloor))
    }

    /// What the gate does with a mic result.
    /// - keep: the envelopes do not match.
    /// - drop: the envelopes match and the mic is as quiet next to the remote as a speaker echo is (or matches too tightly
    ///   to be anyone else).
    /// - defer: the envelopes match, but the mic is about as loud as the remote or louder, which is a person at the mic
    ///   (Alex talking over the remote speaker). Passed on; the text guard (`EchoGuard`, in `TurnEngine`) decides on words.
    public enum Verdict: String, Sendable, Equatable { case keep, drop, `defer` }

    /// Rule (P1 gate fix). Envelope correlation alone cannot tell an echo from a person talking at the same time (two speech
    /// envelopes correlate at 0.7 by chance, and the gate dropped the owner's "Sorry, one second..." at 0.72), so the level of
    /// the mic next to the remote is part of the rule. Measured on the two-track replay (docs/p1-replay-bleed-report.md,
    /// "Gate fix"): correlation >= 0.6 events of the owner's real speech sit at -8.1 ... -2.9 dB (n = 2) with correlation <= 0.73;
    /// echo events at -30/-25/-15/-10 dB sit at -28 ... -10 dB with correlation >= 0.69, 0.99 for -15 and -10 dB.
    public func verdict(_ f: GateFeatures) -> Verdict {
        guard f.score >= threshold else { return .keep }
        guard let ratio = f.window.ratioDb else { return .drop }   // no level information: as before
        if ratio <= maxEchoRatioDb { return .drop }
        if f.score >= strongScore, ratio <= maxStrongEchoRatioDb { return .drop }
        return .defer
    }

    public func isEcho(mic: EnvelopeTrack, remote: EnvelopeTrack, start: TimeInterval, end: TimeInterval) -> Bool {
        guard let f = features(mic: mic, remote: remote, start: start, end: end) else { return false }
        return verdict(f) == .drop
    }

    /// `m` and `r` are bin-aligned. A bin is "active" when it is above `remoteFloor` and within 20 dB of the window's peak.
    static func levels(mic m: [Double], remote r: [Double], remoteFloor: Double) -> GateLevels {
        let n = min(m.count, r.count)
        guard n > 0 else { return GateLevels(meDb: nil, remoteDb: nil, ratioDb: nil, micOnlyShare: 0, remoteActiveShare: 0) }
        let rPeak = r.prefix(n).max() ?? 0, mPeak = m.prefix(n).max() ?? 0
        let rThr = max(remoteFloor, 0.1 * rPeak), mThr = max(remoteFloor, 0.1 * mPeak)
        var sm = 0.0, sr = 0.0, k = 0, mActive = 0, mOnly = 0
        for i in 0..<n {
            let ra = r[i] > rThr
            if ra { sm += m[i] * m[i]; sr += r[i] * r[i]; k += 1 }
            if m[i] > mThr { mActive += 1; if !ra { mOnly += 1 } }
        }
        func db(_ ms: Double) -> Double? { ms > 0 ? 10 * log10(ms) : nil }
        let meDb = k > 0 ? db(sm / Double(k)) : nil, remoteDb = k > 0 ? db(sr / Double(k)) : nil
        return GateLevels(meDb: meDb, remoteDb: remoteDb, ratioDb: (meDb != nil && remoteDb != nil) ? meDb! - remoteDb! : nil,
                          micOnlyShare: mActive > 0 ? Double(mOnly) / Double(mActive) : 0, remoteActiveShare: Double(k) / Double(n))
    }

    public static func pearson(_ a: [Double], _ b: [Double]) -> Double? {
        let n = min(a.count, b.count)
        if n < 10 { return nil }
        let ma = a.prefix(n).reduce(0, +) / Double(n), mb = b.prefix(n).reduce(0, +) / Double(n)
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<n { let x = a[i] - ma, y = b[i] - mb; num += x * y; da += x * x; db += y * y }
        if da == 0 || db == 0 { return nil }
        return num / (da * db).squareRoot()
    }
}

/// Spec §5.7 / plan P1-3: exact-zero audio for >= 1 s on a running stream means the stream is dead, unless the
/// captured app is simply not playing anything (then it is ordinary silence). Pure state machine; the caller
/// supplies the time and the "is the app producing output" probe.
public struct DeadStreamDetector: Sendable {
    public var threshold: TimeInterval = 1.0
    private var zeroSince: TimeInterval?
    private var lastAudioAt: TimeInterval?
    private(set) public var reported = false

    public init(threshold: TimeInterval = 1.0) { self.threshold = threshold }

    public enum Verdict: Sendable, Equatable { case ok, silence, dead }

    /// Feed every chunk.
    public mutating func observe(_ chunk: AudioChunk) {
        if chunk.isExactZero {
            if zeroSince == nil { zeroSince = chunk.startTime }
        } else {
            zeroSince = nil
            reported = false
        }
        lastAudioAt = chunk.endTime
    }

    /// Call periodically. `now` is session time; `targetProducing` is the app-output probe (nil = unknown, treated
    /// as producing so a dead mic or unknown source is still reported).
    public mutating func check(now: TimeInterval, startedAt: TimeInterval, targetProducing: () -> Bool?) -> Verdict {
        let zeroRun: TimeInterval
        if let z = zeroSince {
            zeroRun = now - z
        } else if let last = lastAudioAt {
            zeroRun = now - last            // no callbacks at all since the last chunk
        } else {
            zeroRun = now - startedAt       // nothing ever arrived
        }
        guard zeroRun >= threshold else { return .ok }
        if targetProducing() ?? true {
            if reported { return .ok }
            reported = true
            return .dead
        }
        return .silence
    }
}
