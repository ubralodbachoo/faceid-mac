import XCTest
@testable import FaceUnlockApp

final class HapticFeedbackTests: XCTestCase {
    @MainActor
    func testUnlockHapticsWaitForActualOutcomeAndNeverDuplicateOrBuzzPreflight() {
        var time = 1.0
        var cues: [HapticCue] = []
        let controller = HapticFeedbackController(enabled: { true }, uptime: { time }, emit: { cues.append($0) })
        controller.unlockChanged(.preparing); controller.unlockChanged(.fallback)
        XCTAssertTrue(cues.isEmpty)
        controller.unlockChanged(.scanning); controller.unlockChanged(.fallback); controller.unlockChanged(.fallback)
        XCTAssertEqual(cues, [.failure])
        time += 1
        controller.unlockChanged(.scanning); controller.unlockChanged(.waitingForPasswordField)
        controller.unlockChanged(.submitting); controller.unlockChanged(.awaitingDesktop)
        XCTAssertEqual(cues, [.failure])
        controller.unlockChanged(.unlocked); controller.unlockChanged(.unlocked)
        XCTAssertEqual(cues, [.failure, .success])
    }

    @MainActor
    func testPoseProgressHonorsToggleRateLimitAndCounterReset() {
        var enabled = true
        var time = 1.0
        var cues: [HapticCue] = []
        let controller = HapticFeedbackController(enabled: { enabled }, uptime: { time }, emit: { cues.append($0) })
        controller.poseCountChanged(0); controller.poseCountChanged(1); controller.poseCountChanged(1)
        controller.poseCountChanged(2)
        XCTAssertEqual(cues, [.progress], "No per-frame or rapid repeated vibration")
        time += 1; enabled = false; controller.poseCountChanged(3)
        XCTAssertEqual(cues, [.progress])
        enabled = true; controller.poseCountChanged(0); controller.poseCountChanged(1)
        XCTAssertEqual(cues, [.progress, .progress])
    }

    @MainActor
    func testMetadataReadsAndCanceledEnrollmentDoNotPretendRegistrationCompleted() {
        var cues: [HapticCue] = []
        let controller = HapticFeedbackController(enabled: { true }, emit: { cues.append($0) })
        controller.enrollmentChanged(.validating); controller.enrollmentChanged(.saved)
        controller.enrollmentChanged(.authorizing); controller.enrollmentChanged(.idle)
        XCTAssertTrue(cues.isEmpty)
        controller.enrollmentChanged(.review); controller.enrollmentChanged(.saved)
        XCTAssertEqual(cues, [.success])
    }
}
