import AVFoundation
import Foundation
import os

/// Mono samples held in memory.
public struct PCMClip: Sendable {
    public var samples: [Float]
    public var sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval { Double(samples.count) / sampleRate }

    /// Reads an audio file into memory (mixed down to mono, Float32). Reading only; nothing is written.
    public static func read(_ url: URL) throws -> PCMClip {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw ListenError.sourceFailed("cannot read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let fmt = file.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw ListenError.sourceFailed("buffer allocation failed")
        }
        try file.read(into: buf)
        guard let ch = buf.floatChannelData else { throw ListenError.sourceFailed("no float data in \(url.lastPathComponent)") }
        let n = Int(buf.frameLength)
        let channels = Int(fmt.channelCount)
        var out = [Float](repeating: 0, count: n)
        for c in 0..<channels {
            let p = ch[c]
            for i in 0..<n { out[i] += p[i] / Float(channels) }
        }
        return PCMClip(samples: out, sampleRate: fmt.sampleRate)
    }

    /// Energy-based speech bounds within the clip (10 ms frames, threshold 4 % of the loudest frame), the same
    /// rule as the P0-B bench uses for t = 0.
    public func speechBounds() -> (start: TimeInterval, end: TimeInterval)? {
        let hop = max(Int(sampleRate * 0.01), 1)
        var rms: [Float] = []
        var i = 0
        while i + hop <= samples.count {
            var acc: Float = 0
            for j in i..<(i + hop) { acc += samples[j] * samples[j] }
            rms.append((acc / Float(hop)).squareRoot())
            i += hop
        }
        guard let peak = rms.max(), peak > 0 else { return nil }
        let thr = max(peak * 0.04, 1e-4)
        guard let first = rms.firstIndex(where: { $0 > thr }), let last = rms.lastIndex(where: { $0 > thr }) else { return nil }
        return (Double(first) * 0.01, Double(last + 1) * 0.01)
    }
}

/// Plays a clip at real-time pace (absolute deadlines), in 10 ms chunks, then `tailSeconds` of exact silence, then
/// ends. Used for tests and the replay harness; it stands in for a live stream.
public final class MemorySource: AudioCaptureSource, @unchecked Sendable {
    public let clip: PCMClip
    public let tailSeconds: TimeInterval
    public let chunkSeconds: TimeInterval
    public let name: String
    private let lock = OSAllocatedUnfairLock()
    private var task: Task<Void, Never>?
    /// Session time of the clip's first sample, once started.
    private(set) public var clipStartTime: TimeInterval?
    /// What `targetIsProducingOutput` reports (lets tests model "app playing" vs "app silent").
    public let simulatedTargetOutput: Bool?

    public init(clip: PCMClip, tailSeconds: TimeInterval = 2.0, chunkSeconds: TimeInterval = 0.01,
                name: String = "memory clip", simulatedTargetOutput: Bool? = false) {
        self.clip = clip
        self.tailSeconds = tailSeconds
        self.chunkSeconds = chunkSeconds
        self.name = name
        self.simulatedTargetOutput = simulatedTargetOutput
    }

    public var routeDescription: String { "\(name) (\(String(format: "%.2f", clip.duration)) s at real-time pace)" }

    public func targetIsProducingOutput() -> Bool? { simulatedTargetOutput }

    public func start(clock: SessionClock,
                      onChunk: @escaping @Sendable (AudioChunk) -> Void,
                      onEnd: @escaping @Sendable () -> Void) throws {
        let clip = self.clip
        let frames = max(Int(clip.sampleRate * chunkSeconds), 1)
        let dt = Double(frames) / clip.sampleRate
        let total = clip.samples.count + Int(tailSeconds * clip.sampleRate)
        let start = clock.now()
        clipStartTime = start
        let t = Task.detached(priority: .userInitiated) {
            let cc = ContinuousClock()
            let base = cc.now
            var pos = 0
            var i = 0
            while pos < total, !Task.isCancelled {
                let n = min(frames, total - pos)
                var chunk = [Float](repeating: 0, count: n)
                if pos < clip.samples.count {
                    let m = min(n, clip.samples.count - pos)
                    for k in 0..<m { chunk[k] = clip.samples[pos + k] }
                }
                // Deliver when the chunk's last sample would exist in a live stream.
                try? await cc.sleep(until: base + .seconds(Double(i + 1) * dt))
                if Task.isCancelled { break }
                onChunk(AudioChunk(samples: chunk, sampleRate: clip.sampleRate, startTime: start + Double(i) * dt))
                pos += n
                i += 1
            }
            onEnd()
        }
        lock.withLockUnchecked { task = t }
    }

    public func stop() {
        let t = lock.withLockUnchecked { () -> Task<Void, Never>? in let t = task; task = nil; return t }
        t?.cancel()
    }
}

/// A source that delivers exact zeros at real-time pace until stopped (models a tap whose app is silent, or a
/// tap starved by a missing permission). For tests.
public final class SilentSource: AudioCaptureSource, @unchecked Sendable {
    public let sampleRate: Double
    private let lock = OSAllocatedUnfairLock()
    private var task: Task<Void, Never>?
    private var producing: Bool?

    public init(sampleRate: Double = 48000, simulatedTargetOutput: Bool? = false) {
        self.sampleRate = sampleRate
        self.producing = simulatedTargetOutput
    }

    public var routeDescription: String { "silent source" }

    public func setSimulatedTargetOutput(_ v: Bool?) { lock.withLockUnchecked { producing = v } }
    public func targetIsProducingOutput() -> Bool? { lock.withLockUnchecked { producing } }

    public func start(clock: SessionClock,
                      onChunk: @escaping @Sendable (AudioChunk) -> Void,
                      onEnd: @escaping @Sendable () -> Void) throws {
        let sr = sampleRate
        let frames = Int(sr * 0.01)
        let start = clock.now()
        let t = Task.detached(priority: .userInitiated) {
            let cc = ContinuousClock()
            let base = cc.now
            var i = 0
            while !Task.isCancelled {
                try? await cc.sleep(until: base + .seconds(Double(i + 1) * 0.01))
                if Task.isCancelled { break }
                onChunk(AudioChunk(samples: [Float](repeating: 0, count: frames), sampleRate: sr, startTime: start + Double(i) * 0.01))
                i += 1
            }
        }
        lock.withLockUnchecked { task = t }
    }

    public func stop() {
        let t = lock.withLockUnchecked { () -> Task<Void, Never>? in let t = task; task = nil; return t }
        t?.cancel()
    }
}
