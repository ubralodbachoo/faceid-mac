import AppKit
import Foundation
import FaceUnlockCore

public enum EnrollmentSessionError: Error, LocalizedError, Equatable {
    case foregroundRequired
    case assessment(SessionAssessment)

    public var errorDescription: String? {
        switch self {
        case .foregroundRequired:
            "Bring Face Unlock to the front, then start enrollment again. No enrollment was saved."
        case .assessment(.observedLocked):
            "The screen is locked. Unlock your Mac before enrolling your face."
        case .assessment(.wrongAccount):
            "The active Mac account changed. Return to the account running Face Unlock and start again."
        case .assessment(.inactive):
            "This Mac session is inactive. Return to its desktop before enrolling."
        case .assessment(.loginIncomplete):
            "macOS login is incomplete or unavailable. Finish signing in before enrolling."
        case .assessment:
            "The current Mac account/session could not be verified. Return to your desktop and try again."
        }
    }
}

/// Enrollment-only foreground gate. It never grants credential access or an unlock permit.
@MainActor
public struct MacEnrollmentSession {
    private let snapshot: () -> SessionSnapshot
    private let isForeground: () -> Bool
    private let uptime: () -> Double
    private let pause: () async throws -> Void

    public init() {
        self.init(snapshot: { MacSessionReader().read() }, isForeground: { NSApp.isActive })
    }

    init(snapshot: @escaping () -> SessionSnapshot, isForeground: @escaping () -> Bool,
         uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         pause: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }) {
        self.snapshot = snapshot; self.isForeground = isForeground
        self.uptime = uptime; self.pause = pause
    }

    public func check(requireForeground: Bool = true) throws {
        let assessment = snapshot().assessment(at: uptime())
        // A missing desktop lock flag is not evidence of an unlocked screen. This allowance
        // is limited to OS-authenticated enrollment, never password input or automatic unlocking.
        guard assessment == .unlocked || assessment == .lockUnknown else {
            throw EnrollmentSessionError.assessment(assessment)
        }
        if requireForeground && !isForeground() { throw EnrollmentSessionError.foregroundRequired }
    }

    /// Authentication/Camera prompts can finish before AppKit has restored app activation.
    /// Wait up to five seconds; no camera, commit, or bypass of account/lock checks occurs here.
    public func waitForForeground() async throws {
        for poll in 0...50 {
            try Task.checkCancellation()
            try check(requireForeground: false)
            if isForeground() { return }
            guard poll < 50 else { throw EnrollmentSessionError.foregroundRequired }
            try await pause()
        }
    }
}
