import CoreGraphics
import Foundation
import XCTest
import AppKit
import FaceUnlockCore
@testable import FaceUnlockMac

final class SessionTests: XCTestCase {
    private func snapshot(
        console: UInt32? = 501, session: UInt32? = 501, active: Bool? = true,
        loggedIn: Bool? = true, lock: ScreenLockState = .locked
    ) -> SessionSnapshot {
        SessionSnapshot(
            processUserID: 501, consoleUserID: console, sessionUserID: session,
            isOnConsole: active, loginComplete: loggedIn, screenLock: lock, sampledAtUptime: 100
        )
    }

    func testLockedReportRequiresFreshMatchingActiveAccountAndCompleteLogin() {
        XCTAssertEqual(snapshot().assessment(at: 101), .observedLocked)
        XCTAssertEqual(snapshot(console: nil).assessment(at: 101), .unknown)
        XCTAssertEqual(snapshot(session: nil).assessment(at: 101), .unknown)
        XCTAssertEqual(snapshot(console: 502).assessment(at: 101), .wrongAccount)
        XCTAssertEqual(snapshot(session: 502).assessment(at: 101), .wrongAccount)
        XCTAssertEqual(snapshot(active: false).assessment(at: 101), .inactive)
        XCTAssertEqual(snapshot(active: nil).assessment(at: 101), .unknown)
        XCTAssertEqual(snapshot(loggedIn: false).assessment(at: 101), .loginIncomplete)
        XCTAssertEqual(snapshot(loggedIn: nil).assessment(at: 101), .loginIncomplete)
        XCTAssertEqual(snapshot(lock: .unknown).assessment(at: 101), .lockUnknown)
        XCTAssertEqual(snapshot(lock: .unlocked).assessment(at: 101), .unlocked)
    }

    func testStaleFutureAndNonFiniteObservationsAreRejected() {
        for time in [103.0, 99.0, .nan, .infinity] {
            XCTAssertEqual(snapshot().assessment(at: time), .stale)
        }
        XCTAssertEqual(snapshot().assessment(at: 100, maximumAge: -1), .stale)
        XCTAssertEqual(snapshot().assessment(at: 100, maximumAge: .infinity), .stale)
        let invalid = SessionSnapshot(processUserID: 501, sampledAtUptime: .nan)
        XCTAssertEqual(invalid.assessment(at: 100), .stale)
    }

    func testMissingAndMalformedLockFlagsRemainUnknown() {
        for value: Any? in [nil, "true", 1, 0, NSNull()] {
            var fields = validFields
            fields["CGSSessionScreenIsLocked"] = value
            let report = parse(fields)
            XCTAssertEqual(report.screenLock, .unknown)
            XCTAssertEqual(report.assessment(at: 101), .lockUnknown)
        }
        var fields = validFields
        fields["CGSSessionScreenIsLocked"] = false
        XCTAssertEqual(parse(fields).assessment(at: 101), .unlocked)
        fields["CGSSessionScreenIsLocked"] = true
        XCTAssertEqual(parse(fields).assessment(at: 101), .observedLocked)
    }

    func testMalformedAccountAndActivityFieldsCannotProduceLockedAssessment() {
        for value: Any in ["501", true, -1, 501.5, Double.infinity, Double(UInt32.max) + 1] {
            var fields = validFields
            fields[kCGSessionUserIDKey as String] = value
            XCTAssertEqual(parse(fields).assessment(at: 101), .unknown)
        }
        var fields = validFields
        fields[kCGSessionOnConsoleKey as String] = 1
        XCTAssertEqual(parse(fields).assessment(at: 101), .unknown)
        fields = validFields
        fields[kCGSessionLoginDoneKey as String] = "true"
        XCTAssertEqual(parse(fields).assessment(at: 101), .loginIncomplete)
        XCTAssertEqual(parse([:]).assessment(at: 101), .unknown)
    }

    @MainActor
    func testStoppingMonitorInvalidatesPreviousObservation() {
        let monitor = MacSessionMonitor()
        monitor.start()
        monitor.stop()
        XCTAssertNil(monitor.snapshot.consoleUserID)
        XCTAssertEqual(monitor.snapshot.screenLock, .unknown)
        XCTAssertEqual(monitor.lastEvent, "Observation stopped")
    }

    @MainActor
    func testSleepAndInactiveSessionPreventResamplingUntilTheirMatchingResumeEvents() {
        let monitor = MacSessionMonitor()
        monitor.start()
        defer { monitor.stop() }
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        monitor.refresh()
        XCTAssertNil(monitor.snapshot.consoleUserID)
        XCTAssertEqual(monitor.lastEvent, "System will sleep")
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        monitor.refresh()
        XCTAssertNil(monitor.snapshot.consoleUserID, "Wake alone must not reactivate an inactive session")
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertEqual(monitor.snapshot.screenLock, .unknown, "Resume first invalidates; it cannot reuse a locked result")
        XCTAssertEqual(monitor.lastEvent, "Session became active")
    }

    private var validFields: [String: Any] { [
        kCGSessionUserIDKey as String: 501,
        kCGSessionOnConsoleKey as String: true,
        kCGSessionLoginDoneKey as String: true,
        "CGSSessionScreenIsLocked": true
    ] }

    private func parse(_ fields: [String: Any]) -> SessionSnapshot {
        SessionDictionaryParser.snapshot(fields: fields, processUserID: 501, consoleUserID: 501, uptime: 100)
    }
}
