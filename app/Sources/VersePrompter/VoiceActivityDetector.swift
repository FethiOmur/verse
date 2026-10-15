import Foundation

// Ported from Textream: Textream/VoiceActivityDetector.swift (and the detector at the end of
// TextreamiOS/Speech/VoiceActivityDetector.swift), upstream commit 2c02f3e.
// MIT License, Copyright (c) 2026 Fatih Kadir Akin. Full text: THIRD_PARTY_NOTICES at the repo root.
// Levels are linear RMS (0...1) as Double instead of CGFloat; the numbers are Textream's.

public struct VoiceActivityDetector: Sendable {
    private let activationLevel: Double
    private let immediateActivationLevel: Double
    private let requiredActiveFrames: Int
    private let hangoverDuration: TimeInterval
    private var consecutiveActiveFrames = 0
    private var activeUntil = -TimeInterval.infinity

    public init(
        activationLevel: Double = 0.012,
        immediateActivationLevel: Double = 0.04,
        requiredActiveFrames: Int = 2,
        hangoverDuration: TimeInterval = 0.75
    ) {
        self.activationLevel = activationLevel
        self.immediateActivationLevel = immediateActivationLevel
        self.requiredActiveFrames = requiredActiveFrames
        self.hangoverDuration = hangoverDuration
    }

    public mutating func process(level: Double, at timestamp: TimeInterval) {
        if level >= immediateActivationLevel {
            consecutiveActiveFrames = requiredActiveFrames
            extendActivity(at: timestamp)
        } else if level >= activationLevel {
            consecutiveActiveFrames += 1
            if consecutiveActiveFrames >= requiredActiveFrames {
                extendActivity(at: timestamp)
            }
        } else {
            consecutiveActiveFrames = 0
        }
    }

    public func isActive(at timestamp: TimeInterval) -> Bool { timestamp < activeUntil }

    /// End of the current activity window (`-infinity` before any speech).
    public var activeUntilTime: TimeInterval { activeUntil }

    public mutating func reset() {
        consecutiveActiveFrames = 0
        activeUntil = -TimeInterval.infinity
    }

    private mutating func extendActivity(at timestamp: TimeInterval) {
        activeUntil = max(activeUntil, timestamp + hangoverDuration)
    }
}
