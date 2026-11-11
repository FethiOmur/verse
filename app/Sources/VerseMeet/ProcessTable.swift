import CoreAudio
import Darwin
import Foundation

/// One process as coreaudiod knows it. Only flags are read, never audio.
public struct AudioProcessInfo: Sendable, Equatable {
    public var bundleID: String?
    public var pid: Int32
    public var isRunningInput: Bool
    public var isRunningOutput: Bool
    /// For a shared helper (a `com.apple.WebKit.*` XPC service): the bundle ID of the app it works for. Every WKWebView
    /// app (Mail, any web-view app) has its own `com.apple.WebKit.GPU`, so the helper's own ID does not say which app is
    /// recording. nil: not a helper, or unknown.
    public var responsibleBundleID: String?

    public init(bundleID: String?, pid: Int32 = 0, isRunningInput: Bool = false, isRunningOutput: Bool = false,
                responsibleBundleID: String? = nil) {
        self.bundleID = bundleID
        self.pid = pid
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
        self.responsibleBundleID = responsibleBundleID
    }
}

/// The app a helper process works for, through the system's responsibility record (the pid macOS charges for the
/// helper's privacy access; the same record that names the app in the microphone indicator).
enum ResponsibleApp {
    private typealias Lookup = @convention(c) (pid_t) -> pid_t
    private static let lookup: Lookup? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: Lookup.self)
    }()

    /// The bundle ID of the app responsible for `pid`; nil when it cannot be told (no lookup, gone, not in an .app).
    static func bundleID(for pid: pid_t) -> String? {
        guard pid > 0, let lookup else { return nil }
        let owner = lookup(pid)
        guard owner > 0, owner != pid else { return nil }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(owner, &buf, UInt32(buf.count)) > 0 else { return nil }
        return bundleID(forExecutablePath: String(cString: buf))
    }

    /// The outermost `.app` on the path, read as a bundle.
    static func bundleID(forExecutablePath path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        var app: URL?
        while url.pathComponents.count > 1 {
            if url.pathExtension == "app" { app = url }
            url.deleteLastPathComponent()
        }
        return app.flatMap { Bundle(url: $0)?.bundleIdentifier }
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
            let bundleID = Self.string(id, kAudioProcessPropertyBundleID)
            let pid = Self.scalar(id, kAudioProcessPropertyPID, pid_t(-1))
            let input = Self.scalar(id, kAudioProcessPropertyIsRunningInput, UInt32(0)) != 0
            // Only a recording helper is worth the lookup (one per poll at most, in practice).
            let helper = input && MeetingApp.isSharedHelper(bundleID)
            return AudioProcessInfo(
                bundleID: bundleID,
                pid: pid,
                isRunningInput: input,
                isRunningOutput: Self.scalar(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) != 0,
                responsibleBundleID: helper ? ResponsibleApp.bundleID(for: pid) : nil)
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
