import CoreGraphics
import Foundation
@testable import FaceUnlockRecognition

/// Synthetic mechanics fixtures only; these are not camera accuracy or attack-resistance evidence.
enum LivenessFixtures {
    static func frame(eye: CGFloat = 0.3, rightEye: CGFloat? = nil, yaw: Float = 0,
                      overlap: CGFloat? = 0, glare: GlareSample? = GlareSample(cropPixelWidth: 180,
                          specularFraction: 0, specularClusterRatio: 0),
                      translation: CGFloat = 0, noseShift: CGFloat = 0) -> LivenessFrame {
        let regions: [(LandmarkRegion, [CGPoint])] = [
            (.leftEye, [CGPoint(x: 20, y: 30), CGPoint(x: 30, y: 30)]),
            (.rightEye, [CGPoint(x: 70, y: 30), CGPoint(x: 80, y: 30)]),
            (.leftEyebrow, [CGPoint(x: 20, y: 20), CGPoint(x: 30, y: 19)]),
            (.rightEyebrow, [CGPoint(x: 70, y: 19), CGPoint(x: 80, y: 20)]),
            (.outerLips, [CGPoint(x: 35, y: 75), CGPoint(x: 50, y: 80), CGPoint(x: 65, y: 75)]),
            (.nose, [CGPoint(x: 48 + noseShift, y: 48), CGPoint(x: 52 + noseShift, y: 52)])
        ]
        let points = regions.flatMap { region, points in
            points.enumerated().map { index, point in
                LandmarkPoint(point: CGPoint(x: point.x + translation, y: point.y), region: region, indexInRegion: index)
            }
        }
        return LivenessFrame(timestamp: .distantPast, landmarks: points, interocularDistance: 50,
            yaw: yaw, leftEyeAspectRatio: eye, rightEyeAspectRatio: rightEye ?? eye,
            noseOffsetRatio: noseShift / 50, hasReliableLandmarks: true,
            deviceOverlapFraction: overlap, glare: glare)
    }

    static func blinkingFrame(_ index: Int) -> LivenessFrame {
        // Repeated positives keep identity-only mechanics tests independent of cue expiry.
        frame(eye: index % 3 == 2 ? 0.1 : 0.3)
    }
}
