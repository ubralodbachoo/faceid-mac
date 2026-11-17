import CoreGraphics
import Foundation
import XCTest
@testable import FaceUnlockRecognition

final class HeavyLivenessTests: XCTestCase {
    private func blink(_ gate: inout HeavyLivenessGate, start: Double = 100) -> ExperimentalLivenessDecision {
        var decision = ExperimentalLivenessDecision.pending
        for i in 1...4 { decision = gate.observe(LivenessFixtures.blinkingFrame(i), at: start + Double(i) * 0.05) }
        return decision
    }

    func testStaticFaceNeverAutoConfirmsEvenAfterManyFrames() {
        var gate = HeavyLivenessGate()
        for i in 0..<100 {
            XCTAssertEqual(gate.observe(LivenessFixtures.frame(), at: 100 + Double(i) * 0.05), .pending)
        }
    }

    func testNaturalBlinkCanSupplyExperimentalPositiveEvidence() {
        var gate = HeavyLivenessGate()
        XCTAssertEqual(blink(&gate), .passed)
        XCTAssertEqual(gate.cue, "blink")
    }

    func testWindowStartingMidBlinkStillRecognizesALaterCompleteBilateralBlink() {
        var gate = HeavyLivenessGate()
        var result = ExperimentalLivenessDecision.pending
        for (i, eye) in [0.1, 0.3, 0.3, 0.1, 0.3].enumerated() {
            result = gate.observe(LivenessFixtures.frame(eye: eye), at: 100 + Double(i) * 0.05)
        }
        XCTAssertEqual(result, .passed)
    }

    func testOneEyeShapeChangeDoesNotCountAsABilateralBlink() {
        var gate = HeavyLivenessGate()
        for i in 1...4 {
            XCTAssertEqual(gate.observe(LivenessFixtures.frame(eye: i == 3 ? 0.01 : 0.3, rightEye: 0.3),
                                        at: 100 + Double(i) * 0.05), .pending)
        }
    }

    func testDeviceAndGlareOverrideAnAlreadyPositiveBlink() {
        for device in [true, false] {
            var gate = HeavyLivenessGate()
            XCTAssertEqual(blink(&gate), .passed)
            let sample = LivenessFixtures.frame(overlap: device ? 0.9 : 0,
                glare: GlareSample(cropPixelWidth: 180, specularFraction: device ? 0 : 0.1,
                                   specularClusterRatio: device ? 0 : 1))
            var last = ExperimentalLivenessDecision.pending
            for i in 1...3 { last = gate.observe(sample, at: 100.2 + Double(i) * 0.05) }
            XCTAssertEqual(last, .rejected)
            XCTAssertEqual(gate.cue, device ? "deviceDetected" : "glossGlare")
        }
    }

    func testUnavailableOrInvalidMeasurementsDiscardEarlierConfirmation() {
        let invalid: [LivenessFrame?] = [nil, LivenessFixtures.frame(overlap: nil),
            LivenessFixtures.frame(glare: nil), LivenessFixtures.frame(eye: .nan),
            LivenessFixtures.frame(yaw: .nan), LivenessFixtures.frame(overlap: .infinity)]
        for frame in invalid {
            var gate = HeavyLivenessGate()
            XCTAssertEqual(blink(&gate), .passed)
            XCTAssertEqual(gate.observe(frame, at: 100.25), .unavailable)
            XCTAssertEqual(gate.observe(LivenessFixtures.frame(), at: 100.3), .pending)
        }
    }

    func testResetGapBackwardTimeAndExpiryCannotReusePositiveEvidence() {
        for scenario in 0..<4 {
            var gate = HeavyLivenessGate()
            XCTAssertEqual(blink(&gate), .passed)
            if scenario == 0 { gate.reset() }
            if scenario == 1 {
                XCTAssertEqual(gate.observe(LivenessFixtures.frame(), at: 100.9), .pending)
            } else if scenario == 2 {
                XCTAssertEqual(gate.observe(LivenessFixtures.frame(), at: 100.2), .unavailable)
            } else if scenario == 3 {
                for i in 1...3 { _ = gate.observe(LivenessFixtures.frame(), at: 100.2 + Double(i) * 0.2) }
                XCTAssertEqual(gate.observe(LivenessFixtures.frame(), at: 101), .pending)
            } else {
                XCTAssertEqual(gate.observe(LivenessFixtures.frame(), at: 100.25), .pending)
            }
        }
    }

    func testTranslatingOrTiltingAPlaneDoesNotSupplyPositiveGeometry() {
        var gate = HeavyLivenessGate()
        for i in 0..<20 {
            // All landmarks, including the nose, move in the same plane. Yaw alone isn't liveness.
            let frame = LivenessFixtures.frame(yaw: Float(i) * 0.025, translation: CGFloat(i) * 0.5)
            XCTAssertEqual(gate.observe(frame, at: 100 + Double(i) * 0.05), .pending)
        }
    }

    func testPoseNoseCorrelationCanConfirmWithoutABlink() {
        var gate = HeavyLivenessGate()
        var last = ExperimentalLivenessDecision.pending
        for i in 0..<8 {
            let yaw = Float(i) * 0.05
            last = gate.observe(LivenessFixtures.frame(yaw: yaw, noseShift: CGFloat(tan(yaw)) * 10),
                                at: 100 + Double(i) * 0.05)
        }
        XCTAssertEqual(last, .passed)
        XCTAssertTrue(["depthPose", "flatVs3D"].contains(gate.cue ?? ""))
    }

    func testGlareRasterizationMeasuresPixelsAndIgnoresUniformDarkCrop() throws {
        let width = 180
        for white in [false, true] {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: width, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(gray: 0.2, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: width))
            if white {
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(CGRect(x: 40, y: 40, width: 50, height: 50))
            }
            let sample = try XCTUnwrap(GlareCueExtractor.extract(faceCrop: XCTUnwrap(context.makeImage())))
            XCTAssertEqual(sample.specularFraction, white ? Float(2_500) / Float(width * width) : 0, accuracy: 0.001)
        }
    }
}
