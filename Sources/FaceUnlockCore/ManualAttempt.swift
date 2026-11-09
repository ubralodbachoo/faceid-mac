import Foundation

public enum ManualAttemptError: Error, LocalizedError {
    case expired, alreadyConsumed, wrongAccount, sessionNotLocked, sessionUnavailable, credentialsUnavailable, focusUnverified

    public var errorDescription: String? {
        switch self {
        case .expired: "The one-shot test expired. Arm a new test."
        case .alreadyConsumed: "This test has already been used or canceled."
        case .wrongAccount: "The current account does not match the armed test."
        case .sessionNotLocked: "The session is not explicitly reported locked."
        case .sessionUnavailable: "The session observation is missing, stale, or inactive."
        case .credentialsUnavailable: "The credential session or required permission is unavailable."
        case .focusUnverified: "A focused loginwindow secure password field could not be verified."
        }
    }
}

/// Single-use manual experiment only. Never used as a biometric authorization.
public struct ManualAttempt {
    public let expectedUserID: UInt32
    public let deadline: Double
    private let issuedAt: Double
    public private(set) var consumed = false

    public init(userID: UInt32, now: Double, duration: Double = 60) {
        expectedUserID = userID
        issuedAt = now
        deadline = now + min(max(duration, 0), 60)
    }

    public mutating func cancel() { consumed = true }

    public mutating func consume(
        now: Double, snapshot: SessionSnapshot, snapshotUptime: Double,
        credentialsReady: Bool, accessibilityGranted: Bool, secureFocusVerified: Bool
    ) throws {
        guard !consumed else { throw ManualAttemptError.alreadyConsumed }
        guard now.isFinite, now >= issuedAt, issuedAt >= 0, deadline.isFinite, now < deadline else {
            consumed = true
            throw ManualAttemptError.expired
        }
        guard snapshot.processUserID == expectedUserID else { throw ManualAttemptError.wrongAccount }
        switch snapshot.assessment(at: snapshotUptime, maximumAge: 0.5) {
        case .observedLocked: break
        case .wrongAccount: throw ManualAttemptError.wrongAccount
        case .unlocked, .lockUnknown: throw ManualAttemptError.sessionNotLocked
        default: throw ManualAttemptError.sessionUnavailable
        }
        guard credentialsReady, accessibilityGranted else { throw ManualAttemptError.credentialsUnavailable }
        guard secureFocusVerified else { throw ManualAttemptError.focusUnverified }
        // Consume BEFORE reading plaintext or sending the first event. Failure never retries.
        consumed = true
    }
}

public struct CredentialLease {
    public let expiresAt: Double
    private let issuedAt: Double

    public init(now: Double, duration: Double = 90) {
        issuedAt = now
        expiresAt = now + min(max(duration, 0), 90)
    }

    public func isValid(at now: Double) -> Bool {
        now.isFinite && issuedAt.isFinite && expiresAt.isFinite && issuedAt >= 0
            && now >= issuedAt && now < expiresAt
    }
}
