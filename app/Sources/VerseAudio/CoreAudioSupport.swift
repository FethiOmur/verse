import CoreAudio
import Darwin
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus
    var description: String { "\(what): OSStatus \(status) (\(CoreAudioError.fourCC(status)))" }

    static func fourCC(_ s: OSStatus) -> String {
        let u = UInt32(bitPattern: s)
        let bytes = [UInt8((u >> 24) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 8) & 0xff), UInt8(u & 0xff)]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return "'" + String(decoding: bytes, as: UTF8.self) + "'" }
        return String(s)
    }
}

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    @inline(__always) static func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw CoreAudioError(what: what, status: status) }
    }

    static func address(_ sel: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func array<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ type: T.Type) throws -> [T] {
        var a = address(sel)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size), "GetPropertyDataSize")
        let count = Int(size) / MemoryLayout<T>.stride
        if count == 0 { return [] }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { buf.deallocate() }
        try check(AudioObjectGetPropertyData(obj, &a, 0, nil, &size, buf), "GetPropertyData")
        return Array(UnsafeBufferPointer(start: buf.bindMemory(to: T.self, capacity: count), count: count))
    }

    static func scalar<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var a = address(sel, scope)
        var v = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v), "GetPropertyData")
        return v
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = address(sel)
        var s: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &s) == noErr, let v = s else { return nil }
        return v.takeRetainedValue() as String
    }
}

/// A process registered with coreaudiod.
public struct AudioProcess: Sendable, Codable, Equatable {
    public let objectID: UInt32
    public let pid: Int32
    public let bundleID: String?
    public let isRunningOutput: Bool
    public let isRunningInput: Bool
}

public enum AudioProcesses {
    /// Every process currently registered with coreaudiod.
    public static func list() -> [AudioProcess] {
        guard let ids = try? CA.array(CA.system, kAudioHardwarePropertyProcessObjectList, AudioObjectID.self) else { return [] }
        return ids.map { id in
            AudioProcess(
                objectID: id,
                pid: (try? CA.scalar(id, kAudioProcessPropertyPID, pid_t(-1))) ?? -1,
                bundleID: CA.string(id, kAudioProcessPropertyBundleID),
                isRunningOutput: ((try? CA.scalar(id, kAudioProcessPropertyIsRunningOutput, UInt32(0))) ?? 0) != 0,
                isRunningInput: ((try? CA.scalar(id, kAudioProcessPropertyIsRunningInput, UInt32(0))) ?? 0) != 0)
        }
    }

    /// True when `bundleID` is one of `targets` or a sub-bundle of one (`com.brave.Browser.helper.renderer`
    /// belongs to `com.brave.Browser`).
    public static func matches(_ bundleID: String?, targets: [String]) -> Bool {
        guard let b = bundleID, !b.isEmpty else { return false }
        return targets.contains { b == $0 || b.hasPrefix($0 + ".") }
    }

    /// Processes of the target apps (by bundle ID).
    public static func matching(_ targets: [String]) -> [AudioProcess] {
        list().filter { matches($0.bundleID, targets: targets) }
    }

    /// Whether any process of the target apps is currently sending audio to an output device.
    public static func anyOutputRunning(_ targets: [String]) -> Bool {
        matching(targets).contains { $0.isRunningOutput }
    }
}
