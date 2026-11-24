import Foundation
import os
import VerseAudio

/// What the microphone of a dictation has delivered so far (the silent-microphone check).
public struct DictationInputLevel: Sendable, Equatable {
    /// Highest absolute sample; 0 when no audio arrived or every sample was exactly zero.
    public var peak: Float
    /// Seconds of audio delivered (sample count over sample rate), not seconds the microphone was open.
    public var audioSeconds: TimeInterval
    /// Audio callbacks (chunks) delivered.
    public var chunks: Int

    public init(peak: Float, audioSeconds: TimeInterval, chunks: Int) {
        self.peak = peak
        self.audioSeconds = audioSeconds
        self.chunks = chunks
    }
}

/// Loudness numbers of a dictation's microphone, fed from the capture callback (`MeteredCaptureSource`). It keeps a few
/// numbers and one open frame, never samples: the highest absolute sample and the seconds of audio since the dictation began
/// (the silent-microphone check) and the energy of the samples since the last `takeFrameRMS()` (one release-tail frame).
///
/// `record` may be called on a real-time audio thread: it only sums the chunk under an unfair lock, as `EnvelopeTrack` does.
public final class DictationInputMeter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var peak_: Float = 0
    private var chunks_ = 0
    private var audioSeconds_: TimeInterval = 0
    private var frameSumSq = 0.0
    private var frameCount = 0
    private var meterSumSq = 0.0
    private var meterCount = 0
    private var onCaptureClosed: (@Sendable () -> Void)?
    private var captureClosed = false

    public init() {}

    public func record(_ samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty else { return }
        var p: Float = 0
        var s = 0.0
        for v in samples {
            let a = abs(v)
            if a > p { p = a }
            s += Double(v) * Double(v)
        }
        lock.lock(); defer { lock.unlock() }
        if p > peak_ { peak_ = p }
        chunks_ += 1
        if sampleRate > 0 { audioSeconds_ += Double(samples.count) / sampleRate }
        frameSumSq += s
        frameCount += samples.count
        meterSumSq += s
        meterCount += samples.count
    }

    /// Highest absolute sample since the dictation began; 0 when no audio arrived at all or every sample was exactly zero.
    public var peak: Float { lock.lock(); defer { lock.unlock() }; return peak_ }
    /// Chunks delivered so far.
    public var chunks: Int { lock.lock(); defer { lock.unlock() }; return chunks_ }
    /// Peak, seconds of audio and chunks, read together.
    public var level: DictationInputLevel {
        lock.lock(); defer { lock.unlock() }
        return DictationInputLevel(peak: peak_, audioSeconds: audioSeconds_, chunks: chunks_)
    }

    /// RMS of the samples since the previous call (nil: none arrived), and starts the next frame.
    public func takeFrameRMS() -> Float? {
        lock.lock(); defer { lock.unlock() }
        defer { frameSumSq = 0; frameCount = 0 }
        guard frameCount > 0 else { return nil }
        return Float((frameSumSq / Double(frameCount)).squareRoot())
    }

    /// RMS of the samples since the previous call (nil: none arrived): the recording indicator's level (gap G5). Its own
    /// frame, so reading it never disturbs the release tail's `takeFrameRMS`.
    public func takeMeterRMS() -> Float? {
        lock.lock(); defer { lock.unlock() }
        defer { meterSumSq = 0; meterCount = 0 }
        guard meterCount > 0 else { return nil }
        return Float((meterSumSq / Double(meterCount)).squareRoot())
    }

    /// Called once, right after the microphone's capture has stopped (`MeteredCaptureSource.stop`). Set before the stop;
    /// when the capture already stopped, it is called at once.
    public func whenCaptureCloses(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if captureClosed {
            lock.unlock()
            handler()
            return
        }
        onCaptureClosed = handler
        lock.unlock()
    }

    func markCaptureClosed() {
        lock.lock()
        guard !captureClosed else { lock.unlock(); return }
        captureClosed = true
        let h = onCaptureClosed
        onCaptureClosed = nil
        lock.unlock()
        h?()
    }
}

/// The dictation's microphone source: the system's `MicSource` with every chunk also counted by a `DictationInputMeter`, and
/// the moment its capture stops reported to it. Everything else is the inner source's.
final class MeteredCaptureSource: AudioCaptureSource {
    let inner: any AudioCaptureSource
    let meter: DictationInputMeter

    init(inner: any AudioCaptureSource, meter: DictationInputMeter) {
        self.inner = inner
        self.meter = meter
    }

