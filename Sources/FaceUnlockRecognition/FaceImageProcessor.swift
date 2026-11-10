import CoreGraphics
import CoreImage
import CoreVideo
import Vision
import FaceUnlockCore

enum FaceImageProcessor {
    static func prepare(_ image: CGImage, context: CIContext) throws -> (pixels: CVPixelBuffer, quality: Float?, metrics: EnrollmentMetrics) {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        // Detect with revision 3 FIRST. Supplying that exact face to both following requests
        // avoids implicit legacy detection/cache reuse and keeps pose, quality and landmarks together.
        let detection = VNDetectFaceRectanglesRequest()
        detection.revision = VNDetectFaceRectanglesRequestRevision3
        try handler.perform([detection])
        let poseFace = try selectFace(detection.results ?? [])
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        request.inputFaceObservations = [poseFace]
        let quality = VNDetectFaceCaptureQualityRequest()
        quality.revision = VNDetectFaceCaptureQualityRequestRevision3
        quality.inputFaceObservations = [poseFace]
        try handler.perform([request, quality])
        let face = try selectFace(request.results ?? [])
        let points = try landmarks(face, width: image.width, height: image.height)
        let transform = try FaceAlignmentTransform.fit(source: points)
        let pixels = try render(image, transform: transform, context: context)
        let score = quality.results?.first?.faceCaptureQuality
        let metrics = try captureMetrics(face: face, poseFace: poseFace, quality: score,
                                         width: image.width, height: image.height, luminance: luminance(pixels))
        return (pixels, score, metrics)
    }

    static func captureMetrics(face: VNFaceObservation, poseFace: VNFaceObservation, quality: Float?,
                               width: Int, height: Int, luminance: Double) throws -> EnrollmentMetrics {
        guard let yaw = poseFace.yaw, let pitch = poseFace.pitch, let roll = poseFace.roll,
              sameFaceRegion(face.boundingBox, poseFace.boundingBox) else { throw RecognitionError.poseUnavailable }
        guard let quality else { throw RecognitionError.captureQualityUnavailable }
        // Use the current pose detector for framing, rather than the legacy landmark detector's
        // padded rectangle. Alignment still uses its original landmarks above.
        let box = poseFace.boundingBox
        let bounds = FaceBounds(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        return EnrollmentMetrics(quality: Double(quality), yaw: yaw.doubleValue, pitch: pitch.doubleValue,
            roll: roll.doubleValue, faceWidthPixels: box.width * Double(width),
            faceHeightPixels: box.height * Double(height),
            centered: EnrollmentFraming.isCentered(bounds, imageWidth: width, imageHeight: height),
            luminance: luminance, faceBounds: bounds)
    }

    static func sameFaceRegion(_ first: CGRect, _ second: CGRect) -> Bool {
        let intersection = first.intersection(second)
        let sharedArea = intersection.isNull ? 0 : intersection.width * intersection.height
        let union = first.width * first.height + second.width * second.height - sharedArea
        return sharedArea.isFinite && union.isFinite && union > 0 && sharedArea / union >= 0.4
    }

    private static func luminance(_ buffer: CVPixelBuffer) throws -> Double {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw RecognitionError.pixels }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { throw RecognitionError.pixels }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var sum = 0.0
        // Central aligned-face region; no per-pixel data leaves this function.
        for y in 24..<88 {
            for x in 24..<88 {
                let offset = y * stride + x * 4
                sum += 0.2126 * Double(base[offset + 2]) + 0.7152 * Double(base[offset + 1]) + 0.0722 * Double(base[offset])
            }
        }
        return sum / (64 * 64)
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
