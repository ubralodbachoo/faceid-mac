import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision
import XCTest
import FaceUnlockCore
@testable import FaceUnlockRecognition

final class FaceCaptureIntegrationTests: XCTestCase {
    func testMissingPoseQualityOrMismatchedFaceNeverBecomesDefaultZeroAngles() throws {
        let box = CGRect(x: 0.3, y: 0.2, width: 0.3, height: 0.5)
        let face = VNFaceObservation(boundingBox: box)
        let missingPitch = VNFaceObservation(requestRevision: 2, boundingBox: box, roll: 0, yaw: 0, pitch: nil)
        let validPose = VNFaceObservation(requestRevision: 3, boundingBox: box, roll: 0, yaw: 0, pitch: 0)
        let wrongRegion = VNFaceObservation(requestRevision: 3, boundingBox: CGRect(x: 0, y: 0, width: 0.1, height: 0.1), roll: 0, yaw: 0, pitch: 0)
        for pose in [missingPitch, wrongRegion] {
            XCTAssertThrowsError(try FaceImageProcessor.captureMetrics(face: face, poseFace: pose, quality: 0.8,
                width: 640, height: 480, luminance: 120)) { error in
                XCTAssertEqual(error as? RecognitionError, .poseUnavailable)
            }
        }
        XCTAssertThrowsError(try FaceImageProcessor.captureMetrics(face: face, poseFace: validPose, quality: nil,
            width: 640, height: 480, luminance: 120)) { error in
            XCTAssertEqual(error as? RecognitionError, .captureQualityUnavailable)
        }
        let metrics = try FaceImageProcessor.captureMetrics(face: face, poseFace: validPose, quality: 0.8,
            width: 640, height: 480, luminance: 120)
        XCTAssertNoThrow(try metrics.validate())
    }

    func testNativeModelCanAnalyzeARealFaceWithEnrollmentMetadata() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["FACEUNLOCK_TEST_MODEL_PATH"] else {
            throw XCTSkip("Native Core ML integration is opt-in")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let recognizer = ArcFaceRecognizer(modelURL: URL(fileURLWithPath: modelPath))
        _ = try await recognizer.validateAndBenchmark(referenceURL: root.appendingPathComponent("Models/ArcFaceReference.json"))
        let analysis = try await recognizer.analyze(fixture())
        XCTAssertEqual(analysis.embedding.dimensions, 512)
        XCTAssertNotNil(analysis.enrollmentMetrics)
        XCTAssertNotNil(analysis.quality)
    }

    func testRealDetectedFaceProducesRequiredEnrollmentPoseAndQualityMetrics() throws {
        let image = try fixture()
        let prepared = try FaceImageProcessor.prepare(image, context: CIContext(options: [.cacheIntermediates: false]))
        XCTAssertNotNil(prepared.quality)
        let metrics = prepared.metrics
        XCTAssertTrue(metrics.yaw.isFinite)
        XCTAssertTrue(metrics.pitch.isFinite)
        XCTAssertTrue(metrics.roll.isFinite)
        XCTAssertTrue(metrics.quality.isFinite)
        XCTAssertTrue((0...1).contains(metrics.quality))
    }

    func testNativePipelineComparesBrightnessVariantsThroughTemporalPolicy() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["FACEUNLOCK_TEST_MODEL_PATH"] else {
            throw XCTSkip("Native Core ML integration is opt-in")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let recognizer = ArcFaceRecognizer(modelURL: URL(fileURLWithPath: modelPath))
        _ = try await recognizer.validateAndBenchmark(referenceURL: root.appendingPathComponent("Models/ArcFaceReference.json"))
        let crop = try XCTUnwrap(fixture().cropping(to: CGRect(x: 140, y: 20, width: 220, height: 240)))
        let context = CIContext(options: [.cacheIntermediates: false])
        let input = CIImage(cgImage: crop).transformed(by: CGAffineTransform(scaleX: 2, y: 2))
        let source = try XCTUnwrap(context.createCGImage(input, from: input.extent))
        let enrolled = try await recognizer.analyze(source)
        let template = try EnrollmentTemplate(embeddings: Array(repeating: enrolled.embedding, count: 18),
                                               modelIdentifier: ArcFaceContract.identifier)
        var window = try FaceComparisonWindow(template: template)
        for index in 0..<12 {
            let variant = input.applyingFilter("CIColorControls", parameters: ["inputBrightness": Double(index % 3) * 0.025])
            let image = try XCTUnwrap(context.createCGImage(variant, from: variant.extent))
            let probe = try await recognizer.analyze(image)
            let metrics = try XCTUnwrap(probe.enrollmentMetrics)
            XCTAssertNil(FaceComparisonWindow.adjustment(for: metrics))
            try window.observe(probe.embedding, metrics: metrics, at: Double(index) * 0.2)
        }
        XCTAssertEqual(window.result?.outcome, .similar)
        // This is one public photo with derived variants: a mechanics regression, not accuracy,
        // held-out genuine/impostor evaluation, or proof of liveness.
    }

    private func fixture() throws -> CGImage {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "astronaut", withExtension: "png", subdirectory: "Fixtures"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
}
