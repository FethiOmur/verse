import Foundation
import os

/// Collects loudness numbers only: per-10 ms sum of squares, sample count and peak. No samples are kept.
final class Envelope: @unchecked Sendable {
    static let binSeconds = 0.01
    let name: String
    let t0: Double              // shared run origin (host seconds)
    private let lock = OSAllocatedUnfairLock()
    private var sumsq: [Double] = []
    private var count: [Int] = []
    private var peak: [Float] = []
    private(set) var callbacks = 0
    private(set) var frames = 0
    private(set) var firstCallbackAt: Double? = nil      // host seconds
    private(set) var deliveryDelays: [Double] = []      // seconds from sample time to callback
    var sampleRate: Double = 48000
    private(set) var bufferLayout: [Int] = []

    func noteBufferLayout(_ l: [Int]) {
        lock.lock(); if bufferLayout.isEmpty { bufferLayout = l }; lock.unlock()
    }

    init(name: String, t0: Double) { self.name = name; self.t0 = t0 }

    /// `samples`: mono (or interleaved, treated as one stream) float samples starting at host time `startHost`.
    func add(_ samples: UnsafeBufferPointer<Float>, channels: Int, startHost: Double, callbackHost: Double) {
        let ch = max(channels, 1)
        let nFrames = samples.count / ch
        lock.lock(); defer { lock.unlock() }
        callbacks += 1
        frames += nFrames
        if firstCallbackAt == nil { firstCallbackAt = callbackHost }
        if deliveryDelays.count < 100_000 { deliveryDelays.append(callbackHost - startHost) }
        let rel = startHost - t0
        if rel < -1 { return }
        for f in 0..<nFrames {
            let t = rel + Double(f) / sampleRate
            if t < 0 { continue }
            let bin = Int(t / Envelope.binSeconds)
            if bin >= sumsq.count {
                let grow = bin - sumsq.count + 1
                sumsq.append(contentsOf: repeatElement(0, count: grow))
                count.append(contentsOf: repeatElement(0, count: grow))
                peak.append(contentsOf: repeatElement(0, count: grow))
            }
            var s: Float = 0
            var p: Float = 0
            for c in 0..<ch {
                let v = samples[f * ch + c]
                s += v * v
                p = max(p, abs(v))
            }
            sumsq[bin] += Double(s / Float(ch))
            count[bin] += 1
            if p > peak[bin] { peak[bin] = p }
        }
    }

    struct Snapshot {
        let sumsq: [Double]; let count: [Int]; let peak: [Float]
        let callbacks: Int; let frames: Int; let firstCallbackAt: Double?; let deliveryDelays: [Double]
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(sumsq: sumsq, count: count, peak: peak, callbacks: callbacks, frames: frames,
                        firstCallbackAt: firstCallbackAt, deliveryDelays: deliveryDelays)
    }
}

func db(_ x: Double) -> Double { x > 0 ? 20 * log10(x) : -200 }

func percentile(_ v: [Double], _ p: Double) -> Double? {
    if v.isEmpty { return nil }
    let s = v.sorted()
    let idx = min(s.count - 1, max(0, Int((p / 100) * Double(s.count - 1) + 0.5)))
    return s[idx]
}

func round2(_ x: Double?) -> Double? { x.map { ($0 * 100).rounded() / 100 } }

/// RMS (linear) per window of `binsPerWindow` 10 ms bins over [fromBin, toBin). nil = no data in that window.
func windowRMS(_ s: Envelope.Snapshot, binsPerWindow: Int, fromBin: Int, toBin: Int) -> [Double?] {
    var out: [Double?] = []
    var b = fromBin
    while b + binsPerWindow <= toBin {
        var ss = 0.0, n = 0
        for i in b..<(b + binsPerWindow) where i < s.sumsq.count { ss += s.sumsq[i]; n += s.count[i] }
        out.append(n > 0 ? (ss / Double(n)).squareRoot() : nil)
        b += binsPerWindow
    }
    return out
}

func windowPeak(_ s: Envelope.Snapshot, binsPerWindow: Int, fromBin: Int, toBin: Int) -> [Double] {
    var out: [Double] = []
    var b = fromBin
    while b + binsPerWindow <= toBin {
        var p: Float = 0
        for i in b..<(b + binsPerWindow) where i < s.peak.count { p = max(p, s.peak[i]) }
        out.append(Double(p))
        b += binsPerWindow
    }
    return out
}

