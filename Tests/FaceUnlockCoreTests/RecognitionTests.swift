import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision
import XCTest
import FaceUnlockCore
@testable import FaceUnlockRecognition

final class RecognitionTests: XCTestCase {
    func testEmbeddingValidationNormalizationAndModelIsolation() throws {
        var values = [Float](repeating: 0, count: 512)
        values[0] = 3; values[1] = 4
        let embedding = try FaceEmbedding(raw: values, modelIdentifier: "model-a")
        XCTAssertEqual(embedding.values[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(embedding.values[1], 0.8, accuracy: 1e-6)
        XCTAssertEqual(try embedding.cosineSimilarity(to: embedding), 1, accuracy: 1e-6)
        let opposite = try FaceEmbedding(raw: values.map { -$0 }, modelIdentifier: "model-a")
        XCTAssertEqual(try embedding.cosineSimilarity(to: opposite), -1, accuracy: 1e-6)
        let otherModel = try FaceEmbedding(raw: values, modelIdentifier: "model-b")
        XCTAssertThrowsError(try embedding.cosineSimilarity(to: otherModel))
        XCTAssertTrue(String(describing: embedding).contains("redacted"))
        XCTAssertFalse(String(reflecting: embedding).contains("0.6"))
    }

    func testMalformedAndZeroEmbeddingsAreRejected() throws {
        XCTAssertThrowsError(try FaceEmbedding(raw: [1, 2], modelIdentifier: "model"))
        var values = [Float](repeating: 0, count: 512)
        XCTAssertThrowsError(try FaceEmbedding(raw: values, modelIdentifier: "model"))
        for invalid in [Float.nan, .infinity, -.infinity] {
            values[0] = invalid
            XCTAssertThrowsError(try FaceEmbedding(raw: values, modelIdentifier: "model"))
        }
        values[0] = .greatestFiniteMagnitude
        let embedding = try FaceEmbedding(raw: values, modelIdentifier: "model")
        XCTAssertEqual(embedding.values[0], 1, accuracy: 1e-6)
        XCTAssertThrowsError(try FaceEmbedding(raw: values, modelIdentifier: ""))
    }

    func testAlignmentPreservesCanonicalTemplate() throws {
        let template = FaceAlignmentTransform.arcFaceTemplate
        let fit = try FaceAlignmentTransform.fit(source: template)
        for point in template {
            let actual = fit.apply(point)
            XCTAssertEqual(actual.x, point.x, accuracy: 1e-8)
            XCTAssertEqual(actual.y, point.y, accuracy: 1e-8)
        }
    }

    func testAlignmentRecoversScaleRotationAndTranslationWithoutFlippingImage() throws {
        let template = FaceAlignmentTransform.arcFaceTemplate
        let source = template.map { FacePoint(x: 1.7 * $0.x - 0.4 * $0.y + 31,
                                               y: 0.4 * $0.x + 1.7 * $0.y + 45) }
        let fit = try FaceAlignmentTransform.fit(source: source)
        let ciTransform = FaceImageProcessor.coreImageTransform(fit, sourceHeight: 300)
        for (source, expected) in zip(source, template) {
            let actual = fit.apply(source)
            XCTAssertEqual(actual.x, expected.x, accuracy: 1e-7)
            XCTAssertEqual(actual.y, expected.y, accuracy: 1e-7)
            let bottomLeft = CGPoint(x: source.x, y: 300 - source.y).applying(ciTransform)
            XCTAssertEqual(bottomLeft.x, expected.x, accuracy: 1e-7)
            XCTAssertEqual(bottomLeft.y, 112 - expected.y, accuracy: 1e-7)
        }
    }

    func testUnusableAlignmentCannotFallBackToLooseCrop() {
        XCTAssertThrowsError(try FaceAlignmentTransform.fit(source: []))
        XCTAssertThrowsError(try FaceAlignmentTransform.fit(source: Array(repeating: FacePoint(x: 1, y: 1), count: 5)))
        var points = FaceAlignmentTransform.arcFaceTemplate
        points[0] = FacePoint(x: .nan, y: 1)
        XCTAssertThrowsError(try FaceAlignmentTransform.fit(source: points))
        let noLandmarks = VNFaceObservation(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))
        XCTAssertThrowsError(try FaceImageProcessor.landmarks(noLandmarks, width: 640, height: 480))
    }

    func testSyntheticPixelGeneratorUsesExpectedRGBAndStride() throws {
        let buffer = try ArcFaceRecognizer.syntheticPixels(seed: 19)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for (x, y) in [(0, 0), (1, 2), (38, 51), (111, 111)] {
            let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            XCTAssertEqual(base[offset], UInt8((x * 53 + y * 7 + 19 * 47) % 256))
            XCTAssertEqual(base[offset + 1], UInt8((x * 11 + y * 43 + 19 * 29) % 256))
            XCTAssertEqual(base[offset + 2], UInt8((x * 37 + y * 17 + 19 * 13) % 256))
            XCTAssertEqual(base[offset + 3], 255)
        }
        XCTAssertThrowsError(try ArcFaceRecognizer.syntheticPixels(seed: -1))
    }

    func testRenderedCanonicalImageHasExpectedSizeAndChannels() throws {
        let image = try solidImage()
        let transform = try FaceAlignmentTransform.fit(source: FaceAlignmentTransform.arcFaceTemplate)
        let buffer = try FaceImageProcessor.render(image, transform: transform, context: CIContext(options: [.useSoftwareRenderer: true]))
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 112)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 112)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let center = 56 * CVPixelBufferGetBytesPerRow(buffer) + 56 * 4
        XCTAssertEqual(base[center], 0)
        XCTAssertEqual(base[center + 1], 0)
        XCTAssertEqual(base[center + 2], 255)
        XCTAssertEqual(base[center + 3], 255)
    }

    func testImageWithoutFaceDoesNotBecomeAnIdentity() throws {
        XCTAssertThrowsError(try FaceImageProcessor.prepare(solidImage(), context: CIContext(options: [.useSoftwareRenderer: true]))) { error in
            XCTAssertEqual(error as? RecognitionError, .noFace)
        }
    }

    func testMultipleFacesCannotSilentlyChooseAnIdentity() throws {
        let first = VNFaceObservation(boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.3))
        let second = VNFaceObservation(boundingBox: CGRect(x: 0.5, y: 0.2, width: 0.2, height: 0.3))
        XCTAssertThrowsError(try FaceImageProcessor.selectFace([]))
        XCTAssertThrowsError(try FaceImageProcessor.selectFace([first, second])) { error in
            XCTAssertEqual(error as? RecognitionError, .multipleFaces)
        }
        XCTAssertEqual(try FaceImageProcessor.selectFace([first]).uuid, first.uuid)
    }

    func testVisionLandmarkCoordinatesBecomeTopLeftImagePixels() {
        let face = VNFaceObservation(boundingBox: CGRect(x: 0.2, y: 0.1, width: 0.4, height: 0.6))
        let point = FaceImageProcessor.imagePoint(CGPoint(x: 0.5, y: 0.25), face: face, width: 1000, height: 500)
        XCTAssertEqual(point.x, 400, accuracy: 1e-6)
        XCTAssertEqual(point.y, 375, accuracy: 1e-6)
    }

    func testMissingModelAndUnvalidatedAnalysisFailClosed() async throws {
        let recognizer = ArcFaceRecognizer(modelURL: URL(fileURLWithPath: "/nonexistent/ArcFace.mlmodelc"))
        do {
            _ = try await recognizer.validateAndBenchmark(referenceURL: URL(fileURLWithPath: "/nonexistent/reference.json"))
            XCTFail("A missing model must not generate embeddings")
        } catch { XCTAssertEqual(error as? RecognitionError, .missingModel) }
        do {
            _ = try await recognizer.analyzeImage(at: URL(fileURLWithPath: "/nonexistent/image.png"))
            XCTFail("Image analysis requires numerical validation")
        } catch { XCTAssertEqual(error as? RecognitionError, .reference) }
    }

    func testOptInCompiledModelMatchesOriginalONNXAndReportsLatency() async throws {
        guard let path = ProcessInfo.processInfo.environment["FACEUNLOCK_TEST_MODEL_PATH"] else {
            throw XCTSkip("Native Core ML integration is opt-in")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let recognizer = ArcFaceRecognizer(modelURL: URL(fileURLWithPath: path))
        let report = try await recognizer.validateAndBenchmark(referenceURL: root.appendingPathComponent("Models/ArcFaceReference.json"))
        XCTAssertEqual(report.dimensions, 512)
        XCTAssertEqual(report.referenceCases, 5)
        XCTAssertGreaterThan(report.minimumReferenceCosine, 0.999)
        XCTAssertGreaterThan(report.medianMilliseconds, 0)
        XCTAssertEqual(report.measuredPredictions, 30)
        do {
            _ = try await recognizer.validateAndBenchmark(referenceURL: root.appendingPathComponent("Models/nonexistent-reference.json"))
            XCTFail("Missing reference must disable a previously validated model")
        } catch { XCTAssertEqual(error as? RecognitionError, .reference) }
        do {
            _ = try await recognizer.analyzeImage(at: root.appendingPathComponent("nonexistent.png"))
            XCTFail("Failed revalidation must revoke analysis readiness")
        } catch { XCTAssertEqual(error as? RecognitionError, .reference) }
    }

    private func solidImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 112, height: 112, bitsPerComponent: 8,
                                              bytesPerRow: 112 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 112, height: 112))
        return try XCTUnwrap(context.makeImage())
    }
}
