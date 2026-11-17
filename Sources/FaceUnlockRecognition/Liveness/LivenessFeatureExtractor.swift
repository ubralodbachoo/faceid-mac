// Adapted from jonnyoo/glance b97f521397ec1197ba17768ba797cae1e628848d.
// Copyright (c) 2026 Jonathan Zhou. MIT; see Models/Glance-MIT-LICENSE.txt.
import CoreGraphics
import Vision

enum LivenessFeatureExtractor {
    /// Uses the same detected face and original camera image as identity analysis.
    /// Missing measurements never become an implicit liveness pass.
    static func extract(face: VNFaceObservation, pose: VNFaceObservation, image: CGImage) -> LivenessFrame? {
        guard let landmarks = face.landmarks, let yaw = pose.yaw else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        let box = pose.boundingBox
        let cropRect = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                              width: box.width * size.width, height: box.height * size.height).integral
        guard let crop = image.cropping(to: cropRect),
              let glare = GlareCueExtractor.extract(faceCrop: crop),
              let device = deviceMeasurement(in: image, face: cropRect),
              let left = LandmarkGeometry.eyeCenter(pupil: landmarks.leftPupil, eye: landmarks.leftEye, imageSize: size),
              let right = LandmarkGeometry.eyeCenter(pupil: landmarks.rightPupil, eye: landmarks.rightEye, imageSize: size),
              let noseRegion = landmarks.nose,
              let nose = LandmarkGeometry.centroid(of: noseRegion, imageSize: size) else { return nil }
        let distance = hypot(left.x - right.x, left.y - right.y)
        guard distance.isFinite, distance > 0 else { return nil }
        return LivenessFrame(timestamp: .distantPast,
            landmarks: LandmarkGeometry.allPoints(from: landmarks, imageSize: size),
            interocularDistance: distance, yaw: yaw.floatValue,
            leftEyeAspectRatio: landmarks.leftEye.flatMap { LandmarkGeometry.eyeAspectRatio(of: $0, imageSize: size) },
            rightEyeAspectRatio: landmarks.rightEye.flatMap { LandmarkGeometry.eyeAspectRatio(of: $0, imageSize: size) },
            noseOffsetRatio: (nose.x - (left.x + right.x) / 2) / distance,
            hasReliableLandmarks: true, deviceOverlapFraction: device.overlap, glare: glare,
            deviceDiagnostics: device.diagnostic)
    }

    /// Glance's rectangle heuristic, with failure distinguished from no detected device.
    /// Consider every plausible enclosing candidate, rather than only the largest rectangle.
    static func deviceOverlap(in image: CGImage, face: CGRect) -> CGFloat? {
        deviceMeasurement(in: image, face: face)?.overlap
    }

    private static func deviceMeasurement(in image: CGImage, face: CGRect)
        -> (overlap: CGFloat, diagnostic: DeviceRectangleDiagnostics)? {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.6
        request.minimumSize = 0.15
        request.maximumObservations = 3
        request.minimumAspectRatio = 0.35
        request.maximumAspectRatio = 1
        request.quadratureTolerance = 30
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
        catch { return nil }
        guard let results = request.results, face.width > 0, face.height > 0 else { return nil }
        let rectangles = results.map { observation in
            let box = observation.boundingBox
            let rect = CGRect(x: box.minX * CGFloat(image.width), y: (1 - box.maxY) * CGFloat(image.height),
                              width: box.width * CGFloat(image.width), height: box.height * CGFloat(image.height))
            return rect
        }
        return DeviceRectangleGeometry.measure(rectangles, face: face)
    }
}
