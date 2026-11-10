import CoreGraphics
import XCTest
@testable import FaceUnlockApp
import FaceUnlockCore

final class EnrollmentFramingTests: XCTestCase {
    func testCenteredFaceNearImageEdgeIsNotMistakenForOffCenterPadding() throws {
        let face = FaceBounds(x: 0.3, y: 0.02, width: 0.4, height: 0.96)
        XCTAssertTrue(EnrollmentFraming.isCentered(face))
        XCTAssertFalse(face.isClipped)
        XCTAssertNoThrow(try metrics(face).validate())
    }

    func testClippedCenteredFaceRequestsDistanceInsteadOfRecentering() throws {
        let face = FaceBounds(x: 0.3, y: -0.02, width: 0.4, height: 1.04)
        XCTAssertTrue(EnrollmentFraming.isCentered(face))
        XCTAssertTrue(face.isClipped)
        XCTAssertTrue(metrics(face).adjustment?.contains("farther back") == true)
        XCTAssertThrowsError(try metrics(face).validate())
    }

    func testOffCenterAndInvalidRegionsAreStillRejectedAndMirrorInvariant() {
        let face = FaceBounds(x: 0.02, y: 0.2, width: 0.2, height: 0.4)
        XCTAssertFalse(EnrollmentFraming.isCentered(face))
        XCTAssertEqual(EnrollmentFraming.isCentered(face), EnrollmentFraming.isCentered(face.mirrored))
        XCTAssertTrue(metrics(face).adjustment?.contains("detected face box") == true)
        XCTAssertThrowsError(try metrics(face).validate())
        let invalid = FaceBounds(x: .nan, y: 0.2, width: 0.2, height: 0.4)
        XCTAssertFalse(EnrollmentFraming.isCentered(invalid))
        XCTAssertThrowsError(try metrics(invalid).validate())
    }

    func testPreviewGuideAndDetectionUseSameLetterboxedImageCoordinates() {
        let viewport = EnrollmentPreviewGeometry.viewport(imageWidth: 1920, imageHeight: 1080,
                                                          container: CGSize(width: 416, height: 312))
        XCTAssertEqual(viewport, CGRect(x: 0, y: 39, width: 416, height: 234))
        let guide = EnrollmentPreviewGeometry.rect(EnrollmentFraming.guide(imageWidth: 1920, imageHeight: 1080), viewport: viewport)
        XCTAssertEqual(guide.midX, 208, accuracy: 0.001)
        XCTAssertEqual(guide.midY, 156, accuracy: 0.001)
        XCTAssertEqual(guide.width / guide.height, 190.0 / 244.0, accuracy: 0.001)
        let face = FaceBounds(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let detection = EnrollmentPreviewGeometry.rect(face, viewport: viewport, mirrored: true)
        XCTAssertEqual(detection.minX, 249.6, accuracy: 0.001)
        XCTAssertEqual(detection.minY, 85.8, accuracy: 0.001)
        XCTAssertEqual(detection.width, 124.8, accuracy: 0.001)
        XCTAssertEqual(detection.height, 93.6, accuracy: 0.001)
    }

    private func metrics(_ face: FaceBounds) -> EnrollmentMetrics {
        EnrollmentMetrics(quality: 0.8, yaw: 0, pitch: 0, roll: 0,
                          faceWidthPixels: 180, faceHeightPixels: 200,
                          centered: EnrollmentFraming.isCentered(face), luminance: 120, faceBounds: face)
    }
}
