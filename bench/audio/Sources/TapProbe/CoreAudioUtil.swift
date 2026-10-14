import CoreAudio
import Darwin
import Foundation

struct CAError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus
    var description: String { "\(what) failed: OSStatus \(status) (\(fourCC(status)))" }
}

func fourCC(_ s: OSStatus) -> String {
    let u = UInt32(bitPattern: s)
    let bytes = [UInt8((u >> 24) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 8) & 0xff), UInt8(u & 0xff)]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return "'" + String(decoding: bytes, as: UTF8.self) + "'" }
    return String(s)
}

@inline(__always) func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CAError(what: what, status: status) }
}

func addr(_ sel: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: element)
}

func getArray<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ type: T.Type) throws -> [T] {
    var a = addr(sel)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size), "GetPropertyDataSize \(sel)")
    let count = Int(size) / MemoryLayout<T>.stride
    if count == 0 { return [] }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    defer { buf.deallocate() }
    try check(AudioObjectGetPropertyData(obj, &a, 0, nil, &size, buf), "GetPropertyData \(sel)")
    let typed = buf.bindMemory(to: T.self, capacity: count)
    return Array(UnsafeBufferPointer(start: typed, count: count))
}

func getScalar<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T,
                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
    var a = addr(sel, scope)
    var v = initial
    var size = UInt32(MemoryLayout<T>.size)
    try check(AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v), "GetPropertyData \(sel)")
    return v
}

func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = addr(sel)
    var s: Unmanaged<CFString>? = nil
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &s)
    guard st == noErr, let v = s else { return nil }
    return v.takeRetainedValue() as String
}

struct AudioProcessInfo: Codable {
    let objectID: UInt32
    let pid: Int32
    let bundleID: String?
    let path: String?
    let isRunning: Bool
    let isRunningOutput: Bool
    let isRunningInput: Bool
}

func processPath(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    if n <= 0 { return nil }
    return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// All processes currently registered with coreaudiod.
func listAudioProcesses() throws -> [AudioProcessInfo] {
    let ids = try getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, AudioObjectID.self)
    return ids.map { id in
        let pid = (try? getScalar(id, kAudioProcessPropertyPID, pid_t(-1))) ?? -1
        let running = ((try? getScalar(id, kAudioProcessPropertyIsRunning, UInt32(0))) ?? 0) != 0
        let out = ((try? getScalar(id, kAudioProcessPropertyIsRunningOutput, UInt32(0))) ?? 0) != 0
        let inp = ((try? getScalar(id, kAudioProcessPropertyIsRunningInput, UInt32(0))) ?? 0) != 0
        return AudioProcessInfo(objectID: id, pid: pid, bundleID: getString(id, kAudioProcessPropertyBundleID),
                                path: pid > 0 ? processPath(pid) : nil,
                                isRunning: running, isRunningOutput: out, isRunningInput: inp)
    }
}

struct OSProcess: Codable {
    let pid: Int32
    let path: String
}

/// Every OS process whose executable lives inside `<appName>.app` (main app plus helpers).
func osProcesses(ofApp appName: String) -> [OSProcess] {
    // Chromium browsers run the main process from a code-sign clone: .../<App>.app.bundle/Contents/MacOS/...
    let needles = ["/\(appName).app/", "/\(appName).app.bundle/"]
    var count = proc_listallpids(nil, 0)
    if count <= 0 { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    var out: [OSProcess] = []
    for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
        if let p = processPath(pid), needles.contains(where: { p.contains($0) }) { out.append(OSProcess(pid: pid, path: p)) }
    }
    return out.sorted { $0.pid < $1.pid }
}

func defaultOutputDeviceUID() throws -> String {
    let dev = try getScalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
    guard let uid = getString(dev, kAudioDevicePropertyDeviceUID) else { throw CAError(what: "default output UID", status: -1) }
    return uid
}

func defaultOutputDeviceName() -> String? {
    guard let dev = try? getScalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)) else { return nil }
    return getString(dev, kAudioObjectPropertyName)
}

// MARK: host time

let timebase: mach_timebase_info_data_t = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return tb
}()

@inline(__always) func hostToSeconds(_ t: UInt64) -> Double {
    Double(t) * Double(timebase.numer) / Double(timebase.denom) / 1e9
}

@inline(__always) func nowSeconds() -> Double { hostToSeconds(mach_absolute_time()) }
