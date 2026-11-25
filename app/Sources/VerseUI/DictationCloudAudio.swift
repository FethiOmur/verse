import Foundation
import os

/// Converts the microphone's mono float chunks (at the device rate, usually 48 kHz) to 16 kHz signed 16-bit samples, the
/// format Whisper works in (Groq downsamples everything to 16 kHz mono itself, so nothing is lost by doing it here, and the
/// upload is a third of the size).
///
/// Linear interpolation, with the last sample and the fractional read position carried across chunks so chunk boundaries
/// leave no seam. No anti-alias filter: speech has little energy above 8 kHz and Whisper is trained on far rougher audio.
/// A change of the input rate (a route change) restarts the interpolation.
public struct DictationResampler: Sendable, Equatable {
    public static let targetRate: Double = 16_000

    /// Where the next output sample sits, in input samples from the start of the next chunk (-1 ..< 0: between the previous
    /// chunk's last sample and the next chunk's first).
    private var position: Double = 0
    private var last: Float = 0
    private var rate: Double = 0

    public init() {}

    /// The 16 kHz samples of one chunk, appended to `out`.
    public mutating func convert(_ samples: [Float], sampleRate: Double, into out: inout [Int16]) {
        guard !samples.isEmpty, sampleRate > 0 else { return }
        if sampleRate != rate {
            rate = sampleRate
            position = 0
        }
        let step = sampleRate / Self.targetRate
        let n = samples.count
        while position <= Double(n - 1) {
            let i = Int(position.rounded(.down))
            let frac = Float(position - Double(i))
            let a = i < 0 ? last : samples[i]
            let b = i + 1 < n ? samples[i + 1] : a
            out.append(Self.int16(a + (b - a) * frac))
            position += step
        }
        position -= Double(n)
        last = samples[n - 1]
    }

    static func int16(_ v: Float) -> Int16 {
        let c = max(-1, min(1, v))
        return Int16((c * 32767).rounded())
    }
}

/// The dictation's audio kept in memory for a cloud engine (`GroqDictationTranscriber`): fed from the capture callback
/// (`MeteredCaptureSource`, the same tee as the level meter), converted to 16 kHz 16-bit mono as it arrives, and capped at
/// `maxSeconds` so the upload stays well under Groq's 25 MB limit (5 minutes is 9.6 MB). Past the cap nothing more is kept
/// and `overflowed` is set: the cloud engine then uses the on-device text rather than send half a dictation.
///
/// `record` may be called on a real-time audio thread: it converts under an unfair lock, as `DictationInputMeter` does. It
/// never touches the disk; the samples go when the transcriber goes.
public final class DictationAudioRecorder: @unchecked Sendable {
    public static let maxSeconds: TimeInterval = 300

    private let lock = OSAllocatedUnfairLock()
    private let capSamples: Int
    private var samples_: [Int16] = []
    private var resampler = DictationResampler()
    private var overflowed_ = false

    public init(maxSeconds: TimeInterval = DictationAudioRecorder.maxSeconds) {
        capSamples = Int(maxSeconds * DictationResampler.targetRate)
        // The whole cap plus a second of slack for the chunk that crosses it (9.6 MB at 5 minutes), here rather than on the
        // capture thread: `record` then never reallocates and copies the array while it holds the lock. The pages are only
        // touched as samples arrive.
        samples_.reserveCapacity(capSamples + Int(DictationResampler.targetRate))
    }

    public func record(_ samples: [Float], sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        guard !overflowed_ else { return }
        resampler.convert(samples, sampleRate: sampleRate, into: &samples_)
        if samples_.count > capSamples {
            samples_.removeLast(samples_.count - capSamples)
            overflowed_ = true
        }
    }

    /// The 16 kHz samples so far and whether the cap cut the recording.
    public var snapshot: (samples: [Int16], overflowed: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (samples_, overflowed_)
    }

    /// The samples' reserved capacity (tests).
    var capacity: Int {
        lock.lock(); defer { lock.unlock() }
        return samples_.capacity
    }

    /// Seconds of audio kept.
    public var seconds: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(samples_.count) / DictationResampler.targetRate
    }
}

/// A canonical 44-byte-header PCM WAV (RIFF, mono, 16-bit little-endian), what the transcription endpoint gets.
public enum DictationWAV {
    public static let headerSize = 44

    public static func encode(_ samples: [Int16], sampleRate: Int = Int(DictationResampler.targetRate)) -> Data {
        let dataBytes = samples.count * 2
        var d = Data(capacity: headerSize + dataBytes)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        u32(16)                          // fmt chunk size
        u16(1)                           // PCM
        u16(1)                           // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))      // byte rate
        u16(2)                           // block align
        u16(16)                          // bits per sample
        d.append(contentsOf: Array("data".utf8))
        u32(UInt32(dataBytes))
        samples.withUnsafeBufferPointer { buf in
            for s in buf { withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        }
        return d
    }
}
