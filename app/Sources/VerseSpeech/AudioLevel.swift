@preconcurrency import AVFoundation
import Foundation

/// Reads PCM buffers of any common format (Float32, Int16, Int32), channel 0 only, without writing anything.
enum PCMSamples {
    static func mono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return [] }
        if let ch = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: n))
        }
        if let ch = buffer.int16ChannelData {
            let p = ch[0]
            return (0..<n).map { Float(p[$0]) / 32768 }
        }
        if let ch = buffer.int32ChannelData {
            let p = ch[0]
            return (0..<n).map { Float(p[$0]) / 2147483648 }
        }
        return []
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var acc: Float = 0
        for s in samples { acc += s * s }
        return (acc / Float(samples.count)).squareRoot()
    }

    /// Linear-interpolation resampling to 16 kHz. Only a fallback for recognizer formats that are not 16 kHz.
    static func resample(_ x: [Float], from rate: Double, to target: Double) -> [Float] {
        guard rate != target, !x.isEmpty else { return x }
        let ratio = rate / target
        let m = max(Int(Double(x.count) / ratio), 1)
        return (0..<m).map { i in
            let pos = Double(i) * ratio
            let j = Int(pos)
            let f = Float(pos - Double(j))
            let a = x[min(j, x.count - 1)], b = x[min(j + 1, x.count - 1)]
            return a + (b - a) * f
        }
    }
}

/// Counts how long the signal has been below a loudness floor. Buffer by buffer, in stream order.
struct SilenceTracker {
    /// Linear RMS floor (about -45 dBFS): below it a buffer counts as silence.
    var floor: Float = 0.0056
    private(set) var run: TimeInterval = 0
    /// Stream time (seconds) of the end of the last buffer above the floor.
    private(set) var lastVoicedEnd: TimeInterval = 0
    private(set) var time: TimeInterval = 0
    private(set) var everVoiced = false

    /// Returns true when the buffer was voiced.
    @discardableResult
    mutating func add(rms: Float, duration: TimeInterval) -> Bool {
        time += duration
        if rms > floor {
            run = 0
            lastVoicedEnd = time
            everVoiced = true
            return true
        }
        run += duration
        return false
    }
}
