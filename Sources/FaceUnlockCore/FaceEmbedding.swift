import Foundation

public enum EmbeddingError: Error, LocalizedError {
    case dimensions, nonFinite, zeroNorm, modelMismatch
    public var errorDescription: String? {
        switch self {
        case .dimensions: "ArcFace must produce exactly 512 numbers."
        case .nonFinite: "The face model returned non-finite data."
        case .zeroNorm: "The face model returned an empty or zero-length descriptor."
        case .modelMismatch: "Embeddings from different model versions cannot be compared."
        }
    }
}

/// Identity descriptor only. A score cannot authorize authentication or establish liveness.
public struct FaceEmbedding: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let modelIdentifier: String
    public let values: [Float]
    public var dimensions: Int { values.count }
    public var description: String { "FaceEmbedding(model: \(modelIdentifier), dimensions: \(dimensions), values: redacted)" }
    public var debugDescription: String { description }

    public init(raw: [Float], modelIdentifier: String) throws {
        guard raw.count == 512 else { throw EmbeddingError.dimensions }
        guard raw.allSatisfy(\.isFinite) else { throw EmbeddingError.nonFinite }
        let norm = sqrt(raw.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 1e-12, !modelIdentifier.isEmpty else { throw EmbeddingError.zeroNorm }
        self.modelIdentifier = modelIdentifier
        values = raw.map { Float(Double($0) / norm) }
    }

    public func cosineSimilarity(to other: FaceEmbedding) throws -> Double {
        guard modelIdentifier == other.modelIdentifier else { throw EmbeddingError.modelMismatch }
        let score = zip(values, other.values).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        return min(1, max(-1, score))
    }
}
