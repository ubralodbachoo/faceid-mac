import Foundation
import XCTest
import FaceUnlockCore
@testable import FaceUnlockMac

final class EnrollmentSessionTests: XCTestCase {
    private func snapshot(console: UInt32? = 501, session: UInt32? = 501,
                          active: Bool? = true, login: Bool? = true,
                          lock: ScreenLockState = .unknown, time: Double = 100) -> SessionSnapshot {
        SessionSnapshot(processUserID: 501, consoleUserID: console, sessionUserID: session,
                        isOnConsole: active, loginComplete: login, screenLock: lock, sampledAtUptime: time)
    }

    @MainActor
    func testPromptCompletionWaitsForAppActivationInsteadOfReportingExpiredLease() async throws {
        var foreground = false
        var polls = 0
        let gate = MacEnrollmentSession(snapshot: { self.snapshot() }, isForeground: { foreground }, uptime: { 100 }, pause: {
            polls += 1
            if polls == 3 { foreground = true }
        })
        XCTAssertThrowsError(try gate.check()) { error in
            XCTAssertEqual(error as? EnrollmentSessionError, .foregroundRequired)
        }
        try await gate.waitForForeground()
        XCTAssertEqual(polls, 3)
        XCTAssertNoThrow(try gate.check())
    }

    @MainActor
    func testForegroundWaitIsBoundedAndDoesNotActivateAppItself() async throws {
        var polls = 0
        let gate = MacEnrollmentSession(snapshot: { self.snapshot() }, isForeground: { false }, uptime: { 100 }, pause: { polls += 1 })
        do { try await gate.waitForForeground(); XCTFail("Must not continue in background") }
        catch { XCTAssertEqual(error as? EnrollmentSessionError, .foregroundRequired) }
        XCTAssertEqual(polls, 50)
    }

    @MainActor
    func testLockOrAccountChangeDuringPromptReturnStillRejectsEnrollment() async throws {
        for lock in [false, true] {
            var changed = false
            var polls = 0
            let gate = MacEnrollmentSession(snapshot: {
                if !changed { return self.snapshot() }
                return lock ? self.snapshot(lock: .locked) : self.snapshot(console: 502)
            }, isForeground: { changed }, uptime: { 100 }, pause: { changed = true; polls += 1 })
            do { try await gate.waitForForeground(); XCTFail("Session change must stop the wait") }
            catch { XCTAssertEqual(error as? EnrollmentSessionError, .assessment(lock ? .observedLocked : .wrongAccount)) }
            XCTAssertEqual(polls, 1)
        }
    }

    @MainActor
    func testUnknownInactiveStaleAndIncompleteSessionsCannotWaitOrCapture() async throws {
        let cases: [(SessionSnapshot, SessionAssessment)] = [
            (snapshot(console: nil), .unknown), (snapshot(session: 502), .wrongAccount),
            (snapshot(active: false), .inactive), (snapshot(login: false), .loginIncomplete),
            (snapshot(time: 90), .stale), (snapshot(lock: .locked), .observedLocked)
        ]
        for (snapshot, assessment) in cases {
            let gate = MacEnrollmentSession(snapshot: { snapshot }, isForeground: { true }, uptime: { 100 }, pause: { XCTFail("Do not wait on an invalid session") })
            do { try await gate.waitForForeground(); XCTFail("Invalid session") }
            catch { XCTAssertEqual(error as? EnrollmentSessionError, .assessment(assessment)) }
            XCTAssertThrowsError(try gate.check())
        }
    }

    @MainActor
    func testForegroundLossDuringCaptureRejectsImmediatelyWithoutPromptGrace() {
        var foreground = true
        let gate = MacEnrollmentSession(snapshot: { self.snapshot(lock: .unlocked) }, isForeground: { foreground }, uptime: { 100 })
        XCTAssertNoThrow(try gate.check())
        foreground = false
        XCTAssertThrowsError(try gate.check()) { error in XCTAssertEqual(error as? EnrollmentSessionError, .foregroundRequired) }
    }

    @MainActor
    func testCancellationDuringPromptReturnCannotContinue() async throws {
        let gate = MacEnrollmentSession(snapshot: { self.snapshot() }, isForeground: { false }, uptime: { 100 }, pause: { throw CancellationError() })
        do { try await gate.waitForForeground(); XCTFail("Canceled wait") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
