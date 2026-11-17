import CoreGraphics

/// Counts only; safe to include in operational reports. No rectangles or face coordinates leave memory.
public struct DeviceRectangleDiagnostics: Codable, Sendable {
    public var candidates = 0
    public var qualifying = 0
    public var ignoredPartial = 0
    public var ignoredBackground = 0
    public var ignoredTight = 0
    public var ignoredInvalid = 0

    public init() {}
}

enum DeviceRectangleAssessment {
    case qualifying(CGFloat), partial, background, tight, invalid
}

enum DeviceRectangleGeometry {
    /// Overlap alone cannot identify a device: an eye-sized detail, door or monitor can overlap a face.
    /// A candidate must enclose almost all of the face, with a plausible face-to-display area ratio.
    /// These are experimental geometry bounds, not a calibrated device classifier.
    static func assess(_ rectangle: CGRect, face: CGRect) -> DeviceRectangleAssessment {
        guard [rectangle.minX, rectangle.minY, rectangle.width, rectangle.height,
               face.minX, face.minY, face.width, face.height].allSatisfy(\.isFinite),
              rectangle.width > 0, rectangle.height > 0, face.width > 0, face.height > 0 else { return .invalid }
        let faceArea = face.width * face.height
        let rectangleArea = rectangle.width * rectangle.height
        guard faceArea.isFinite, rectangleArea.isFinite, faceArea > 0, rectangleArea > 0 else { return .invalid }
        let intersection = rectangle.intersection(face)
        let overlap = intersection.isNull ? 0 : intersection.width * intersection.height / faceArea
        guard overlap >= 0.9 else { return .partial }
        let faceFraction = faceArea / rectangleArea
        guard faceFraction >= 0.2 else { return .background }
        guard faceFraction <= 0.8,
              rectangle.width >= face.width * 1.05, rectangle.height >= face.height * 1.05 else { return .tight }
        return .qualifying(min(overlap, 1))
    }

    static func measure(_ rectangles: [CGRect], face: CGRect) -> (overlap: CGFloat, diagnostic: DeviceRectangleDiagnostics) {
        var diagnostic = DeviceRectangleDiagnostics()
        var overlap: CGFloat = 0
        for rectangle in rectangles {
            diagnostic.candidates += 1
            switch assess(rectangle, face: face) {
            case .qualifying(let coverage): diagnostic.qualifying += 1; overlap = max(overlap, coverage)
            case .partial: diagnostic.ignoredPartial += 1
            case .background: diagnostic.ignoredBackground += 1
            case .tight: diagnostic.ignoredTight += 1
            case .invalid: diagnostic.ignoredInvalid += 1
            }
        }
        return (overlap, diagnostic)
    }
}
