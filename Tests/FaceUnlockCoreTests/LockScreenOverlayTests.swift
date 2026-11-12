import AppKit
import XCTest
@testable import FaceUnlockApp

final class LockScreenOverlayTests: XCTestCase {
    @MainActor
    func testOptInNativeDesktopBridgeCanBePreparedBeforeLock() throws {
        guard ProcessInfo.processInfo.environment["FACEUNLOCK_TEST_WINDOW_BRIDGE"] == "1" else {
            throw XCTSkip("Native WindowServer bridge check is opt-in")
        }
        _ = NSApplication.shared
        LockScreenWindowBridge.prepare()
        let bridge = try XCTUnwrap(LockScreenWindowBridge.shared, LockScreenWindowBridge.initializationFailure ?? "Bridge unavailable")
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { bridge.detach(panel); panel.close() }
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(bridge.moveToOverlaySpace(windowNumber: panel.windowNumber), bridge.lastAttachmentFailure ?? "WindowServer must report actual space membership")
        XCTAssertFalse(panel.isVisible, "The native check must not display a window")
    }

    @MainActor
    func testFailedBridgeInitializationRetriesAndSuccessfulPreparationIsReused() {
        var cache = LockScreenBridgeCache<Int>()
        var attempts = 0
        func create() -> Int? { attempts += 1; return attempts == 1 ? nil : 42 }
        XCTAssertNil(cache.resolve(at: 10, create: create))
        XCTAssertNil(cache.resolve(at: 10.2, create: create))
        XCTAssertEqual(attempts, 1, "Do not hammer WindowServer on every overlay tick")
        XCTAssertEqual(cache.resolve(at: 11, create: create), 42)
        XCTAssertEqual(cache.resolve(at: 20, create: create), 42)
        XCTAssertEqual(attempts, 2, "A prepared desktop bridge is reused on the lock screen")
    }

    @MainActor
    func testEachRefreshOrdersThenReattachesEvenAfterEarlierSuccess() {
        var delivery = LockScreenOverlayDelivery()
        var events: [String] = []
        for _ in 0..<3 {
            delivery.refresh(locked: true, orderFront: { events.append("front") },
                attach: { events.append("attach"); return true }, detach: { events.append("detach") })
        }
        XCTAssertEqual(events, ["front", "attach", "front", "attach", "front", "attach"])
        XCTAssertTrue(delivery.delegated)
        delivery.hide(detach: { events.append("detach") }, orderOut: { events.append("out") })
        XCTAssertEqual(Array(events.suffix(2)), ["detach", "out"])
        XCTAssertFalse(delivery.delegated)
    }

    @MainActor
    func testFailedAttachmentRetriesAndUnlockDetachesWithoutReattaching() {
        var delivery = LockScreenOverlayDelivery()
        var attachments = 0
        var detachments = 0
        func refresh(locked: Bool, succeeds: Bool) {
            delivery.refresh(locked: locked, orderFront: {},
                attach: { attachments += 1; return succeeds }, detach: { detachments += 1 })
        }
        refresh(locked: true, succeeds: false)
        XCTAssertFalse(delivery.delegated)
        refresh(locked: true, succeeds: true)
        refresh(locked: true, succeeds: false)
        XCTAssertTrue(delivery.delegated, "A later failure must not forget a prior attachment that needs cleanup")
        refresh(locked: false, succeeds: true)
        XCTAssertEqual(attachments, 3)
        XCTAssertEqual(detachments, 1)
        XCTAssertFalse(delivery.delegated)
        refresh(locked: false, succeeds: true)
        XCTAssertEqual(detachments, 1)
    }
}
