import AVFoundation
@preconcurrency import CoreAudio
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
///
/// Device changes (review H5): AVAudioEngine stops itself on `AVAudioEngineConfigurationChange` (AirPods connecting or
/// switching to headset mode, a USB mic unplugged, the default input changing). The source watches that notification and the
/// default input device, and rebuilds its engine on the new default input (`CaptureRebuilder`: coalesced, retried). The result
/// goes to the event handler: `.rebuilt` when audio flows again, `.failed` when every retry failed.
public final class MicSource: AudioCaptureSource, @unchecked Sendable {
    public let voiceProcessing: Bool
    private let lock = OSAllocatedUnfairLock()
    private var engine: AVAudioEngine?
    private var configObserver: (any NSObjectProtocol)?
    /// What the running engine was built for: the input node's output format and the default input device.
    private var builtRate: Double = 0
    private var builtChannels: AVAudioChannelCount = 0
    private var builtDevice = AudioObjectID(kAudioObjectUnknown)
    private var clock_: SessionClock?
    private var onChunk_: (@Sendable (AudioChunk) -> Void)?
    private var stopped_ = false
    private var eventHandler: (@Sendable (CaptureEvent) -> Void)?
    private var rebuilder: CaptureRebuilder?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var rebuildLog_: [String] = []
    private let controlQueue = DispatchQueue(label: "verse.mic.control")
    /// Property-listener blocks only trigger the rebuilder; they run here so removing a listener never waits on `controlQueue`.
    private let listenerQueue = DispatchQueue(label: "verse.mic.listener")
    private let controlKey = DispatchSpecificKey<Bool>()
    private(set) public var formatDescription = ""
    private(set) public var appliedDucking: String?
    /// One line per rebuild after a device change (for logs).
    public var rebuildLog: [String] { lock.withLockUnchecked { rebuildLog_ } }

    /// The least ducking voice processing allows: fixed minimum level, advanced (voice-activity) ducking off.
    public static let minimumDucking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
        enableAdvancedDucking: false, duckingLevel: .min)

    public init(voiceProcessing: Bool = false) {
        self.voiceProcessing = voiceProcessing
        controlQueue.setSpecific(key: controlKey, value: true)
    }

    public var routeDescription: String {
        "default input via AVAudioEngine sink" + (voiceProcessing ? " (voice processing, \(appliedDucking ?? "?"))" : " (no voice processing)")
    }

    public func targetIsProducingOutput() -> Bool? { nil }

    public func setEventHandler(_ handler: @escaping @Sendable (CaptureEvent) -> Void) {
        lock.withLockUnchecked { eventHandler = handler }
    }

    public func start(clock: SessionClock,
                      onChunk: @escaping @Sendable (AudioChunk) -> Void,
                      onEnd: @escaping @Sendable () -> Void) throws {
        lock.withLockUnchecked { clock_ = clock; onChunk_ = onChunk; stopped_ = false }
        try startEngine(clock: clock, onChunk: onChunk)
        let rb = CaptureRebuilder(queue: controlQueue,
                                  rebuild: { [weak self] in try self?.rebuildIfNeeded() ?? false },
                                  report: { [weak self] ev in self?.report(ev) })
        lock.withLockUnchecked { rebuilder = rb }
        var a = CA.address(kAudioHardwarePropertyDefaultInputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.trigger("default input device changed") }
        if AudioObjectAddPropertyListenerBlock(CA.system, &a, listenerQueue, block) == noErr {
            lock.withLockUnchecked { defaultInputListener = block }
        }
    }

    private func report(_ ev: CaptureEvent) {
        let h = lock.withLockUnchecked { eventHandler }
        h?(ev)
    }

    private func trigger(_ reason: String) {
        let rb = lock.withLockUnchecked { rebuilder }
        rb?.trigger(reason)
    }

    static func defaultInputDevice() -> AudioObjectID {
        (try? CA.scalar(CA.system, kAudioHardwarePropertyDefaultInputDevice, AudioObjectID(kAudioObjectUnknown))) ?? AudioObjectID(kAudioObjectUnknown)
    }

    private func startEngine(clock: SessionClock, onChunk: @escaping @Sendable (AudioChunk) -> Void) throws {
        let device = Self.defaultInputDevice()
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
            if voiceProcessing { try? input.setVoiceProcessingEnabled(false) }
            throw ListenError.micFailed("AVAudioEngine.start: \(error)")
        }
        let token = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) {
            [weak self] _ in self?.trigger("audio engine configuration changed")
        }
        lock.withLockUnchecked {
            self.engine = engine
            configObserver = token
            builtRate = format.sampleRate
            builtChannels = format.channelCount
            builtDevice = device
        }
    }

    private func teardownEngine() {
        let (e, token) = lock.withLockUnchecked { () -> (AVAudioEngine?, (any NSObjectProtocol)?) in
            let r = (engine, configObserver)
            engine = nil
            configObserver = nil
            return r
        }
        if let token { NotificationCenter.default.removeObserver(token) }
        guard let e else { return }
        e.stop()
        if voiceProcessing { try? e.inputNode.setVoiceProcessingEnabled(false) }
    }

    /// On `controlQueue`. False when the engine still runs on the same default input and format (nothing to do).
    private func rebuildIfNeeded() throws -> Bool {
        let (stopped, clock, onChunk, engine, rate, channels, device) = lock.withLockUnchecked {
            (stopped_, clock_, onChunk_, self.engine, builtRate, builtChannels, builtDevice)
        }
        guard !stopped, let clock, let onChunk else { return false }
        let nowDevice = Self.defaultInputDevice()
        if let engine, engine.isRunning {
            let f = engine.inputNode.outputFormat(forBus: 0)
            if !Self.needsRebuild(running: true, builtRate: rate, builtChannels: channels, builtDevice: device,
                                  nowRate: f.sampleRate, nowChannels: f.channelCount, nowDevice: nowDevice) { return false }
        }
        teardownEngine()
        try startEngine(clock: clock, onChunk: onChunk)
        let line = "rebuilt on device \(nowDevice) (was \(device)): \(formatDescription)"
        lock.withLockUnchecked { rebuildLog_.append(line) }
        return true
    }

    /// The rebuild decision: a stopped engine, another default input device or another input format needs a new engine.
    static func needsRebuild(running: Bool, builtRate: Double, builtChannels: AVAudioChannelCount, builtDevice: AudioObjectID,
                             nowRate: Double, nowChannels: AVAudioChannelCount, nowDevice: AudioObjectID) -> Bool {
        !running || nowRate != builtRate || nowChannels != builtChannels || nowDevice != builtDevice
    }

    public func stop() {
        let (listener, rb) = lock.withLockUnchecked { () -> (AudioObjectPropertyListenerBlock?, CaptureRebuilder?) in
            stopped_ = true
            let r = (defaultInputListener, rebuilder)
            defaultInputListener = nil
            rebuilder = nil
            return r
        }
        rb?.cancel()
        if let listener {
            var a = CA.address(kAudioHardwarePropertyDefaultInputDevice)
            _ = AudioObjectRemovePropertyListenerBlock(CA.system, &a, listenerQueue, listener)
        }
        // On the control queue, so a rebuild in progress finishes first and its new engine is the one stopped.
        if DispatchQueue.getSpecific(key: controlKey) != nil { teardownEngine() } else { controlQueue.sync { teardownEngine() } }
    }

    deinit { stop() }
}
