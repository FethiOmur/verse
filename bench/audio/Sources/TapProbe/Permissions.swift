import AVFoundation
import Darwin
import Foundation

/// Private TCC SPI, used read-only for diagnosis (same approach as the open-source AudioCap sample).
/// TCCAccessPreflight: 0 = granted, 1 = denied, other = not determined.
enum TCC {
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static func preflight(_ service: String) -> String {
        guard let h = handle, let sym = dlsym(h, "TCCAccessPreflight") else { return "unavailable" }
        let fn = unsafeBitCast(sym, to: PreflightFn.self)
        switch fn(service as CFString, nil) {
        case 0: return "granted"
        case 1: return "denied"
        default: return "not_determined"
        }
    }

    /// Triggers the system prompt (attributed to the responsible app) and waits up to `timeout` seconds.
    static func request(_ service: String, timeout: Double) -> String {
        guard let h = handle, let sym = dlsym(h, "TCCAccessRequest") else { return "unavailable" }
        let fn = unsafeBitCast(sym, to: RequestFn.self)
        let sem = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var v: Bool? }
        let box = Box()
        fn(service as CFString, nil) { granted in box.v = granted; sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut { return "timeout" }
        return box.v == true ? "granted" : "denied"
    }
}

func micAuthorization() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "not_determined"
    @unknown default: return "unknown"
    }
}

/// The app TCC attributes this process to (walks up to the first ancestor inside a .app bundle).
func responsibleAppGuess() -> String {
    var pid = getpid()
    var last = ""
    for _ in 0..<12 {
        if let p = processPath(pid), let r = p.range(of: ".app/") { last = String(p[..<r.upperBound].dropLast()) }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        if sysctl(&mib, 4, &info, &size, nil, 0) != 0 { break }
        let ppid = info.kp_eproc.e_ppid
        if ppid <= 1 { break }
        pid = ppid
        if !last.isEmpty { break }
    }
    return last.isEmpty ? "unknown" : last
}
