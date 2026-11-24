import AVFoundation
import Foundation

/// The two cues of dictation.
public enum DictationSound: String, Sendable, Equatable, CaseIterable {
    /// The microphone is open and the engine listens.
    case start
    /// The second press was taken: the microphone closes and the text follows.
    case stop
}

/// Plays a dictation cue. The app's is `SynthDictationSoundPlayer`; tests record the calls.
@MainActor
public protocol DictationSoundPlaying: AnyObject {
    func play(_ sound: DictationSound)
}

/// The cues, synthesised at runtime (no audio file in the bundle): a short drum-like hit, a sine whose pitch falls fast under
/// an exponential decay, with a softer second partial so small laptop speakers still carry it. The start cue is brighter and
/// louder; the stop cue lower, longer and softer.
enum DictationSoundSynth {
    static let sampleRate = 44_100

    struct Voice: Equatable {
        /// Seconds.
        var duration: Double
        /// Where the pitch ends (Hz) and how far above it the hit starts (Hz).
        var baseHz: Double
        var sweepHz: Double
        /// Time constant of the pitch fall and of the loudness decay (s).
        var sweepTau: Double
        var decayTau: Double
        /// Peak level, 0...1 of full scale.
        var peak: Double
        /// Level of the second partial relative to the first.
        var overtone: Double
        /// Attack ramp (s).
        var attack: Double
    }

    static func voice(_ sound: DictationSound) -> Voice {
        switch sound {
        case .start: return Voice(duration: 0.12, baseHz: 150, sweepHz: 250, sweepTau: 0.022, decayTau: 0.035,
                                  peak: 0.45, overtone: 0.35, attack: 0.0008)
        case .stop: return Voice(duration: 0.14, baseHz: 95, sweepHz: 150, sweepTau: 0.03, decayTau: 0.045,
                                 peak: 0.28, overtone: 0.3, attack: 0.003)
        }
    }

    /// Mono samples in -1...1.
    static func samples(_ sound: DictationSound) -> [Float] {
        let v = voice(sound)
        let n = Int(v.duration * Double(sampleRate))
        let fadeOut = Int(0.01 * Double(sampleRate))
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        let norm = 1 / (1 + v.overtone)
        for i in 0..<n {
            let t = Double(i) / Double(sampleRate)
            let hz = v.baseHz + v.sweepHz * exp(-t / v.sweepTau)
            phase += 2 * Double.pi * hz / Double(sampleRate)
            var env = exp(-t / v.decayTau)
            if t < v.attack { env *= t / v.attack }
            if i >= n - fadeOut { env *= Double(n - i) / Double(fadeOut) }
            let s = (sin(phase) + v.overtone * sin(2 * phase)) * norm
            out[i] = Float(v.peak * env * s)
        }
        return out
    }

    /// A 16-bit mono PCM WAV file of the cue.
    static func wav(_ sound: DictationSound) -> Data {
        let pcm = samples(sound).map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
        let dataBytes = UInt32(pcm.count * 2)
        var d = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36) + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
        d.append(contentsOf: Array("data".utf8)); put(dataBytes)
        for s in pcm { put(s) }
        return d
    }
}

/// Plays the synthesised cues through the default output with `AVAudioPlayer`. Each cue is built once, on its first play.
@MainActor
final class SynthDictationSoundPlayer: DictationSoundPlaying {
    private var players: [DictationSound: AVAudioPlayer] = [:]

    func play(_ sound: DictationSound) {
        let player: AVAudioPlayer
        if let p = players[sound] {
            player = p
        } else {
            guard let p = try? AVAudioPlayer(data: DictationSoundSynth.wav(sound), fileTypeHint: AVFileType.wav.rawValue) else { return }
            p.prepareToPlay()
            players[sound] = p
            player = p
        }
        player.currentTime = 0
        player.play()
    }
}
