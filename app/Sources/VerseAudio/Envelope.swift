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

/// Echo gate for the mic channel (spec §5.7): mic speech is discarded when its 10 ms envelope correlates
/// >= `threshold` with the remote envelope delayed by 0...`maxLag` (the remote sound reaching the mic later).
public struct BleedGate: Sendable {
    public var threshold: Double = 0.6
    public var maxLag: TimeInterval = 0.08
    /// Ranges shorter than this are widened symmetrically so the correlation has enough bins.
    public var minWindow: TimeInterval = 0.3
    /// Remote RMS below this everywhere in the window means there is nothing to echo.
    public var remoteFloor: Double = 1e-4

    public init() {}

    /// Highest Pearson correlation between mic[t] and remote[t - lag] over the window, for lag in 0...maxLag.
    /// `nil` when either side has no usable signal (then it cannot be echo).
    public func echoScore(mic: EnvelopeTrack, remote: EnvelopeTrack, start: TimeInterval, end: TimeInterval) -> Double? {
        var s = start, e = end
        if e - s < minWindow { let mid = (s + e) / 2; s = mid - minWindow / 2; e = mid + minWindow / 2 }
        let b0 = EnvelopeTrack.bin(s), b1 = EnvelopeTrack.bin(e) + 1
        let maxLagBins = Int((maxLag / EnvelopeTrack.binSeconds).rounded())
        let m = mic.rms(fromBin: b0, toBin: b1)
        let r = remote.rms(fromBin: b0 - maxLagBins, toBin: b1)   // r[i + maxLagBins] is remote at bin b0 + i
        guard r.contains(where: { $0 > remoteFloor }) else { return nil }
        var best: Double? = nil
        for lag in 0...maxLagBins {
            // remote at (bin - lag) -> index (i + maxLagBins - lag)
            let shifted = (0..<m.count).map { r[$0 + maxLagBins - lag] }
            if let c = BleedGate.pearson(m, shifted) { best = max(best ?? -1, c) }
        }
        return best
    }

    public func isEcho(mic: EnvelopeTrack, remote: EnvelopeTrack, start: TimeInterval, end: TimeInterval) -> Bool {
        guard let s = echoScore(mic: mic, remote: remote, start: start, end: end) else { return false }
        return s >= threshold
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
