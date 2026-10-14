import CoreAudio
import Darwin
import Foundation

/// One process as coreaudiod knows it. Only flags are read, never audio.
public struct AudioProcessInfo: Sendable, Equatable {
    public var bundleID: String?
    public var pid: Int32
    public var isRunningInput: Bool
    public var isRunningOutput: Bool

    public init(bundleID: String?, pid: Int32 = 0, isRunningInput: Bool = false, isRunningOutput: Bool = false) {
        self.bundleID = bundleID
        self.pid = pid
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }
}

public protocol AudioProcessTable: Sendable {
    func snapshot() -> [AudioProcessInfo]
}

/// Reads `kAudioHardwarePropertyProcessObjectList` and the per-process running flags (same properties as
/// VerseAudio's `AudioProcesses`; copied here so VerseMeet stays independent of the capture stack).
public struct CoreAudioProcessTable: AudioProcessTable {
    public init() {}

    public func snapshot() -> [AudioProcessInfo] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let ids = Self.array(system, kAudioHardwarePropertyProcessObjectList) else { return [] }
        return ids.map { id in
            AudioProcessInfo(
                bundleID: Self.string(id, kAudioProcessPropertyBundleID),
                pid: Self.scalar(id, kAudioProcessPropertyPID, pid_t(-1)),
                isRunningInput: Self.scalar(id, kAudioProcessPropertyIsRunningInput, UInt32(0)) != 0,
                isRunningOutput: Self.scalar(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) != 0)
        }
    }

    private static func address(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func array(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [AudioObjectID]? {
        var a = address(sel)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        if count == 0 { return [] }
        var out = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &out) == noErr else { return nil }
        return out
    }

    private static func scalar<T: BitwiseCopyable>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T) -> T {
        var a = address(sel)
        var v = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : initial
    }

    private static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = address(sel)
        var s: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &s) == noErr, let v = s else { return nil }
        return v.takeRetainedValue() as String
    }
}
