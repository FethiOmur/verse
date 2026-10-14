import AudioToolbox
@preconcurrency import CoreAudio
import Foundation
import os

public enum TapRoute: String, Sendable, Codable {
    /// macOS 26 `CATapDescription.bundleIDs` + `processRestoreEnabled`: follows helpers that start later.
    case bundleID
    /// Fallback: a tap on the process objects that exist now, refreshed when coreaudiod's process list changes.
    case pidList
}

public enum TapRoutePreference: String, Sendable, Codable {
    case auto, bundleID, pidList
}

/// Default bundle IDs of the meeting apps (Brave's audio comes from `com.brave.Browser.helper`).
public let defaultRemoteBundleIDs = ["com.brave.Browser", "com.brave.Browser.helper", "ai.perplexity.comet", "ai.perplexity.comet.helper",
                                     "us.zoom.xos", "com.microsoft.teams2"]

/// Core Audio process tap on the meeting app -> private aggregate device that holds only the tap (no output
/// sub-device, so AirPods are never pulled into an aggregate or switched to headset mode) -> IOProc.
/// Samples are handed to `onChunk` straight from the IOProc (no batching) and never stored.
public final class ProcessTapSource: AudioCaptureSource, @unchecked Sendable {
    public let bundleIDs: [String]
    public let preference: TapRoutePreference
    public let muteBehavior: CATapMuteBehavior

    private let lock = OSAllocatedUnfairLock()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var stopped_ = false
    private var clock_: SessionClock?
    private var onChunk_: (@Sendable (AudioChunk) -> Void)?
    private var tappedObjects: [AudioObjectID] = []
    private var processListListener: AudioObjectPropertyListenerBlock?
    private let ioQueue = DispatchQueue(label: "verse.tap.io", qos: .userInteractive)
    private let controlQueue = DispatchQueue(label: "verse.tap.control")
    private let controlKey = DispatchSpecificKey<Bool>()
    private(set) public var route: TapRoute?
    private(set) public var tapFormatDescription = ""
    /// PID route: one line per process-list refresh (count of matching objects and the set-description status).
    public var refreshLog: [String] { lock.withLockUnchecked { refreshLog_ } }
    private var refreshLog_: [String] = []
    /// Errors from the bundle-ID attempt when `auto` fell back to the PID list.
    private(set) public var fallbackReason: String?

    public init(bundleIDs: [String] = defaultRemoteBundleIDs,
                preference: TapRoutePreference = .auto,
                muteBehavior: CATapMuteBehavior = .unmuted) {
        self.bundleIDs = bundleIDs
        self.preference = preference
        self.muteBehavior = muteBehavior
        controlQueue.setSpecific(key: controlKey, value: true)
    }

    public var routeDescription: String {
        switch route {
        case .bundleID: return "process tap (bundle ID \(bundleIDs.joined(separator: ",")), process restore on)"
        case .pidList: return "process tap (PID list: \(lock.withLockUnchecked { tappedObjects.count }) process objects)" + (fallbackReason.map { "; fallback because \($0)" } ?? "")
        case nil: return "process tap (not started)"
        }
    }

    public func targetIsProducingOutput() -> Bool? { AudioProcesses.anyOutputRunning(bundleIDs) }

    public func start(clock: SessionClock,
                      onChunk: @escaping @Sendable (AudioChunk) -> Void,
                      onEnd: @escaping @Sendable () -> Void) throws {
        switch preference {
        case .bundleID:
            try startTap(.bundleID, clock: clock, onChunk: onChunk)
        case .pidList:
            try startTap(.pidList, clock: clock, onChunk: onChunk)
        case .auto:
            do {
                try startTap(.bundleID, clock: clock, onChunk: onChunk)
            } catch {
                teardownTap()
                fallbackReason = "\(error)"
                try startTap(.pidList, clock: clock, onChunk: onChunk)
            }
        }
    }

    private func makeDescription(_ route: TapRoute) -> CATapDescription {
        let desc: CATapDescription
        switch route {
        case .bundleID:
            desc = CATapDescription(monoMixdownOfProcesses: [])
            desc.bundleIDs = bundleIDs
            desc.isProcessRestoreEnabled = true
        case .pidList:
            let objects = AudioProcesses.matching(bundleIDs).map { AudioObjectID($0.objectID) }
            lock.withLockUnchecked { tappedObjects = objects }
            desc = CATapDescription(monoMixdownOfProcesses: objects)
        }
        desc.uuid = UUID()
        desc.name = "Verse remote tap"
        desc.isPrivate = true
        desc.muteBehavior = muteBehavior
        return desc
    }

