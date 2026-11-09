import CoreGraphics
import CoreImage
import CoreVideo
import Vision
import FaceUnlockCore

enum FaceImageProcessor {
    static func prepare(_ image: CGImage, context: CIContext) throws -> (pixels: CVPixelBuffer, quality: Float?) {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])
        let face = try selectFace(request.results ?? [])
        let points = try landmarks(face, width: image.width, height: image.height)
        let transform = try FaceAlignmentTransform.fit(source: points)
        let pixels = try render(image, transform: transform, context: context)
        let quality = VNDetectFaceCaptureQualityRequest()
        quality.inputFaceObservations = [face]
        try handler.perform([quality])
        return (pixels, quality.results?.first?.faceCaptureQuality)
    }

    static func selectFace(_ faces: [VNFaceObservation]) throws -> VNFaceObservation {
        guard !faces.isEmpty else { throw RecognitionError.noFace }
        guard faces.count == 1 else { throw RecognitionError.multipleFaces }
        return faces[0]
    }

    static func landmarks(_ face: VNFaceObservation, width: Int, height: Int) throws -> [FacePoint] {
        guard let landmarks = face.landmarks,
              let eyeA = centroid(landmarks.leftPupil ?? landmarks.leftEye, face: face, width: width, height: height),
              let eyeB = centroid(landmarks.rightPupil ?? landmarks.rightEye, face: face, width: width, height: height),
              let nose = centroid(landmarks.nose, face: face, width: width, height: height),
              let lips = landmarks.outerLips, lips.pointCount >= 2 else { throw RecognitionError.landmarks }
        let mouth = lips.normalizedPoints.map { imagePoint($0, face: face, width: width, height: height) }
        guard let left = mouth.min(by: { $0.x < $1.x }), let right = mouth.max(by: { $0.x < $1.x }),
              abs(eyeA.x - eyeB.x) > 1, right.x - left.x > 1 else { throw RecognitionError.landmarks }
        let eyes = [eyeA, eyeB].sorted { $0.x < $1.x }
        return [eyes[0], eyes[1], nose, left, right]
    }

    static func render(_ image: CGImage, transform: FaceAlignmentTransform, context: CIContext) throws -> CVPixelBuffer {
        let buffer = try ArcFaceRecognizer.makeBuffer()
        let aligned = CIImage(cgImage: image).transformed(by: coreImageTransform(transform, sourceHeight: Double(image.height)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw RecognitionError.pixels }
        context.render(aligned, to: buffer, bounds: CGRect(x: 0, y: 0, width: 112, height: 112), colorSpace: colorSpace)
        return buffer
    }

    static func coreImageTransform(_ transform: FaceAlignmentTransform, sourceHeight: Double) -> CGAffineTransform {
        // Both images use bottom-left coordinates in Core Image. The fit/template use top-left.
        CGAffineTransform(a: transform.a, b: -transform.b, c: transform.b, d: transform.a,
                          tx: transform.tx - transform.b * sourceHeight,
                          ty: 112 - transform.a * sourceHeight - transform.ty)
    }

    private static func centroid(_ region: VNFaceLandmarkRegion2D?, face: VNFaceObservation, width: Int, height: Int) -> FacePoint? {
        guard let region, region.pointCount > 0 else { return nil }
        let points = region.normalizedPoints.map { imagePoint($0, face: face, width: width, height: height) }
        return FacePoint(x: points.reduce(0) { $0 + $1.x } / Double(points.count),
                         y: points.reduce(0) { $0 + $1.y } / Double(points.count))
    }

    static func imagePoint(_ point: CGPoint, face: VNFaceObservation, width: Int, height: Int) -> FacePoint {
        FacePoint(x: (face.boundingBox.minX + point.x * face.boundingBox.width) * Double(width),
                  y: (1 - face.boundingBox.minY - point.y * face.boundingBox.height) * Double(height))
    }
}
