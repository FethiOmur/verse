import AVFoundation
import Foundation
import os

/// The owner's microphone via AVAudioEngine (default input device), delivered through an `AVAudioSinkNode` so each
/// hardware buffer is handed on as it arrives (no tap-size batching). Samples are never stored.
///
/// Voice processing is OFF by default. Measured on 2026-10-14 (see the P1-3 report): with voice processing on,
/// macOS ducks other apps' audio, and the meeting with it, by about 30 dB at the default level and still by about
/// 8 dB at the minimum level (`duckingLevel = .min`, advanced ducking off). The ducking also reaches the process
/// tap, so it would lower the remote transcription input too. Echo is handled by the bleed gate instead.
/// `voiceProcessing: true` is kept for experiments and always applies the minimum ducking configuration.
public final class MicSource: AudioCaptureSource, @unchecked Sendable {
    public let voiceProcessing: Bool
    private let lock = OSAllocatedUnfairLock()
    private var engine: AVAudioEngine?
    private(set) public var formatDescription = ""
    private(set) public var appliedDucking: String?

    /// The least ducking voice processing allows: fixed minimum level, advanced (voice-activity) ducking off.
    public static let minimumDucking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
        enableAdvancedDucking: false, duckingLevel: .min)

    public init(voiceProcessing: Bool = false) {
        self.voiceProcessing = voiceProcessing
    }

    public var routeDescription: String {
        "default input via AVAudioEngine sink" + (voiceProcessing ? " (voice processing, \(appliedDucking ?? "?"))" : " (no voice processing)")
    }

    public func targetIsProducingOutput() -> Bool? { nil }

    public func start(clock: SessionClock,
                      onChunk: @escaping @Sendable (AudioChunk) -> Void,
                      onEnd: @escaping @Sendable () -> Void) throws {
        let engine = AVAudioEngine()
        if voiceProcessing {
            // Touching the output side before enabling VP avoids kAUInitialize -10875 on start (measured).
            _ = engine.outputNode
            _ = engine.mainMixerNode
        }
        let input = engine.inputNode
        if voiceProcessing {
            do { try input.setVoiceProcessingEnabled(true) } catch {
                throw ListenError.micFailed("setVoiceProcessingEnabled: \(error)")
            }
            input.voiceProcessingOtherAudioDuckingConfiguration = MicSource.minimumDucking
            let c = input.voiceProcessingOtherAudioDuckingConfiguration
            appliedDucking = "ducking level \(c.duckingLevel.rawValue), advanced \(c.enableAdvancedDucking)"
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw ListenError.micFailed("no input device (format \(format))")
        }
        formatDescription = "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch"
        let sampleRate = format.sampleRate
        let sink = AVAudioSinkNode { timestamp, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            // Channel 0 is the (processed) voice channel; with VP the node exposes extra reference channels.
            guard let first = list.first, let data = first.mData else { return noErr }
            let n = Int(frameCount)
            let interleavedChannels = max(Int(first.mNumberChannels), 1)
            let p = data.assumingMemoryBound(to: Float.self)
            var mono = [Float](repeating: 0, count: n)
            for f in 0..<n { mono[f] = p[f * interleavedChannels] }
            let host = timestamp.pointee.mHostTime
            let t = host != 0 ? clock.sessionTime(hostTime: host) : clock.now() - Double(n) / sampleRate
            onChunk(AudioChunk(samples: mono, sampleRate: sampleRate, startTime: t))
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        engine.prepare()
        do { try engine.start() } catch {
            throw ListenError.micFailed("AVAudioEngine.start: \(error)")
        }
        lock.withLockUnchecked { self.engine = engine }
    }

    public func stop() {
        let e = lock.withLockUnchecked { () -> AVAudioEngine? in let e = engine; engine = nil; return e }
        guard let e else { return }
        e.stop()
        if voiceProcessing { try? e.inputNode.setVoiceProcessingEnabled(false) }
    }

    deinit { stop() }
}
