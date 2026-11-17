import CoreGraphics
import XCTest
@testable import FaceUnlockRecognition

final class DeviceRectangleGeometryTests: XCTestCase {
    private let face = CGRect(x: 100, y: 100, width: 100, height: 100)

    func testBackgroundRectangleAndPartialOverlapAreNotDeviceEvidence() {
        let measurements = DeviceRectangleGeometry.measure([
            CGRect(x: 0, y: 0, width: 640, height: 480), // Background monitor/window.
            CGRect(x: 150, y: 50, width: 150, height: 200), // Half the face overlaps.
            CGRect(x: 110, y: 120, width: 60, height: 30) // An eye/glasses-sized detail.
        ], face: face)
        XCTAssertEqual(measurements.overlap, 0)
        XCTAssertEqual(measurements.diagnostic.ignoredBackground, 1)
        XCTAssertEqual(measurements.diagnostic.ignoredPartial, 2)
        XCTAssertEqual(measurements.diagnostic.qualifying, 0)
    }

    func testPlausibleDisplayEnclosingFaceStillSuppliesDenyEvidence() {
        let measurements = DeviceRectangleGeometry.measure([
            CGRect(x: 60, y: 40, width: 180, height: 240)
        ], face: face)
        XCTAssertEqual(measurements.overlap, 1)
        XCTAssertEqual(measurements.diagnostic.qualifying, 1)
        var gate = HeavyLivenessGate()
        var decision = ExperimentalLivenessDecision.pending
        for i in 1...4 {
            decision = gate.observe(LivenessFixtures.frame(eye: i == 2 ? 0.1 : 0.3, overlap: measurements.overlap),
                                    at: 100 + Double(i) * 0.05)
        }
        XCTAssertEqual(decision, .rejected, "A blink cannot override qualifying device evidence")
    }

    func testIgnoredRectanglesDoNotOverrideAnOtherwisePositiveBlink() {
        let measurements = DeviceRectangleGeometry.measure([
            CGRect(x: 0, y: 0, width: 640, height: 480)
        ], face: face)
        var gate = HeavyLivenessGate()
        var decision = ExperimentalLivenessDecision.pending
        for i in 1...4 {
            decision = gate.observe(LivenessFixtures.frame(eye: i == 2 ? 0.1 : 0.3, overlap: measurements.overlap),
                                    at: 100 + Double(i) * 0.05)
        }
        XCTAssertEqual(decision, .passed)
        XCTAssertEqual(gate.cue, "blink")
    }

    func testFaceSizedDetailIsNotAnEnclosingScreen() {
        let measurements = DeviceRectangleGeometry.measure([face, face.insetBy(dx: -1, dy: -1)], face: face)
        XCTAssertEqual(measurements.overlap, 0)
        XCTAssertEqual(measurements.diagnostic.ignoredTight, 2)
    }

    func testBackgroundCandidateDoesNotHideAnotherQualifyingDevice() {
        let measurements = DeviceRectangleGeometry.measure([
            CGRect(x: 0, y: 0, width: 640, height: 480),
            CGRect(x: 60, y: 40, width: 180, height: 240)
        ], face: face)
        XCTAssertEqual(measurements.overlap, 1)
        XCTAssertEqual(measurements.diagnostic.candidates, 2)
        XCTAssertEqual(measurements.diagnostic.ignoredBackground, 1)
        XCTAssertEqual(measurements.diagnostic.qualifying, 1)
    }

    func testQualificationIsScaleAndTranslationIndependent() {
        for scale: CGFloat in [0.5, 1, 2] {
            let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: 25, ty: 60)
            let measurements = DeviceRectangleGeometry.measure([
                CGRect(x: 60, y: 40, width: 180, height: 240).applying(transform)
            ], face: face.applying(transform))
            XCTAssertEqual(measurements.overlap, 1)
        }
    }

    func testInvalidRectanglesAreIgnoredWithoutProducingNonfiniteEvidence() {
        let measurements = DeviceRectangleGeometry.measure([.null, .zero,
            CGRect(x: CGFloat.nan, y: 0, width: 200, height: 200)
        ], face: face)
        XCTAssertEqual(measurements.overlap, 0)
        XCTAssertEqual(measurements.diagnostic.ignoredInvalid, 3)
    }
}
