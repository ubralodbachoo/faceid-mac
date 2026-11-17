import CoreGraphics
import CoreML
import Foundation

public enum PassivePADContract {
    public static let identifier = "minivision-minifasnet-pair-b6d5f04-fp32-v1"
    public static let inputSize = 80
    public static let liveIndex = 1
}

/// Raw model outputs for evaluation only. They do not authorize password access.
public struct PassivePADScores: Sendable, CustomStringConvertible {
    public let nearLive: Double
    public let wideLive: Double
    public let inferenceMilliseconds: Double
    public var minimumLive: Double { min(nearLive, wideLive) }
    public var description: String { "PassivePADScores(evaluation values: redacted)" }

    public init(nearLive: Double, wideLive: Double, inferenceMilliseconds: Double) throws {
        guard nearLive.isFinite, wideLive.isFinite, (0...1).contains(nearLive), (0...1).contains(wideLive),
              inferenceMilliseconds.isFinite, inferenceMilliseconds >= 0 else { throw RecognitionError.passivePADContract }
        self.nearLive = nearLive; self.wideLive = wideLive; self.inferenceMilliseconds = inferenceMilliseconds
    }
}

/// Actor-confined by ArcFaceRecognizer. No camera, template or credential-store access.
final class PassivePADModel {
    private let model: MLModel
    private var validated = false

    init(url: URL) throws {
        guard url.pathExtension == "mlmodelc", FileManager.default.fileExists(atPath: url.path) else {
            throw RecognitionError.missingPassivePAD
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        do { model = try MLModel(contentsOf: url, configuration: configuration) }
        catch { throw RecognitionError.passivePADContract }
        let description = model.modelDescription
        guard Set(description.inputDescriptionsByName.keys) == ["crop27", "crop40"],
              Set(description.outputDescriptionsByName.keys) == ["probabilities"] else { throw RecognitionError.passivePADContract }
        for input in description.inputDescriptionsByName.values {
            guard input.type == .multiArray, input.multiArrayConstraint?.shape.map(\.intValue) == [1, 3, 80, 80],
                  input.multiArrayConstraint?.dataType == .float32 else { throw RecognitionError.passivePADContract }
        }
        guard let output = description.outputDescriptionsByName["probabilities"], output.type == .multiArray,
              output.multiArrayConstraint?.shape.map(\.intValue) == [1, 2, 3] else { throw RecognitionError.passivePADContract }
    }

    func validate(referenceURL: URL) throws {
        validated = false
        let reference: Reference
        do { reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: referenceURL)) }
        catch { throw RecognitionError.passivePADReference }
        guard reference.schema == 1, reference.modelIdentifier == PassivePADContract.identifier,
              reference.maximumAbsoluteError == 0.001, reference.cases.map(\.seed) == [0, 1, 7, 19, 113] else {
            throw RecognitionError.passivePADReference
        }
        for sample in reference.cases {
            try Task.checkCancellation()
            let values = try predict(PassivePADPixels.synthetic(seed: sample.seed), PassivePADPixels.synthetic(seed: sample.seed + 1))
            guard sample.probabilities.count == 6,
                  zip(values, sample.probabilities).allSatisfy({ $0.isFinite && $1.isFinite && abs($0 - $1) < 0.001 }) else {
                throw RecognitionError.passivePADReference
            }
        }
        validated = true
    }

    func analyze(_ image: CGImage, face: CGRect) throws -> PassivePADScores {
        guard validated else { throw RecognitionError.passivePADReference }
        let near = try PassivePADPixels.tensor(image: image, face: face, scale: 2.7)
        let wide = try PassivePADPixels.tensor(image: image, face: face, scale: 4)
        try Task.checkCancellation()
        let started = ProcessInfo.processInfo.systemUptime
        let values = try predict(near, wide)
        return try PassivePADScores(nearLive: values[1], wideLive: values[4],
            inferenceMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000)
    }

    private func predict(_ near: MLMultiArray, _ wide: MLMultiArray) throws -> [Double] {
        let provider = try MLDictionaryFeatureProvider(dictionary: ["crop27": MLFeatureValue(multiArray: near),
                                                                   "crop40": MLFeatureValue(multiArray: wide)])
        let prediction = try model.prediction(from: provider)
        guard let output = prediction.featureValue(for: "probabilities")?.multiArrayValue,
              output.shape.map(\.intValue) == [1, 2, 3] else { throw RecognitionError.passivePADContract }
        let values = (0..<6).map { output[$0].doubleValue }
        guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              abs(values[0...2].reduce(0, +) - 1) < 0.001,
              abs(values[3...5].reduce(0, +) - 1) < 0.001 else { throw RecognitionError.passivePADContract }
        return values
    }

    private struct Reference: Decodable {
        let schema: Int
        let modelIdentifier: String
        let maximumAbsoluteError: Double
        let cases: [Sample]
        struct Sample: Decodable { let seed: Int; let probabilities: [Double] }
    }
}
