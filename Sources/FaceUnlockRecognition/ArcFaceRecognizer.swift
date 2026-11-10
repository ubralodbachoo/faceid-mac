import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation
import ImageIO
import FaceUnlockCore

public enum ArcFaceContract {
    public static let identifier = "insightface-w600k_mbf-glance-b97f5213-fp16-v1"
    public static let inputSize = 112
    public static let dimensions = 512
    public static let inputName = "input_image"
    public static let outputName = "embedding"
    public static let onnxSHA256 = "9cc6e4a75f0e2bf0b1aed94578f144d15175f357bdc05e815e5c4a02b319eb4f"
}

public enum RecognitionError: Error, LocalizedError {
    case missingModel, contract, reference, prediction, pixels, image, noFace, multipleFaces, landmarks
    case poseUnavailable, captureQualityUnavailable
    public var errorDescription: String? {
        switch self {
        case .missingModel: "ArcFace is missing. Fetch, validate and compile the pinned model before testing."
        case .contract: "The model input/output contract is incompatible. Recognition is disabled."
        case .reference: "ArcFace numerical validation failed or its reference fixture is incompatible."
        case .prediction: "Core ML did not produce a valid face embedding."
        case .pixels: "The aligned RGB image could not be prepared."
        case .image: "The selected image could not be decoded."
        case .noFace: "No face was detected."
        case .multipleFaces: "Exactly one face is required. Multiple faces were detected."
        case .landmarks: "Five usable landmarks were not found. A loose crop will not be used."
        case .poseUnavailable: "The camera detected your face but could not measure its angle. Face the camera and try a small head movement."
        case .captureQualityUnavailable: "The camera detected your face but could not measure capture quality. Try even light and keep your face visible."
        }
    }
}

public struct RecognitionCheckReport: Codable, Sendable {
    public let modelIdentifier: String
    public let dimensions: Int
    public let referenceCases: Int
    public let minimumReferenceCosine: Double
    public let loadMilliseconds: Double
    public let medianMilliseconds: Double
    public let p95Milliseconds: Double
    public let measuredPredictions: Int
    public let computeUnits: String
}

public struct FaceAnalysis: Sendable {
    public let embedding: FaceEmbedding
    public let quality: Float?
    public let inferenceMilliseconds: Double
    public let enrollmentMetrics: EnrollmentMetrics?
}

