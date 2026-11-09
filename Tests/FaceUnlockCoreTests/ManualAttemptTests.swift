import XCTest
import FaceUnlockCore

final class ManualAttemptTests: XCTestCase {
    private func snapshot(lock: ScreenLockState = .locked, console: UInt32 = 501, sampledAt: Double = 10) -> SessionSnapshot {
        SessionSnapshot(processUserID: 501, consoleUserID: console, sessionUserID: 501,
                        isOnConsole: true, loginComplete: true, screenLock: lock, sampledAtUptime: sampledAt)
    }

    func testSubmissionCanOnlyBeConsumedOnceAndCannotBeReenabledAfterCancel() throws {
        var attempt = ManualAttempt(userID: 501, now: 10)
        try attempt.consume(now: 11, snapshot: snapshot(), snapshotUptime: 10.1,
                            credentialsReady: true, accessibilityGranted: true, secureFocusVerified: true)
        XCTAssertTrue(attempt.consumed)
        XCTAssertThrowsError(try attempt.consume(now: 12, snapshot: snapshot(), snapshotUptime: 10.1,
                                                credentialsReady: true, accessibilityGranted: true, secureFocusVerified: true))
        var canceled = ManualAttempt(userID: 501, now: 10)
        canceled.cancel()
        XCTAssertThrowsError(try canceled.consume(now: 11, snapshot: snapshot(), snapshotUptime: 10.1,
                                                 credentialsReady: true, accessibilityGranted: true, secureFocusVerified: true))
    }

    func testMissingLockAccountFocusPermissionOrCredentialsCannotConsumeSubmission() {
        let cases: [(SessionSnapshot, Double, Bool, Bool, Bool)] = [
            (snapshot(lock: .unknown), 10.1, true, true, true),
            (snapshot(lock: .unlocked), 10.1, true, true, true),
            (snapshot(console: 502), 10.1, true, true, true),
            (snapshot(), 11, true, true, true),
            (snapshot(), 10.1, false, true, true),
            (snapshot(), 10.1, true, false, true),
            (snapshot(), 10.1, true, true, false)
        ]
        for (snapshot, time, credentials, accessibility, focus) in cases {
            var attempt = ManualAttempt(userID: 501, now: 10)
            XCTAssertThrowsError(try attempt.consume(now: 11, snapshot: snapshot, snapshotUptime: time,
                                                    credentialsReady: credentials, accessibilityGranted: accessibility, secureFocusVerified: focus))
            XCTAssertFalse(attempt.consumed, "Preflight failure must not represent a submitted attempt")
        }
    }

    func testExpiredBackwardAndInvalidTimesCannotAuthorizeSubmission() {
        for now in [70.0, 9.0, Double.nan, .infinity] {
            var attempt = ManualAttempt(userID: 501, now: 10)
            XCTAssertThrowsError(try attempt.consume(now: now, snapshot: snapshot(), snapshotUptime: 10.1,
                                                    credentialsReady: true, accessibilityGranted: true, secureFocusVerified: true))
            XCTAssertTrue(attempt.consumed)
        }
    }

    func testCredentialLeaseExpiresWithoutBeingExtendedByClockOrSleep() {
        let lease = CredentialLease(now: 100, duration: 1000)
        XCTAssertTrue(lease.isValid(at: 189.9))
        for time in [99.0, 190, 400, .infinity, .nan] { XCTAssertFalse(lease.isValid(at: time)) }
        XCTAssertFalse(CredentialLease(now: .nan).isValid(at: 100))
    }
}
