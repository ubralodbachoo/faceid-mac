import ApplicationServices
import Foundation
import FaceUnlockCore

/// Shared one-shot input for verified evidence or an explicitly opted-in experimental permit.
@MainActor
public struct VerifiedUnlockSubmitter {
    private let vault: CredentialVault
    private let input = LockScreenInput()

    public init(vault: CredentialVault) { self.vault = vault }

    public func prepareInput() throws { try input.prepareTarget() }

    public func submit(attempt: inout FaceUnlockAttempt, verification: UnlockVerification,
                       isSuspended: () -> Bool) throws {
        guard !isSuspended() else { throw FaceUnlockAttemptError.session }
        let target = try input.inspectTarget()
        let snapshot = MacSessionReader().read()
        let uptime = ProcessInfo.processInfo.systemUptime
        try attempt.consume(now: ContinuousTime.now, verification: verification,
                            snapshot: snapshot, uptime: uptime,
                            credentialsReady: vault.sessionIsValid && vault.hasCredential,
                            focusVerified: AXIsProcessTrusted())
        let consumedAttempt = attempt
        try vault.withPassword { data in
            try input.submit(data, to: target) {
                let time = ContinuousTime.now
                guard consumedAttempt.consumed, time >= verification.observedAt,
                      time - verification.observedAt <= FaceUnlockAttempt.evidenceMaximumAge,
                      time < consumedAttempt.expiresAt,
                      let scanStart = consumedAttempt.scanStartedAt,
                      time - scanStart < FaceUnlockAttempt.scanDuration,
                      !isSuspended(), vault.sessionIsValid else { return false }
                return (try? consumedAttempt.checkSession(MacSessionReader().read(),
                    uptime: ProcessInfo.processInfo.systemUptime)) != nil
            }
        }
    }
}