/// No dependency on credential storage or password submission. The model is actor-confined.
public actor ArcFaceRecognizer {
    private let modelURL: URL
    private var model: MLModel?
    private var loadMilliseconds = 0.0
    private var validated = false
    private let context = CIContext()

    public init(modelURL: URL) { self.modelURL = modelURL }

    private func load() throws -> MLModel {
        if let model { return model }
        guard modelURL.pathExtension == "mlmodelc", FileManager.default.fileExists(atPath: modelURL.path) else {
            throw RecognitionError.missingModel
        }
        let start = ProcessInfo.processInfo.systemUptime
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let loaded: MLModel
        do { loaded = try MLModel(contentsOf: modelURL, configuration: configuration) }
        catch { throw RecognitionError.contract }
        let description = loaded.modelDescription
        guard description.inputDescriptionsByName.count == 1,
              description.outputDescriptionsByName.count == 1,
              let input = description.inputDescriptionsByName[ArcFaceContract.inputName], input.type == .image,
              let constraint = input.imageConstraint, constraint.pixelsWide == 112, constraint.pixelsHigh == 112,
              constraint.pixelFormatType == kCVPixelFormatType_32BGRA,
              let output = description.outputDescriptionsByName[ArcFaceContract.outputName], output.type == .multiArray,
              let shape = output.multiArrayConstraint?.shape,
              shape.map(\.intValue) == [1, 512] else { throw RecognitionError.contract }
        model = loaded
        loadMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return loaded
    }

    /// Uses deterministic synthetic RGB only. Passing does not establish face accuracy or liveness.
    public func validateAndBenchmark(referenceURL: URL) throws -> RecognitionCheckReport {
        validated = false
        let model = try load()
        let reference: ReferenceFixture
        do { reference = try JSONDecoder().decode(ReferenceFixture.self, from: Data(contentsOf: referenceURL)) }
        catch { throw RecognitionError.reference }
        guard reference.schema == 1, reference.modelIdentifier == ArcFaceContract.identifier,
              reference.onnxSHA256 == ArcFaceContract.onnxSHA256,
              reference.minimumCosine == 0.999,
              reference.vectors.map(\.seed) == [0, 1, 7, 19, 113] else { throw RecognitionError.reference }
        var minimumCosine = 1.0
        for item in reference.vectors {
            try Task.checkCancellation()
            let buffer = try Self.syntheticPixels(seed: item.seed)
            let actual = try predict(buffer, model: model)
            let expected = try FaceEmbedding(raw: item.embedding, modelIdentifier: ArcFaceContract.identifier)
            let score = try actual.cosineSimilarity(to: expected)
            guard score > reference.minimumCosine else { throw RecognitionError.reference }
            minimumCosine = min(minimumCosine, score)
        }
        let buffer = try Self.syntheticPixels(seed: 7)
        for _ in 0..<3 { _ = try predict(buffer, model: model) }
        var durations: [Double] = []
        for _ in 0..<30 {
            try Task.checkCancellation()
            let start = ProcessInfo.processInfo.systemUptime
            _ = try predict(buffer, model: model)
            durations.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        durations.sort()
        validated = true
        return RecognitionCheckReport(
            modelIdentifier: ArcFaceContract.identifier, dimensions: 512, referenceCases: reference.vectors.count,
            minimumReferenceCosine: minimumCosine, loadMilliseconds: loadMilliseconds,
            medianMilliseconds: durations[durations.count / 2], p95Milliseconds: durations[28],
            measuredPredictions: durations.count, computeUnits: "all (Core ML chooses CPU/GPU/Neural Engine)"
        )
    }

    public func analyzeImage(at url: URL) throws -> FaceAnalysis {
        guard validated else { throw RecognitionError.reference }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw RecognitionError.image }
        return try analyze(image)
    }

    /// Camera and selected-image analysis share exactly the same detection/alignment/model path.
    public func analyze(_ image: CGImage) throws -> FaceAnalysis {
        guard validated else { throw RecognitionError.reference }
        try Task.checkCancellation()
        let prepared = try FaceImageProcessor.prepare(image, context: context)
        let start = ProcessInfo.processInfo.systemUptime
        let embedding = try predict(prepared.pixels, model: load())
        return FaceAnalysis(embedding: embedding, quality: prepared.quality,
                            inferenceMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000,
                            enrollmentMetrics: prepared.metrics)
    }

    private func predict(_ pixels: CVPixelBuffer, model: MLModel) throws -> FaceEmbedding {
        guard CVPixelBufferGetWidth(pixels) == 112, CVPixelBufferGetHeight(pixels) == 112,
              CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { throw RecognitionError.pixels }
        let features = try MLDictionaryFeatureProvider(dictionary: [ArcFaceContract.inputName: MLFeatureValue(pixelBuffer: pixels)])
        let prediction = try model.prediction(from: features)
        guard let array = prediction.featureValue(for: ArcFaceContract.outputName)?.multiArrayValue,
              array.count == 512 else { throw RecognitionError.prediction }
        return try FaceEmbedding(raw: (0..<512).map { array[$0].floatValue }, modelIdentifier: ArcFaceContract.identifier)
    }

    static func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, 112, 112, kCVPixelFormatType_32BGRA,
                                 attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else {
            throw RecognitionError.pixels
        }
        return buffer
    }

    static func syntheticPixels(seed: Int) throws -> CVPixelBuffer {
        guard (0...1000).contains(seed) else { throw RecognitionError.reference }
        let buffer = try makeBuffer()
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw RecognitionError.pixels }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { throw RecognitionError.pixels }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<112 {
            for x in 0..<112 {
                let offset = y * stride + x * 4
                base[offset] = UInt8((x * 53 + y * 7 + seed * 47) % 256)
                base[offset + 1] = UInt8((x * 11 + y * 43 + seed * 29) % 256)
                base[offset + 2] = UInt8((x * 37 + y * 17 + seed * 13) % 256)
                base[offset + 3] = 255
            }
        }
        return buffer
    }
}

private struct ReferenceFixture: Decodable {
    let schema: Int
    let modelIdentifier: String
    let onnxSHA256: String
    let minimumCosine: Double
    let vectors: [Vector]
    struct Vector: Decodable { let seed: Int; let embedding: [Float] }
}
