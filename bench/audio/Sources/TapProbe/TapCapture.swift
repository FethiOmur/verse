import CoreAudio
import AudioToolbox
import Foundation

enum TapTarget {
    case processes([AudioObjectID])          // mono mixdown of these process objects
    case bundleIDs([String])                 // macOS 26: tap by bundle ID (+ process restore)
    case globalExcluding([AudioObjectID])    // everything except these processes
}

/// Core Audio process tap -> private aggregate device -> IOProc that feeds an Envelope. Never stores samples.
final class TapCapture: @unchecked Sendable {
    let env: Envelope
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "tapprobe.io", qos: .userInteractive)
    private(set) var format = AudioStreamBasicDescription()
    private(set) var startedAt: Double = 0
    var info: [String: String] = [:]

    nonisolated(unsafe) static var defaultWithSubDevice = false

    init(env: Envelope) { self.env = env }

    /// withSubDevice: also add the default output device as the aggregate's clock sub-device (AudioCap style).
    /// Off by default: with Bluetooth headsets (AirPods) it can open their mic and drop them to the HFP profile.
    func start(_ target: TapTarget, withSubDevice: Bool = TapCapture.defaultWithSubDevice) throws {
        let desc: CATapDescription
        switch target {
        case .processes(let ids):
            desc = CATapDescription(monoMixdownOfProcesses: ids)
        case .globalExcluding(let ids):
            desc = CATapDescription(monoGlobalTapButExcludeProcesses: ids)
        case .bundleIDs(let b):
            desc = CATapDescription(monoMixdownOfProcesses: [])
            desc.bundleIDs = b
            desc.isProcessRestoreEnabled = true
        }
        desc.uuid = UUID()
        desc.name = "TapProbe-\(env.name)"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var tid = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &tid), "AudioHardwareCreateProcessTap")
        tapID = tid

        format = try getScalar(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        env.sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48000
        info["tapFormat"] = "\(format.mSampleRate) Hz, \(format.mChannelsPerFrame) ch, flags 0x\(String(format.mFormatFlags, radix: 16)), \(format.mBitsPerChannel) bit"

        let aggUID = UUID().uuidString
        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TapProbe-\(env.name)",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        if withSubDevice {
            let outUID = try defaultOutputDeviceUID()
            info["mainSubDevice"] = outUID
            dict[kAudioAggregateDeviceMainSubDeviceKey] = outUID
            dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outUID]]
        } else {
            info["mainSubDevice"] = "none (tap only)"
        }
        var aid = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aid), "AudioHardwareCreateAggregateDevice")
        aggID = aid

        if let bs = try? getScalar(aggID, kAudioDevicePropertyBufferFrameSize, UInt32(0)) { info["bufferFrames"] = "\(bs)" }
        if let lat = try? getScalar(aggID, kAudioDevicePropertyLatency, UInt32(0), scope: kAudioObjectPropertyScopeInput) {
            info["inputLatencyFrames"] = "\(lat)"
        }
        if let so = try? getScalar(aggID, kAudioDevicePropertySafetyOffset, UInt32(0), scope: kAudioObjectPropertyScopeInput) {
            info["inputSafetyOffsetFrames"] = "\(so)"
        }

        let env = self.env
        var pid: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&pid, aggID, queue) { inNow, inInputData, inInputTime, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let start = hostToSeconds(inInputTime.pointee.mHostTime)
            let now = hostToSeconds(inNow.pointee.mHostTime)
            // Taps are appended after sub-device inputs, so the tap stream is the last input buffer.
            env.noteBufferLayout(abl.map { Int($0.mNumberChannels) })
            guard let b = abl.last, let data = b.mData else { return }
            let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
            let ptr = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: n)
            env.add(ptr, channels: Int(b.mNumberChannels), startHost: start, callbackHost: now)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        procID = pid
        if let n = try? getArray(aggID, kAudioDevicePropertyStreams, AudioObjectID.self) { info["aggregateStreams"] = "\(n.count)" }
        startedAt = nowSeconds()
        try check(AudioDeviceStart(aggID, procID), "AudioDeviceStart")
    }

    func stop() {
        if aggID != kAudioObjectUnknown {
            if let p = procID {
                _ = AudioDeviceStop(aggID, p)
                _ = AudioDeviceDestroyIOProcID(aggID, p)
            }
            _ = AudioHardwareDestroyAggregateDevice(aggID)
            aggID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }
}