struct LevelStats: Codable {
    let stream: String
    let windowMs: Int
    let windows: Int
    let windowsWithData: Int
    let windowsAboveFloor: Int
    let fractionAboveFloor: Double
    let floorDbfs: Double
    let rmsDbfsP10: Double?
    let rmsDbfsP50: Double?
    let rmsDbfsP90: Double?
    let peakDbfs: Double
    let allZero: Bool
    let callbacks: Int
    let framesReceived: Int
    let sampleRate: Double
    let firstCallbackAfterStartMs: Double?
    let deliveryDelayP50Ms: Double?
    let deliveryDelayP90Ms: Double?
    let perWindowRmsDbfs: [Double?]
}

func levelStats(_ env: Envelope, fromSec: Double, toSec: Double, floorDb: Double, startedAt: Double) -> LevelStats {
    let s = env.snapshot()
    let fromBin = Int(fromSec / Envelope.binSeconds), toBin = Int(toSec / Envelope.binSeconds)
    let w = windowRMS(s, binsPerWindow: 10, fromBin: fromBin, toBin: toBin)
    let pk = windowPeak(s, binsPerWindow: 10, fromBin: fromBin, toBin: toBin)
    let withData = w.compactMap { $0 }
    let dbs = withData.map { db($0) }
    let above = dbs.filter { $0 > floorDb }.count
    let peak = pk.max() ?? 0
    let delays = s.deliveryDelays.map { $0 * 1000 }
    return LevelStats(stream: env.name, windowMs: 100, windows: w.count, windowsWithData: withData.count,
                      windowsAboveFloor: above,
                      fractionAboveFloor: w.isEmpty ? 0 : (Double(above) / Double(w.count) * 1000).rounded() / 1000,
                      floorDbfs: floorDb,
                      rmsDbfsP10: round2(percentile(dbs, 10)), rmsDbfsP50: round2(percentile(dbs, 50)),
                      rmsDbfsP90: round2(percentile(dbs, 90)), peakDbfs: round2(db(peak)) ?? -200,
                      allZero: peak == 0, callbacks: s.callbacks, framesReceived: s.frames, sampleRate: env.sampleRate,
                      firstCallbackAfterStartMs: round2(s.firstCallbackAt.map { ($0 - startedAt) * 1000 }),
                      deliveryDelayP50Ms: round2(percentile(delays, 50)), deliveryDelayP90Ms: round2(percentile(delays, 90)),
                      perWindowRmsDbfs: w.map { $0.map { (db($0) * 10).rounded() / 10 } })
}

/// Linear RMS per 10 ms bin (0 where no data).
func binRMS(_ s: Envelope.Snapshot, fromBin: Int, toBin: Int) -> [Double] {
    (fromBin..<toBin).map { i in
        (i < s.count.count && s.count[i] > 0) ? (s.sumsq[i] / Double(s.count[i])).squareRoot() : 0
    }
}

func pearson(_ a: [Double], _ b: [Double]) -> Double? {
    let n = min(a.count, b.count)
    if n < 10 { return nil }
    let ma = a.prefix(n).reduce(0, +) / Double(n), mb = b.prefix(n).reduce(0, +) / Double(n)
    var num = 0.0, da = 0.0, dbb = 0.0
    for i in 0..<n { let x = a[i] - ma, y = b[i] - mb; num += x * y; da += x * x; dbb += y * y }
    if da == 0 || dbb == 0 { return nil }
    return num / (da * dbb).squareRoot()
}

/// Correlation of b shifted later by `lagBins` against a: corr(a[t], b[t+lag]).
func laggedPearson(_ a: [Double], _ b: [Double], lagBins: Int) -> Double? {
    if lagBins >= 0 {
        let n = min(a.count, b.count - lagBins)
        if n < 10 { return nil }
        return pearson(Array(a.prefix(n)), Array(b[lagBins..<(lagBins + n)]))
    } else {
        let l = -lagBins
        let n = min(a.count - l, b.count)
        if n < 10 { return nil }
        return pearson(Array(a[l..<(l + n)]), Array(b.prefix(n)))
    }
}
