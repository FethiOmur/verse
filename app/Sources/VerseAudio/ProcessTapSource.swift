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

/// Default bundle IDs of the meeting apps (a Chromium browser's audio comes from its `.helper` process). Every browser a Meet call
/// can run in is listed: a call in a browser missing here reaches Verse only through the mic, labelled as the owner (2 Nov, Chrome).
public let defaultRemoteBundleIDs = ["com.brave.Browser", "com.brave.Browser.helper", "ai.perplexity.comet", "ai.perplexity.comet.helper",
                                     "com.google.Chrome", "com.google.Chrome.helper", "com.microsoft.edgemac", "com.microsoft.edgemac.helper",
                                     "company.thebrowser.Browser", "company.thebrowser.Browser.helper", "com.apple.Safari",
                                     "org.mozilla.firefox", "us.zoom.xos", "com.microsoft.teams2"]

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
    /// Review H5: the default output device and the current tap's format are watched; a change rebuilds the tap. The output
    /// devices the meeting app itself plays to (often not the default: a USB headset picked in Zoom) are watched through
    /// `watch` (see `watchKeys`), and a stall watchdog covers a tap that stops calling back with no notification at all.
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var formatListener: (tap: AudioObjectID, block: AudioObjectPropertyListenerBlock)?
    private var builtRate: Double = 0
    private var builtChannels: UInt32 = 0
    private var builtOutputDevice = AudioObjectID(kAudioObjectUnknown)
    /// The last PID-list refresh could not build a tap: the next rebuild pass rebuilds whatever it finds.
    private var broken = false
    /// The output devices the meeting app's processes played to when the tap was built (any device, not only the default),
    /// with each one's nominal rate. A call in Zoom/Teams/a browser can play to a headset that is not the system default;
    /// that device going away, the app moving off it or its rate changing rebuilds the tap like a default-output change.
    private var builtAppOutput: [AudioObjectID: Double] = [:]
    /// Listeners on the device list, the process list, each meeting process's output devices and each device it plays to.
    private var watch: AudioPropertyWatch?
    /// The stall watchdog asked the next pass to rebuild although no property says anything changed.
    private var stallPending = false
    private var stallTimer: DispatchSourceTimer?
    private let ioState = TapIOState()
    /// No IOProc callback at all for this long while the meeting app sends audio to an output counts as a stall.
    static let stallThreshold: TimeInterval = 3
    private var rebuilder: CaptureRebuilder?
    private var eventHandler: (@Sendable (CaptureEvent) -> Void)?
    /// Device and format listener blocks only trigger the rebuilder; they run here so removing one never waits on `controlQueue`.
    private let listenerQueue = DispatchQueue(label: "verse.tap.listener")
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

    public func setEventHandler(_ handler: @escaping @Sendable (CaptureEvent) -> Void) {
        lock.withLockUnchecked { eventHandler = handler }
    }

    public func start(clock: SessionClock,
                      onChunk: @escaping @Sendable (AudioChunk) -> Void,
                      onEnd: @escaping @Sendable () -> Void) throws {
        try startRoute(clock: clock, onChunk: onChunk)
        let rb = CaptureRebuilder(queue: controlQueue,
                                  rebuild: { [weak self] in try self?.rebuildIfNeeded() ?? false },
                                  report: { [weak self] ev in
                                      guard let self else { return }
                                      let h = self.lock.withLockUnchecked { self.eventHandler }
                                      h?(ev)
                                  })
        let app = Self.appOutput(bundleIDs)
        lock.withLockUnchecked { rebuilder = rb; builtOutputDevice = Self.defaultOutputDevice(); builtAppOutput = app.devices }
        var a = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.trigger("default output device changed") }
        if AudioObjectAddPropertyListenerBlock(CA.system, &a, listenerQueue, block) == noErr {
            lock.withLockUnchecked { defaultOutputListener = block }
        }
        let w = AudioPropertyWatch(queue: listenerQueue) { [weak self] key in self?.trigger(Self.reason(for: key)) }
        lock.withLockUnchecked { watch = w }
        onControlQueue { syncWatch(app) }
        startStallWatchdog()
    }

    /// Runs `body` on `controlQueue` (inline when already there), where rebuild passes and teardown run.
    private func onControlQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: controlKey) != nil { body() } else { controlQueue.sync(execute: body) }
    }

    /// On `controlQueue`: points the listeners at the meeting processes and devices of `app`. Nothing after `stop()`.
    private func syncWatch(_ app: (processes: [AudioObjectID], devices: [AudioObjectID: Double])) {
        let w = lock.withLockUnchecked { stopped_ ? nil : watch }
        w?.sync(Self.watchKeys(processes: app.processes, devices: Array(app.devices.keys)))
    }

    /// What the tap listens to besides the default output and its own format: the device list (a device appears or goes),
    /// the process list (a meeting helper starts), each meeting process's output devices (the app moved to another device)
    /// and each device it plays to, default or not (its nominal rate).
    static func watchKeys(processes: [AudioObjectID], devices: [AudioObjectID]) -> Set<AudioWatchKey> {
        var keys: Set<AudioWatchKey> = [AudioWatchKey(object: CA.system, selector: kAudioHardwarePropertyDevices),
                                        AudioWatchKey(object: CA.system, selector: kAudioHardwarePropertyProcessObjectList)]
        for p in processes { keys.insert(AudioWatchKey(object: p, selector: kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)) }
        for d in devices { keys.insert(AudioWatchKey(object: d, selector: kAudioDevicePropertyNominalSampleRate)) }
        return keys
    }

    static func reason(for key: AudioWatchKey) -> String {
        switch key.selector {
        case kAudioHardwarePropertyDevices: return "audio device list changed"
        case kAudioHardwarePropertyProcessObjectList: return "meeting app processes changed"
        case kAudioProcessPropertyDevices: return "meeting app output device changed"
        case kAudioDevicePropertyNominalSampleRate: return "meeting app output device rate changed"
        default: return "audio property changed"
        }
    }

    /// The meeting app's processes and the output devices they play to right now, each with its nominal rate (0 = unreadable,
    /// e.g. a device that is going away).
    static func appOutput(_ bundleIDs: [String]) -> (processes: [AudioObjectID], devices: [AudioObjectID: Double]) {
        let processes = AudioProcesses.matching(bundleIDs).map { AudioObjectID($0.objectID) }
        var devices: [AudioObjectID: Double] = [:]
        for p in processes {
            let ids = (try? CA.array(p, kAudioProcessPropertyDevices, AudioObjectID.self, scope: kAudioObjectPropertyScopeOutput)) ?? []
            for d in ids where d != kAudioObjectUnknown && devices[d] == nil {
                devices[d] = (try? CA.scalar(d, kAudioDevicePropertyNominalSampleRate, Float64(0))) ?? 0
            }
        }
        return (processes, devices)
    }

    public enum AppOutputChange: Equatable, Sendable {
        case none
        /// The app started playing after the tap was built: remember its devices (a tap built before the call's audio starts
        /// is what every session start does), no rebuild.
        case adopt
        case rebuild(String)
    }

    /// The decision for the meeting app's own output devices. An app that paused its output (no devices) changes nothing; a
    /// different set of devices or another rate on one of them rebuilds.
    static func appOutputChange(built: [AudioObjectID: Double], now: [AudioObjectID: Double]) -> AppOutputChange {
        if now.isEmpty { return .none }
        if built.isEmpty { return .adopt }
        let b = built.keys.sorted(), n = now.keys.sorted()
        if b != n {
            return .rebuild("meeting app output devices \(b.map(String.init)) -> \(n.map(String.init))")
        }
        let changed = n.filter { built[$0] != now[$0] }
        if changed.isEmpty { return .none }
        return .rebuild("meeting app output device " + changed.map { "\($0): \(Int(built[$0] ?? 0)) -> \(Int(now[$0] ?? 0)) Hz" }.joined(separator: ", "))
    }

    // MARK: stall watchdog

    /// What notifications cannot see: the tap's aggregate device stops calling the IOProc (its clock went with a device) with
    /// no property change. A running tap delivers buffers of zeros during silence, so missing callbacks are never ordinary
    /// silence; the check also requires the meeting app to be sending audio to an output (unknown counts as no) and fires once
    /// per stall (latched until a callback arrives). A tap that keeps calling back with exact zeros while the app plays is not
    /// covered here: that looks the same as a silent remote side, and only `DeadStreamDetector` reports it (no rebuild).
    static func isStalled(now: TimeInterval, lastCallback: TimeInterval?, builtAt: TimeInterval, threshold: TimeInterval,
                          latched: Bool, producing: () -> Bool?) -> Bool {
        guard !latched, now - (lastCallback ?? builtAt) >= threshold else { return false }
        return producing() == true
    }

    private func startStallWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: listenerQueue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.checkStall() }
        lock.withLockUnchecked { stallTimer = t }
        t.resume()
    }

    private func checkStall() {
        let s = ioState.snapshot()
        let ids = bundleIDs
        guard Self.isStalled(now: HostTime.nowSeconds(), lastCallback: s.lastCallback, builtAt: s.builtAt, threshold: Self.stallThreshold,
                             latched: s.latched, producing: { AudioProcesses.anyOutputRunning(ids) }) else { return }
        ioState.latch()
        lock.withLockUnchecked { stallPending = true }
        trigger("no audio callbacks for \(Int(Self.stallThreshold)) s while the meeting app plays")
    }

    private func trigger(_ reason: String) {
        let rb = lock.withLockUnchecked { rebuilder }
        rb?.trigger(reason)
    }

    static func defaultOutputDevice() -> AudioObjectID {
        (try? CA.scalar(CA.system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(kAudioObjectUnknown))) ?? AudioObjectID(kAudioObjectUnknown)
    }

    private func startRoute(clock: SessionClock, onChunk: @escaping @Sendable (AudioChunk) -> Void) throws {
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
        lock.withLockUnchecked { builtRate = format.mSampleRate; builtChannels = format.mChannelsPerFrame }
        // The IOProc below labels every chunk with this rate, so a format change must rebuild the tap (review H5).
        var fa = CA.address(kAudioTapPropertyFormat)
        let formatBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.trigger("tap format changed") }
        if AudioObjectAddPropertyListenerBlock(tid, &fa, listenerQueue, formatBlock) == noErr {
            lock.withLockUnchecked { formatListener = (tid, formatBlock) }
        }

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
        let io = ioState
        io.reset(builtAt: HostTime.nowSeconds())
        let status = AudioDeviceCreateIOProcIDWithBlock(&pid, aid, ioQueue) { _, inInputData, inInputTime, _, _ in
            io.beat()
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
        var failed = false
        do { try startTap(.pidList, clock: clock, onChunk: onChunk, installListener: false) } catch { result = "\(error)"; failed = true }
        lock.withLockUnchecked { refreshLog_.append("objects \(old.count) -> \(now.count): rebuilt tap (\(result))"); broken = failed }
        // A failed refresh used to leave the remote channel silent with no signal. With no meeting process left there is nothing
        // to hear, so only a failure with processes to tap goes to the rebuilder (retries, then `.failed`).
        if failed && !now.isEmpty { trigger("process list refresh failed") }
    }

    /// On `controlQueue`. False when the tap still exists with the format it was built for, the default output is unchanged,
    /// the meeting app plays to the same devices at the same rates and the stall watchdog did not ask for a rebuild.
    private func rebuildIfNeeded() throws -> Bool {
        let (stopped, clock, onChunk, tid, rate, channels, device, isBroken, builtApp) = lock.withLockUnchecked {
            (stopped_, clock_, onChunk_, tapID, builtRate, builtChannels, builtOutputDevice, broken, builtAppOutput)
        }
        guard !stopped, let clock, let onChunk, let route else { return false }
        let nowDevice = Self.defaultOutputDevice()
        let app = Self.appOutput(bundleIDs)
        // Every pass re-points the listeners: the meeting app may have new processes or play to other devices now.
        defer { syncWatch(app) }
        let f = tid == kAudioObjectUnknown ? nil : try? CA.scalar(tid, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        let tapChanged = Self.needsRebuild(tapExists: tid != kAudioObjectUnknown && !isBroken, builtRate: rate, builtChannels: channels,
                                           builtDevice: device, nowRate: f?.mSampleRate, nowChannels: f?.mChannelsPerFrame, nowDevice: nowDevice)
        let appChange = Self.appOutputChange(built: builtApp, now: app.devices)
        let stall = lock.withLockUnchecked { () -> Bool in defer { stallPending = false }; return stallPending }
        if !tapChanged && !stall {
            switch appChange {
            case .none: return false
            case .adopt:
                lock.withLockUnchecked { builtAppOutput = app.devices }
                return false
            case .rebuild: break
            }
        }
        teardownTap()
        do {
            try startTap(route, clock: clock, onChunk: onChunk, installListener: false)
        } catch {
            teardownTap()
            lock.withLockUnchecked { broken = true }
            throw error
        }
        var why = ["output device \(device) -> \(nowDevice)"]
        if case .rebuild(let m) = appChange { why.append(m) }
        if stall { why.append("stalled") }
        let line = why.joined(separator: "; ") + ": rebuilt tap (\(tapFormatDescription))"
        lock.withLockUnchecked { broken = false; builtOutputDevice = nowDevice; builtAppOutput = app.devices; refreshLog_.append(line) }
        return true
    }

    /// The rebuild decision: no working tap, another tap format (nil = unreadable) or another default output device.
    static func needsRebuild(tapExists: Bool, builtRate: Double, builtChannels: UInt32, builtDevice: AudioObjectID,
                             nowRate: Double?, nowChannels: UInt32?, nowDevice: AudioObjectID) -> Bool {
        guard tapExists, let nowRate, let nowChannels else { return true }
        return nowRate != builtRate || nowChannels != builtChannels || nowDevice != builtDevice
    }

    private func teardownTap() {
        let (tid, aid, proc, fl) = lock.withLockUnchecked { () -> (AudioObjectID, AudioObjectID, AudioDeviceIOProcID?, (tap: AudioObjectID, block: AudioObjectPropertyListenerBlock)?) in
            let r = (tapID, aggregateID, ioProcID, formatListener)
            tapID = AudioObjectID(kAudioObjectUnknown)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            ioProcID = nil
            formatListener = nil
            return r
        }
        if let fl {
            var fa = CA.address(kAudioTapPropertyFormat)
            _ = AudioObjectRemovePropertyListenerBlock(fl.tap, &fa, listenerQueue, fl.block)
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
        let (listener, outListener, rb, w, timer) = lock.withLockUnchecked {
            () -> (AudioObjectPropertyListenerBlock?, AudioObjectPropertyListenerBlock?, CaptureRebuilder?, AudioPropertyWatch?, DispatchSourceTimer?) in
            stopped_ = true
            let r = (processListListener, defaultOutputListener, rebuilder, watch, stallTimer)
            processListListener = nil
            defaultOutputListener = nil
            rebuilder = nil
            watch = nil
            stallTimer = nil
            return r
        }
        rb?.cancel()
        timer?.cancel()
        if let listener {
            var a = CA.address(kAudioHardwarePropertyProcessObjectList)
            _ = AudioObjectRemovePropertyListenerBlock(CA.system, &a, controlQueue, listener)
        }
        if let outListener {
            var a = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
            _ = AudioObjectRemovePropertyListenerBlock(CA.system, &a, listenerQueue, outListener)
        }
        // Run teardown on the control queue so it cannot interleave with a refresh (or a pass re-pointing the listeners) in progress.
        onControlQueue {
            w?.removeAll()
            teardownTap()
        }
    }

    deinit { stop() }
}

/// IOProc bookkeeping for the stall watchdog. Its own small lock, taken once per buffer.
final class TapIOState: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var lastCallback: TimeInterval?
    private var builtAt: TimeInterval = 0
    private var latched = false

    /// A callback arrived: the tap delivers again (a later stall may rebuild again).
    func beat() {
        let now = HostTime.nowSeconds()
        lock.withLockUnchecked { lastCallback = now; latched = false }
    }

    /// A new tap starts: its grace period begins. The latch stays until that tap actually calls back.
    func reset(builtAt t: TimeInterval) { lock.withLockUnchecked { builtAt = t; lastCallback = nil } }

    func latch() { lock.withLockUnchecked { latched = true } }

    func snapshot() -> (lastCallback: TimeInterval?, builtAt: TimeInterval, latched: Bool) {
        lock.withLockUnchecked { (lastCallback, builtAt, latched) }
    }
}
