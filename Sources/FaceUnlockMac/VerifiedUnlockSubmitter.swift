import ApplicationServices
import Foundation
import FaceUnlockCore

/// Shared one-shot input for verified evidence or an explicitly opted-in experimental permit.
@MainActor
public final class VerifiedUnlockSubmitter {
    private let vault: CredentialVault
    private let input = LockScreenInput()
    private var preparedTarget: SecureInputTarget?

    public init(vault: CredentialVault) { self.vault = vault }

    public var inputDiagnostic: InputTargetDiagnostic { LockScreenInput.diagnostic }

    public func revealPasswordPrompt() throws { try input.revealPasswordPrompt() }

    public func prepareInput() throws {
        preparedTarget = nil
        preparedTarget = try input.prepareTarget()
    }

    public func clearPreparedTarget() { preparedTarget = nil }

    public func submit(attempt: inout FaceUnlockAttempt, verification: UnlockVerification,
                       isSuspended: () -> Bool) throws {
        guard !isSuspended() else { throw FaceUnlockAttemptError.session }
        defer { preparedTarget = nil }
        // Revalidate the prepared field directly if AX focus attributes are unavailable;
        // repeated tree walks must not consume the fresh match's input budget.
        let target = try input.inspectTarget(preferred: preparedTarget)
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
