import XCTest
import FaceUnlockCore
import FaceUnlockMac

final class ReadinessTests: XCTestCase {
    func testGrantedPermissionsDoNotMakeMissingUnlockServicesReady() {
        let report = ReadinessReport(statuses: [
            .cameraPermission: .available,
            .accessibilityPermission: .available
        ])

        XCTAssertFalse(report.isSetupComplete)
        XCTAssertEqual(Set(report.blockers), Set([
            .credentialVault, .lockSession, .faceRecognition, .liveness, .passwordEntry
        ]))
    }

    func testEveryRequirementMustBeAvailableToCompleteSetup() {
        let configured = Dictionary(uniqueKeysWithValues: Component.allCases.map { ($0, ComponentStatus.available) })
        XCTAssertTrue(ReadinessReport(statuses: configured).isSetupComplete)

        for component in Component.allCases {
            for status in [ComponentStatus.permissionRequired, .unavailable, .notImplemented] {
                var statuses = configured
                statuses[component] = status
                XCTAssertFalse(ReadinessReport(statuses: statuses).isSetupComplete)
            }
            var missing = configured
            missing.removeValue(forKey: component)
            XCTAssertFalse(ReadinessReport(statuses: missing).isSetupComplete)
        }
    }

    @MainActor
    func testProductionSkeletonKeepsAuthenticationComponentsUnimplemented() {
        let report = MacReadinessProvider().inspect()
        for component in [Component.credentialVault, .lockSession, .faceRecognition, .liveness, .passwordEntry] {
            XCTAssertEqual(report.status(for: component), .notImplemented)
        }
        XCTAssertFalse(report.isSetupComplete)
    }
}
