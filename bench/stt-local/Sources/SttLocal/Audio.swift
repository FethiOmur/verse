import Foundation
import AVFoundation
import Speech

/// One scripted question placed on the stream timeline.
struct Utterance: Codable, Sendable {
    let index: Int
    let voice: String
    let text: String
    let placedAtSec: Double     // where the rendered file starts on the stream
    let fileDurationSec: Double
    let speechStartSec: Double  // energy-based start on the stream
    let speechEndSec: Double    // energy-based acoustic end on the stream (t = 0 of the question)
}

/// All questions of one language laid out on one continuous 16 kHz mono stream.
struct Timeline: Sendable {
    static let sampleRate = 16000.0
    static let leadSilence = 1.0
    static let gapSilence = 2.5
    static let tailSilence = 4.0
    let samples: [Float]
    let utterances: [Utterance]
    var durationSec: Double { Double(samples.count) / Timeline.sampleRate }
}

enum Synth {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Renders `text` with a macOS voice into a 16 kHz mono Int16 WAV (CLI `say`, no GUI).
    static func say(voice: String, text: String, to url: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000", text]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure(description: "say failed (\(voice)): \(msg)")
        }
    }

    static func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw Failure(description: "buffer alloc failed")
        }
        try file.read(into: buf)
        guard let ch = buf.floatChannelData else { throw Failure(description: "no float data") }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
    }

    /// Energy-based speech bounds (seconds within the file): 10 ms frames, threshold 4 % of the loudest frame.
    static func speechBounds(_ s: [Float]) -> (start: Double, end: Double) {
        let hop = 160
        var rms: [Float] = []
        var i = 0
        while i + hop <= s.count {
            var acc: Float = 0
            for j in i..<(i + hop) { acc += s[j] * s[j] }
            rms.append((acc / Float(hop)).squareRoot())
            i += hop
        }
        let peak = rms.max() ?? 0
        let thr = max(peak * 0.04, 1e-4)
        let first = rms.firstIndex { $0 > thr } ?? 0
        let last = rms.lastIndex { $0 > thr } ?? max(rms.count - 1, 0)
        return (Double(first) * 0.01, Double(last + 1) * 0.01)
    }

    /// Synthesizes all questions into temp WAVs under `dir`, reads them into memory and lays them out in real-time order.
    static func buildTimeline(lang: LangSpec, count: Int, dir: URL) throws -> (Timeline, [URL]) {
        var files: [URL] = []
        var samples = [Float](repeating: 0, count: Int(Timeline.leadSilence * Timeline.sampleRate))
        var utts: [Utterance] = []
        for (i, q) in lang.questions.prefix(count).enumerated() {
            let voice = lang.voices[i % lang.voices.count]
            let url = dir.appendingPathComponent("\(lang.key)-\(String(format: "%02d", i)).wav")
            try say(voice: voice, text: q, to: url)
            files.append(url)
            let s = try readSamples(url)
            let b = speechBounds(s)
            let placed = Double(samples.count) / Timeline.sampleRate
            utts.append(Utterance(index: i, voice: voice, text: q, placedAtSec: placed,
                                  fileDurationSec: Double(s.count) / Timeline.sampleRate,
                                  speechStartSec: placed + b.start, speechEndSec: placed + b.end))
            samples += s
            samples += [Float](repeating: 0, count: Int(Timeline.gapSilence * Timeline.sampleRate))
        }
        samples += [Float](repeating: 0, count: Int((Timeline.tailSilence - Timeline.gapSilence) * Timeline.sampleRate))
        return (Timeline(samples: samples, utterances: utts), files)
    }

    /// Converts the timeline to the analyzer's preferred format and slices it into `chunkMs` buffers.
    static func makeInputs(_ t: Timeline, format target: AVAudioFormat, chunkMs: Int) throws -> [AnalyzerInput] {
        guard let srcFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Timeline.sampleRate, channels: 1, interleaved: false),
              let src = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: AVAudioFrameCount(t.samples.count)) else {
            throw Failure(description: "src buffer")
        }
        src.frameLength = AVAudioFrameCount(t.samples.count)
        t.samples.withUnsafeBufferPointer { p in src.floatChannelData![0].update(from: p.baseAddress!, count: t.samples.count) }

        let full: AVAudioPCMBuffer
        if srcFmt == target {
            full = src
        } else {
            guard let conv = AVAudioConverter(from: srcFmt, to: target) else { throw Failure(description: "no converter to \(target)") }
            let cap = AVAudioFrameCount(Double(src.frameLength) * target.sampleRate / srcFmt.sampleRate) + 4096
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { throw Failure(description: "out buffer") }
            nonisolated(unsafe) var given = false
            nonisolated(unsafe) let srcRef = src
            var err: NSError?
            let st = conv.convert(to: out, error: &err) { _, status in
                if given { status.pointee = .endOfStream; return nil }
                given = true
                status.pointee = .haveData
                return srcRef
            }
            if st == .error { throw Failure(description: "convert: \(err?.localizedDescription ?? "?")") }
            full = out
        }

        let chunkFrames = Int(target.sampleRate * Double(chunkMs) / 1000.0)
        let bpf = Int(target.streamDescription.pointee.mBytesPerFrame)
        var inputs: [AnalyzerInput] = []
        var pos = 0
        let total = Int(full.frameLength)
        let srcList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: full.audioBufferList))
        while pos < total {
            let n = min(chunkFrames, total - pos)
            guard let b = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(n)) else { throw Failure(description: "chunk alloc") }
            b.frameLength = AVAudioFrameCount(n)
            let dst = UnsafeMutableAudioBufferListPointer(b.mutableAudioBufferList)
            for k in 0..<srcList.count {
                memcpy(dst[k].mData, srcList[k].mData!.advanced(by: pos * bpf), n * bpf)
            }
            inputs.append(AnalyzerInput(buffer: b))
            pos += n
        }
        return inputs
    }
}
