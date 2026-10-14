import AVFoundation
import Darwin
import Foundation

public enum PermissionStatus: String, Sendable, Codable {
    case granted, denied, notDetermined, unknown
}

/// Permission probe, injectable so tests can model a denied TCC entry.
public protocol PermissionChecking: Sendable {
    func status(_ kind: PermissionKind) -> PermissionStatus
    /// Asks for the permission when it is not determined (shows the system prompt). Returns the new status.
    func request(_ kind: PermissionKind) async -> PermissionStatus
}

/// Real permission state.
/// - Microphone: `AVCaptureDevice.authorizationStatus(for: .audio)` (public API).
/// - System audio recording (process taps): there is no public status API, so this reads the TCC SPI
///   `TCCAccessPreflight(kTCCServiceAudioCapture)` read-only (the approach of Apple-adjacent open-source samples).
///   P0-C saw it stay `notDetermined` while the tap delivered real audio, so only an explicit `denied` is treated
///   as a denial; `notDetermined` lets the tap creation itself trigger the prompt.
public struct SystemPermissions: PermissionChecking {
    public init() {}

    public func status(_ kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        case .audioCapture:
            return TCCSPI.preflight("kTCCServiceAudioCapture")
        }
    }

    public func request(_ kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .microphone:
            let ok = await AVCaptureDevice.requestAccess(for: .audio)
            return ok ? .granted : .denied
        case .audioCapture:
            // Creating the process tap is what triggers the "System Audio Recording" prompt.
            return status(.audioCapture)
        }
    }
}

enum TCCSPI {
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    /// 0 = granted, 1 = denied, anything else = not determined.
    static func preflight(_ service: String) -> PermissionStatus {
        guard let h = handle, let sym = dlsym(h, "TCCAccessPreflight") else { return .unknown }
        let fn = unsafeBitCast(sym, to: PreflightFn.self)
        switch fn(service as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notDetermined
        }
    }
}

/// Fixed answers, for tests.
public struct FixedPermissions: PermissionChecking {
    public var audioCapture: PermissionStatus
    public var microphone: PermissionStatus

    public init(audioCapture: PermissionStatus = .granted, microphone: PermissionStatus = .granted) {
        self.audioCapture = audioCapture
        self.microphone = microphone
    }

    public func status(_ kind: PermissionKind) -> PermissionStatus {
        kind == .audioCapture ? audioCapture : microphone
    }

    public func request(_ kind: PermissionKind) async -> PermissionStatus { status(kind) }
}
