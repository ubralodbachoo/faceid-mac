import Foundation

/// Authentication evidence is separate from the experimental comparison score.
/// Experimental comparison matches remain distinct from calibrated identity/PAD verification.
public enum UnlockCheck: Sendable { case verified, experimentalMatch, rejected, unavailable }

public enum UnlockAuthorizationPolicy: Sendable {
    case verifiedBiometrics
    /// Requires explicit owner opt-in; photos/video may unlock. Never claims verified liveness.
    case experimentalSimilarity
}

public struct UnlockVerification: Sendable {
    public let attemptID: UUID
    public let identity: UnlockCheck
    public let liveness: UnlockCheck
    public let observedAt: Double

    public init(attemptID: UUID, identity: UnlockCheck, liveness: UnlockCheck, observedAt: Double) {
        self.attemptID = attemptID; self.identity = identity
        self.liveness = liveness; self.observedAt = observedAt
    }
}

public enum FaceUnlockAttemptError: Error, LocalizedError, Equatable {
    case expired, consumed, session, identity, liveness, staleEvidence, credentials, focus

    public var errorDescription: String? {
        switch self {
        case .expired: "The lock-screen test expired. Return to Face Unlock to arm another test."
        case .consumed: "This lock-screen attempt has already been used or canceled."
        case .session: "The locked Mac account could not be verified. Use password or Touch ID."
        case .identity: "Identity verification is unavailable or did not pass. Use password or Touch ID."
        case .liveness: "Liveness is not verified. Use password or Touch ID."
        case .staleEvidence: "Verification is stale or belongs to another attempt. No password was entered."
        case .credentials: "The authorized credential session is unavailable. No password was entered."
        case .focus: "The loginwindow password field could not be verified. No password was entered."
        }
    }
}

/// One explicit arm, one locked scan, at most one submission. No timer can renew this permit.
public struct FaceUnlockAttempt {
    public let id = UUID()
    public let userID: UInt32
    public let policy: UnlockAuthorizationPolicy
    public let issuedAt: Double
    public let expiresAt: Double
    public private(set) var scanStartedAt: Double?
    public private(set) var consumed = false
    public static let scanDuration = 15.0
    public static let evidenceMaximumAge = 0.75

    public init(userID: UInt32, now: Double, policy: UnlockAuthorizationPolicy = .verifiedBiometrics) {
        self.userID = userID; self.policy = policy; issuedAt = now; expiresAt = now + 60
    }

    public func checkTime(_ now: Double) throws {
        guard !consumed else { throw FaceUnlockAttemptError.consumed }
        guard issuedAt.isFinite, issuedAt >= 0, now.isFinite, now >= issuedAt, now < expiresAt,
              scanStartedAt.map({ now >= $0 && now - $0 < Self.scanDuration }) ?? true else {
            throw FaceUnlockAttemptError.expired
        }
    }

    public mutating func beginScan(now: Double, snapshot: SessionSnapshot, uptime: Double) throws {
        try checkTime(now)
        guard scanStartedAt == nil else { throw FaceUnlockAttemptError.consumed }
        try checkSession(snapshot, uptime: uptime)
        scanStartedAt = now
    }

    public func checkSession(_ snapshot: SessionSnapshot, uptime: Double) throws {
        guard snapshot.processUserID == userID,
              snapshot.assessment(at: uptime, maximumAge: 0.5) == .observedLocked else {
            throw FaceUnlockAttemptError.session
        }
    }

    public mutating func consume(now: Double, verification: UnlockVerification,
                                 snapshot: SessionSnapshot, uptime: Double,
                                 credentialsReady: Bool, focusVerified: Bool) throws {
        try checkTime(now)
        try checkSession(snapshot, uptime: uptime)
        guard let scanStartedAt, verification.attemptID == id,
              verification.observedAt.isFinite, verification.observedAt >= scanStartedAt,
              verification.observedAt <= now, now - verification.observedAt <= Self.evidenceMaximumAge else {
            throw FaceUnlockAttemptError.staleEvidence
        }
        switch policy {
        case .verifiedBiometrics:
            guard verification.identity == .verified else { throw FaceUnlockAttemptError.identity }
            guard verification.liveness == .verified else { throw FaceUnlockAttemptError.liveness }
        case .experimentalSimilarity:
            guard verification.identity == .experimentalMatch || verification.identity == .verified else {
                throw FaceUnlockAttemptError.identity
            }
            guard verification.liveness != .rejected else { throw FaceUnlockAttemptError.liveness }
        }
        guard credentialsReady else { throw FaceUnlockAttemptError.credentials }
        guard focusVerified else { throw FaceUnlockAttemptError.focus }
        // Commit before reading the password or delivering the first keyboard event.
        consumed = true
    }

    public mutating func cancel() { consumed = true }
}
