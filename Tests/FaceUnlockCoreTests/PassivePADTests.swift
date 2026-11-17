import CoreGraphics
import CoreML
import Foundation
import ImageIO
import XCTest
@testable import FaceUnlockRecognition

final class PassivePADTests: XCTestCase {
    func testNativePreprocessingMatchesOriginalModelOnUpstreamCameraExamples() throws {
        guard let path = ProcessInfo.processInfo.environment["FACEUNLOCK_TEST_PAD_MODEL_PATH"] else {
            throw XCTSkip("Native passive PAD integration is opt-in")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let samples = root.appendingPathComponent("Models/passive-pad-source/images/sample")
        guard FileManager.default.fileExists(atPath: samples.path) else { throw XCTSkip("Public upstream examples not downloaded") }
        let model = try PassivePADModel(url: URL(fileURLWithPath: path))
        try model.validate(referenceURL: root.appendingPathComponent("Models/PassivePADReference.json"))
        let cases: [(String, CGRect, Double, Double)] = [
            ("image_T1.jpg", CGRect(x: 158.8196, y: 172.5271, width: 170.6329, height: 170.6329), 0.999367, 0.989388),
            ("image_F1.jpg", CGRect(x: 118.1463, y: 112.2436, width: 212.1612, height: 212.1612), 0.016695, 0.008778),
            ("image_F2.jpg", CGRect(x: 231.7004, y: 102.2877, width: 269.1673, height: 269.1673), 0.241249, 0.515478)
        ]
        for (name, box, near, wide) in cases {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(samples.appendingPathComponent(name) as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let result = try model.analyze(image, face: box)
            XCTAssertEqual(result.nearLive, near, accuracy: 0.02)
            XCTAssertEqual(result.wideLive, wide, accuracy: 0.02)
        }
    }

    func testEvaluationNeedsBothModelsAndConsecutiveFreshFrames() throws {
        var window = PassivePADEvaluationWindow()
        let live = try PassivePADScores(nearLive: 0.99, wideLive: 0.99, inferenceMilliseconds: 5)
        XCTAssertEqual(window.observe(live, at: 100), .uncertain)
        XCTAssertEqual(window.observe(live, at: 100.2), .uncertain)
        XCTAssertEqual(window.observe(live, at: 100.4), .liveCandidate)
        let disagreement = try PassivePADScores(nearLive: 0.99, wideLive: 0.02, inferenceMilliseconds: 5)
        XCTAssertEqual(window.observe(disagreement, at: 100.6), .uncertain)
        XCTAssertEqual(window.observe(nil, at: 100.8), .unavailable)
        XCTAssertEqual(window.observe(live, at: 101), .uncertain)
        XCTAssertEqual(window.observe(live, at: 102), .uncertain)
        XCTAssertEqual(window.observe(live, at: 102), .unavailable)
        XCTAssertThrowsError(try PassivePADScores(nearLive: .nan, wideLive: 1, inferenceMilliseconds: 5))
    }

    func testSpoofCandidateNeedsBothModels() throws {
        var window = PassivePADEvaluationWindow()
        let spoof = try PassivePADScores(nearLive: 0.01, wideLive: 0.02, inferenceMilliseconds: 5)
        for i in 0..<3 { _ = window.observe(spoof, at: 100 + Double(i) * 0.2) }
        XCTAssertEqual(window.decision, .spoofCandidate)
    }

    func testCropShiftsAtFrameEdgesAndIncludesEndPixel() throws {
        XCTAssertEqual(try PassivePADPixels.crop(width: 640, height: 480,
            face: CGRect(x: 100, y: 100, width: 100, height: 100), scale: 2.7),
            CGRect(x: 15, y: 15, width: 271, height: 271))
        XCTAssertEqual(try PassivePADPixels.crop(width: 640, height: 480,
            face: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2.7),
            CGRect(x: 0, y: 0, width: 271, height: 271))
        XCTAssertThrowsError(try PassivePADPixels.crop(width: 640, height: 480, face: .null, scale: 2.7))
    }

    func testTensorPreservesRawBGRAndTopToBottomOrientation() throws {
        var data = [UInt8](repeating: 255, count: 80 * 80 * 4)
        for y in 0..<80 {
            for x in 0..<80 {
                let i = (y * 80 + x) * 4
                data[i] = UInt8(y); data[i+1] = 100; data[i+2] = 200
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(data) as CFData))
        let image = try XCTUnwrap(CGImage(width: 80, height: 80, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 320, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let tensor = try PassivePADPixels.tensor(image: image, face: CGRect(x: 0, y: 0, width: 79, height: 79), scale: 1)
        XCTAssertEqual(tensor[0].intValue, 200)
        XCTAssertEqual(tensor[6_400].intValue, 100)
        XCTAssertEqual(tensor[12_800].intValue, 0)
        XCTAssertEqual(tensor[12_800 + 79 * 80].intValue, 79)
    }

    func testNativeConvertedPairMatchesOriginalReferenceAndRejectsAlteredReference() throws {
        guard let path = ProcessInfo.processInfo.environment["FACEUNLOCK_TEST_PAD_MODEL_PATH"] else {
            throw XCTSkip("Native passive PAD integration is opt-in")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let model = try PassivePADModel(url: URL(fileURLWithPath: path))
        try model.validate(referenceURL: root.appendingPathComponent("Models/PassivePADReference.json"))
        let reference = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: reference) }
        try Data("{}".utf8).write(to: reference)
        XCTAssertThrowsError(try model.validate(referenceURL: reference))
    }
}
