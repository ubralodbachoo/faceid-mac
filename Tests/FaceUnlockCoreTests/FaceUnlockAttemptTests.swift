import Foundation
import XCTest
import FaceUnlockCore

final class FaceUnlockAttemptTests: XCTestCase {
    private func snapshot(lock: ScreenLockState = .locked, console: UInt32 = 501, sampled: Double = 10) -> SessionSnapshot {
        SessionSnapshot(processUserID: 501, consoleUserID: console, sessionUserID: 501,
            isOnConsole: true, loginComplete: true, screenLock: lock, sampledAtUptime: sampled)
    }

    private func scanning() throws -> FaceUnlockAttempt {
        var attempt = FaceUnlockAttempt(userID: 501, now: 100)
        try attempt.beginScan(now: 101, snapshot: snapshot(), uptime: 10)
        return attempt
    }

    private func consume(_ attempt: inout FaceUnlockAttempt, identity: UnlockCheck = .verified,
                         liveness: UnlockCheck = .verified, evidenceTime: Double = 101.9,
                         attemptID: UUID? = nil, now: Double = 102,
                         snapshot: SessionSnapshot? = nil, credentials: Bool = true, focus: Bool = true) throws {
        try attempt.consume(now: now,
            verification: UnlockVerification(attemptID: attemptID ?? attempt.id, identity: identity,
                                             liveness: liveness, observedAt: evidenceTime),
            snapshot: snapshot ?? self.snapshot(), uptime: 10,
            credentialsReady: credentials, focusVerified: focus)
    }

    func testVerifiedEvidenceIsSingleUseAndCannotBeRearmed() throws {
        var attempt = try scanning()
        try consume(&attempt)
        XCTAssertTrue(attempt.consumed)
        XCTAssertThrowsError(try consume(&attempt))
        XCTAssertThrowsError(try attempt.beginScan(now: 103, snapshot: snapshot(), uptime: 10))
        var canceled = try scanning()
        canceled.cancel()
        XCTAssertThrowsError(try consume(&canceled))
    }

    func testIdentityAndLivenessMustBothBeIndependentlyVerified() throws {
        let cases: [(UnlockCheck, UnlockCheck)] = [(.unavailable, .verified), (.rejected, .verified),
                                                  (.verified, .unavailable), (.verified, .rejected)]
        for (identity, liveness) in cases {
            var attempt = try scanning()
            XCTAssertThrowsError(try consume(&attempt, identity: identity, liveness: liveness))
            XCTAssertFalse(attempt.consumed)
        }
    }

    func testForeignStaleFutureOrPreScanEvidenceCannotAuthorizeInput() throws {
        for time in [100.9, 101.0, 102.1, .nan, .infinity] {
            var attempt = try scanning()
            XCTAssertThrowsError(try consume(&attempt, evidenceTime: time))
        }
        var attempt = try scanning()
        XCTAssertThrowsError(try consume(&attempt, attemptID: UUID()))
    }

    func testFreshAccountLockFocusAndCredentialsAreRequiredAtConsumption() throws {
        for observed in [snapshot(lock: .unknown), snapshot(lock: .unlocked), snapshot(console: 502), snapshot(sampled: 8)] {
            var attempt = try scanning()
            XCTAssertThrowsError(try consume(&attempt, snapshot: observed))
        }
        var attempt = try scanning()
        XCTAssertThrowsError(try consume(&attempt, credentials: false))
        XCTAssertThrowsError(try consume(&attempt, focus: false))
        XCTAssertFalse(attempt.consumed)
    }

    func testScanDeadlineAndArmDeadlineCannotBeExtendedByAnotherTrigger() throws {
        var attempt = try scanning()
        XCTAssertNoThrow(try attempt.checkTime(115.99))
        XCTAssertThrowsError(try attempt.beginScan(now: 110, snapshot: snapshot(), uptime: 10))
        XCTAssertThrowsError(try consume(&attempt, evidenceTime: 116, now: 116))
        var waiting = FaceUnlockAttempt(userID: 501, now: 100)
        XCTAssertThrowsError(try waiting.beginScan(now: 160, snapshot: snapshot(), uptime: 10))
        for time in [99.0, .nan, .infinity] { XCTAssertThrowsError(try waiting.checkTime(time)) }
    }

    func testCannotConsumeWithoutLockedScanOrWithInvalidIssueTime() throws {
        var attempt = FaceUnlockAttempt(userID: 501, now: 100)
        XCTAssertThrowsError(try consume(&attempt))
        XCTAssertThrowsError(try attempt.beginScan(now: 101, snapshot: snapshot(lock: .unknown), uptime: 10))
        XCTAssertNil(attempt.scanStartedAt)
        var invalid = FaceUnlockAttempt(userID: 501, now: .nan)
        XCTAssertThrowsError(try invalid.beginScan(now: 101, snapshot: snapshot(), uptime: 10))
    }

    func testExperimentalEvidenceRequiresAnExplicitlyExperimentalPermit() throws {
        var verifiedPermit = try scanning()
        XCTAssertThrowsError(try consume(&verifiedPermit, identity: .experimentalMatch, liveness: .unavailable))
        var experimental = FaceUnlockAttempt(userID: 501, now: 100, policy: .experimentalSimilarity)
        try experimental.beginScan(now: 101, snapshot: snapshot(), uptime: 10)
        try consume(&experimental, identity: .experimentalMatch, liveness: .unavailable)
        XCTAssertTrue(experimental.consumed)
        XCTAssertThrowsError(try consume(&experimental, identity: .experimentalMatch, liveness: .unavailable))
    }

    func testExperimentalPolicyKeepsSessionFreshnessFocusCredentialAndDenyGates() throws {
        for scenario in 0..<7 {
            var attempt = FaceUnlockAttempt(userID: 501, now: 100, policy: .experimentalSimilarity)
            try attempt.beginScan(now: 101, snapshot: snapshot(), uptime: 10)
            XCTAssertThrowsError(try consume(&attempt,
                identity: scenario == 0 ? .unavailable : .experimentalMatch,
                liveness: scenario == 1 ? .rejected : .unavailable,
                evidenceTime: scenario == 2 ? 101 : 101.9,
                attemptID: scenario == 3 ? UUID() : nil,
                snapshot: scenario == 4 ? snapshot(console: 502) : nil,
                credentials: scenario != 5, focus: scenario != 6))
            XCTAssertFalse(attempt.consumed)
        }
    }
}