    var routeDescription: String { inner.routeDescription }

    func start(clock: SessionClock, onChunk: @escaping @Sendable (AudioChunk) -> Void, onEnd: @escaping @Sendable () -> Void) throws {
        let meter = self.meter
        try inner.start(clock: clock, onChunk: { chunk in
            meter.record(chunk.samples, sampleRate: chunk.sampleRate)
            onChunk(chunk)
        }, onEnd: onEnd)
    }

    /// The inner source stops its capture synchronously, so when the meter hears of it no more microphone audio can arrive.
    func stop() {
        inner.stop()
        meter.markCaptureClosed()
    }

    func targetIsProducingOutput() -> Bool? { inner.targetIsProducingOutput() }

    func setEventHandler(_ handler: @escaping @Sendable (CaptureEvent) -> Void) { inner.setEventHandler(handler) }
}

/// The release tail (gap G4, after TypeWhisper's `ReleaseTail.hotkeyStop`): the stop press used to close the microphone at
/// once, so a last syllable spoken while pressing could be cut. After the press the microphone stays open for at most
/// `maxDuration`, and closes early once `quietDuration` of quiet has passed (each `frameDuration` frame's RMS under
/// `speechRMSFloor`). A recording shorter than `minimumRecording` gets no tail (a quick tap, nothing to clip).
///
/// Pure: the controller feeds it one frame per `frameDuration` and the time since the press from its own clock.
public struct DictationReleaseTail: Sendable, Equatable {
    public static let maxDuration: TimeInterval = 0.35
    public static let quietDuration: TimeInterval = 0.15
    public static let frameDuration: TimeInterval = 0.05
    public static let minimumRecording: TimeInterval = 0.3
    /// Linear RMS (-48 dBFS). A quiet room's microphone is well under it; speech, even a trailing consonant, is above it.
    public static let speechRMSFloor: Float = 0.004

    /// Whether a recording that lasted `recordedFor` seconds (microphone open to stop press) gets a tail.
    public static func applies(recordedFor: TimeInterval) -> Bool { recordedFor >= minimumRecording }

    /// Quiet time in a row so far.
    public private(set) var quiet: TimeInterval = 0

    public init() {}

    /// One frame: its RMS (nil: no audio arrived in it, which counts as quiet) and the time since the press. True when the
    /// tail is over and the microphone may close.
    public mutating func add(frameRMS: Float?, elapsed: TimeInterval) -> Bool {
        if let rms = frameRMS, rms >= Self.speechRMSFloor {
            quiet = 0
        } else {
            quiet += Self.frameDuration
        }
        let eps = 1e-9
        return quiet + eps >= Self.quietDuration || elapsed + eps >= Self.maxDuration
    }
}

/// The silent-microphone rule (gap G10, after TypeWhisper's `isRecordingInputSilentSoFar`): the microphone has delivered at
/// least `minimumDuration` of audio and none of it was above `peakFloor`. A muted input or a dead Bluetooth route delivers
/// exact zeros; the floor (-100 dBFS) only absorbs dither. A working microphone in a quiet room has a noise floor far above it.
///
/// Time without callbacks never counts as silence: a microphone that delivers nothing (a stalled route, a capture that has not
/// started) is `noAudio`, a different state the controller logs instead of asking whether the microphone is muted.
public enum DictationSilence {
    public static let minimumDuration: TimeInterval = 1.0
    public static let peakFloor: Float = 0.00001
    /// How often the controller looks while recording.
    public static let checkInterval: TimeInterval = 0.25

    public enum Reading: Sendable, Equatable {
        /// Not enough audio yet to say.
        case undecided
        /// Something above the floor arrived: a working microphone (the peak never goes down, so this is final).
        case sound
        /// A second of audio, all of it exact silence: the microphone may be muted.
        case silent
        /// Open for a second and not one callback: no audio at all, which is not silence.
        case noAudio
    }

    /// The audio delivered so far was at least a second and all (near) zero.
    public static func isSilent(_ level: DictationInputLevel) -> Bool {
        level.chunks > 0 && level.audioSeconds + 1e-9 >= minimumDuration && level.peak < peakFloor
    }

    /// What the microphone shows after being open for `openFor` seconds.
    public static func reading(openFor: TimeInterval, level: DictationInputLevel) -> Reading {
        if level.peak >= peakFloor { return .sound }
        if isSilent(level) { return .silent }
        if level.chunks == 0, openFor + 1e-9 >= minimumDuration { return .noAudio }
        return .undecided
    }
}