    private func startTap(_ route: TapRoute, clock: SessionClock, onChunk: @escaping @Sendable (AudioChunk) -> Void,
                          installListener: Bool = true) throws {
        let desc = makeDescription(route)
        var tid = AudioObjectID(kAudioObjectUnknown)
        do {
            try CA.check(AudioHardwareCreateProcessTap(desc, &tid), "AudioHardwareCreateProcessTap(\(route.rawValue))")
        } catch {
            throw ListenError.tapFailed("\(error)")
        }
        lock.withLockUnchecked { tapID = tid; clock_ = clock; onChunk_ = onChunk }

        let format = (try? CA.scalar(tid, kAudioTapPropertyFormat, AudioStreamBasicDescription())) ?? AudioStreamBasicDescription()
        let sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48000
        tapFormatDescription = "\(Int(sampleRate)) Hz, \(format.mChannelsPerFrame) ch"

        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Verse remote tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var aid = AudioObjectID(kAudioObjectUnknown)
        do {
            try CA.check(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aid), "AudioHardwareCreateAggregateDevice")
        } catch {
            throw ListenError.tapFailed("\(error)")
        }
        lock.withLockUnchecked { aggregateID = aid }

        var pid: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&pid, aid, ioQueue) { _, inInputData, inInputTime, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            // The aggregate holds only the tap, so the tap stream is the last (and only) input buffer.
            guard let b = abl.last, let data = b.mData else { return }
            let channels = max(Int(b.mNumberChannels), 1)
            let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
            let p = data.assumingMemoryBound(to: Float.self)
            var mono: [Float]
            if channels == 1 {
                mono = Array(UnsafeBufferPointer(start: p, count: n))
            } else {
                let frames = n / channels
                mono = [Float](repeating: 0, count: frames)
                for f in 0..<frames {
                    var s: Float = 0
                    for c in 0..<channels { s += p[f * channels + c] }
                    mono[f] = s / Float(channels)
                }
            }
            let t = inInputTime.pointee.mHostTime != 0
                ? clock.sessionTime(hostTime: inInputTime.pointee.mHostTime)
                : clock.now() - Double(mono.count) / sampleRate
            onChunk(AudioChunk(samples: mono, sampleRate: sampleRate, startTime: t))
        }
        do {
            try CA.check(status, "AudioDeviceCreateIOProcIDWithBlock")
            lock.withLockUnchecked { ioProcID = pid }
            try CA.check(AudioDeviceStart(aid, pid), "AudioDeviceStart")
        } catch {
            throw ListenError.tapFailed("\(error)")
        }
        self.route = route
        if route == .pidList && installListener { installProcessListListener() }
    }

    /// PID route only: when coreaudiod's process list changes (a helper starts or restarts), re-point the tap at
    /// the current matching process objects.
    private func installProcessListListener() {
        var a = CA.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refreshPIDList() }
        if AudioObjectAddPropertyListenerBlock(CA.system, &a, controlQueue, block) == noErr {
            lock.withLockUnchecked { processListListener = block }
        }
    }

    /// Updating a running tap's description is refused (kAudioTapPropertyDescription -> '!hog', measured), so the
    /// PID route rebuilds the tap and its aggregate device with the new process list (a gap of a few ms).
    private func refreshPIDList() {
        let now = AudioProcesses.matching(bundleIDs).map { AudioObjectID($0.objectID) }
        let (stopped, old, clock, onChunk) = lock.withLockUnchecked { (stopped_, tappedObjects, clock_, onChunk_) }
        guard !stopped, let clock, let onChunk, Set(now) != Set(old) else { return }
        teardownTap()
        var result = "ok"
        do { try startTap(.pidList, clock: clock, onChunk: onChunk, installListener: false) } catch { result = "\(error)" }
        lock.withLockUnchecked { refreshLog_.append("objects \(old.count) -> \(now.count): rebuilt tap (\(result))") }
    }

    private func teardownTap() {
        let (tid, aid, proc) = lock.withLockUnchecked { () -> (AudioObjectID, AudioObjectID, AudioDeviceIOProcID?) in
            let r = (tapID, aggregateID, ioProcID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            ioProcID = nil
            return r
        }
        if aid != kAudioObjectUnknown {
            if let proc {
                _ = AudioDeviceStop(aid, proc)
                _ = AudioDeviceDestroyIOProcID(aid, proc)
            }
            _ = AudioHardwareDestroyAggregateDevice(aid)
        }
        if tid != kAudioObjectUnknown { _ = AudioHardwareDestroyProcessTap(tid) }
    }

    public func stop() {
        let listener = lock.withLockUnchecked { () -> AudioObjectPropertyListenerBlock? in
            stopped_ = true
            let l = processListListener
            processListListener = nil
            return l
        }
        if let listener {
            var a = CA.address(kAudioHardwarePropertyProcessObjectList)
            _ = AudioObjectRemovePropertyListenerBlock(CA.system, &a, controlQueue, listener)
        }
        // Run teardown on the control queue so it cannot interleave with a refresh in progress.
        if DispatchQueue.getSpecific(key: controlKey) != nil { teardownTap() } else { controlQueue.sync { teardownTap() } }
    }

    deinit { stop() }
}
