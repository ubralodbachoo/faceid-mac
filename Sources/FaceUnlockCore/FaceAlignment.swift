import Foundation

public struct FacePoint: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Uniform scale + rotation + translation in top-left image coordinates; no reflection.
public struct FaceAlignmentTransform: Sendable {
    public let a: Double
    public let b: Double
    public let tx: Double
    public let ty: Double

    public func apply(_ point: FacePoint) -> FacePoint {
        FacePoint(x: a * point.x - b * point.y + tx, y: b * point.x + a * point.y + ty)
    }

    public static func fit(source: [FacePoint], target: [FacePoint] = arcFaceTemplate) throws -> Self {
        guard source.count == 5, target.count == 5,
              (source + target).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw AlignmentError.landmarks }
        let sourceCenter = center(source), targetCenter = center(target)
        var denominator = 0.0, numeratorA = 0.0, numeratorB = 0.0
        for (source, target) in zip(source, target) {
            let sx = source.x - sourceCenter.x, sy = source.y - sourceCenter.y
            let dx = target.x - targetCenter.x, dy = target.y - targetCenter.y
            denominator += sx * sx + sy * sy
            numeratorA += sx * dx + sy * dy
            numeratorB += sx * dy - sy * dx
        }
        guard denominator > 1e-8 else { throw AlignmentError.degenerate }
        let a = numeratorA / denominator, b = numeratorB / denominator
        guard a.isFinite, b.isFinite, a * a + b * b > 1e-12 else { throw AlignmentError.degenerate }
        return Self(a: a, b: b,
                    tx: targetCenter.x - a * sourceCenter.x + b * sourceCenter.y,
                    ty: targetCenter.y - b * sourceCenter.x - a * sourceCenter.y)
    }

    public static let arcFaceTemplate: [FacePoint] = [
        FacePoint(x: 38.2946, y: 51.6963), FacePoint(x: 73.5318, y: 51.5014),
        FacePoint(x: 56.0252, y: 71.7366), FacePoint(x: 41.5493, y: 92.3655),
        FacePoint(x: 70.7299, y: 92.2041)
    ]

    private static func center(_ points: [FacePoint]) -> FacePoint {
        FacePoint(x: points.reduce(0) { $0 + $1.x } / Double(points.count),
                  y: points.reduce(0) { $0 + $1.y } / Double(points.count))
    }
}

public enum AlignmentError: Error, LocalizedError {
    case landmarks, degenerate
    public var errorDescription: String? {
        switch self {
        case .landmarks: "Five valid face landmarks are required. No loose-crop fallback is used."
        case .degenerate: "Face landmarks cannot define a stable alignment."
        }
    }
}
