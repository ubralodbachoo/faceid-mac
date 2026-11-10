import Foundation

/// Normalized, top-left image coordinates. Transient capture geometry, never a face template.
public struct FaceBounds: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
    public var isClipped: Bool { !isValid || x < 0 || y < 0 || x + width > 1 || y + height > 1 }
    public var mirrored: Self { Self(x: 1 - x - width, y: y, width: width, height: height) }
}

/// One shared guide for display and collection. Centering is independent of bounding-box
/// padding; clipping is a separate, actionable check instead of being called "off center".
public enum EnrollmentFraming {
    public static func guide(imageWidth: Int = 640, imageHeight: Int = 480) -> FaceBounds {
        guard imageWidth > 0, imageHeight > 0 else { return FaceBounds(x: 0, y: 0, width: 0, height: 0) }
        let imageAspect = Double(imageWidth) / Double(imageHeight)
        let ovalAspect = 190.0 / 244.0
        let height = min(0.78, 0.66 * imageAspect / ovalAspect)
        let width = height * ovalAspect / imageAspect
        return FaceBounds(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    public static func isCentered(_ face: FaceBounds, imageWidth: Int = 640, imageHeight: Int = 480) -> Bool {
        guard face.isValid else { return false }
        let guide = guide(imageWidth: imageWidth, imageHeight: imageHeight)
        guard guide.isValid else { return false }
        let dx = (face.x + face.width / 2 - 0.5) / (guide.width / 2)
        let dy = (face.y + face.height / 2 - 0.5) / (guide.height / 2)
        return dx * dx + dy * dy <= 0.75 * 0.75
    }
}
