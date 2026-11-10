import AVFoundation
import CoreGraphics
import Foundation
import XCTest
import FaceUnlockCore
@testable import FaceUnlockRecognition

final class EnrollmentVideoReplayTests: XCTestCase {
    /// Opt-in local replay of the user-supplied Glance reference. The movie is never copied into
    /// the repository/app, saved as enrollment, or used as evidence of liveness/identity accuracy.
    func testReferenceVideoProducesStableMultiFrameCaptureWithRealVisionAndCoreML() async throws {
        guard let moviePath = ProcessInfo.processInfo.environment["FACEUNLOCK_TEST_ENROLLMENT_VIDEO_PATH"],
              let modelPath = ProcessInfo.processInfo.environment["FACEUNLOCK_TEST_MODEL_PATH"] else {
            throw XCTSkip("Local reference-video replay is opt-in")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let recognizer = ArcFaceRecognizer(modelURL: URL(fileURLWithPath: modelPath))
        _ = try await recognizer.validateAndBenchmark(referenceURL: root.appendingPathComponent("Models/ArcFaceReference.json"))
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: moviePath)))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var collector = VideoEnrollmentCollector(modelIdentifier: ArcFaceContract.identifier)
        var analyzed = 0
        var timings: [Double] = []
        for index in 0..<32 {
            let time = Double(index) * 0.125
            let frame = try await generator.image(at: CMTime(seconds: 15.5 + time, preferredTimescale: 600)).image
            // This known clip is a screen recording: isolate its camera preview, excluding UI.
            let crop = try XCTUnwrap(frame.cropping(to: CGRect(x: 835, y: 65, width: 250, height: 250)))
            let context = try XCTUnwrap(CGContext(data: nil, width: 500, height: 500, bitsPerComponent: 8,
                bytesPerRow: 2000, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 500, height: 500))
            let image = try XCTUnwrap(context.makeImage())
            do {
                let start = ProcessInfo.processInfo.systemUptime
                let result = try await recognizer.analyze(image)
                timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                analyzed += 1
                _ = try collector.observe(result.embedding, metrics: XCTUnwrap(result.enrollmentMetrics), at: time)
            } catch let error as RecognitionError {
                switch error {
                case .noFace, .landmarks, .poseUnavailable, .captureQualityUnavailable: collector.interrupt()
                default: throw error
                }
            }
        }
        XCTAssertGreaterThan(analyzed, 20)
        XCTAssertGreaterThanOrEqual(collector.completedPoses, 1, "The real video must provide a stable burst, not merely a detectable single image")
        XCTAssertGreaterThanOrEqual(collector.sampleCount, 2)
        timings.sort()
        if !timings.isEmpty {
            print("Reference replay: \(analyzed) frames analyzed; \(collector.completedPoses) angles captured; analysis median \(String(format: "%.1f", timings[timings.count / 2])) ms.")
        }
    }
}
