import AVFoundation
import Foundation

/// Default-input mic loudness via AVAudioEngine. Numbers only.
final class MicCapture: @unchecked Sendable {
    let env: Envelope
    let engine = AVAudioEngine()
    var info: [String: String] = [:]

    init(env: Envelope) { self.env = env }

    func start(voiceProcessing: Bool) throws {
        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            _ = engine.mainMixerNode
        }
        let fmt = input.outputFormat(forBus: 0)
        env.sampleRate = fmt.sampleRate
        info["format"] = "\(fmt.sampleRate) Hz, \(fmt.channelCount) ch"
        info["voiceProcessing"] = "\(input.isVoiceProcessingEnabled)"
        let env = self.env
        input.installTap(onBus: 0, bufferSize: 480, format: fmt) { buf, when in
            let cb = nowSeconds()
            guard let ch = buf.floatChannelData else { return }
            let start = when.isHostTimeValid ? hostToSeconds(when.hostTime) : cb - Double(buf.frameLength) / fmt.sampleRate
            env.add(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)), channels: 1, startHost: start, callbackHost: cb)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
