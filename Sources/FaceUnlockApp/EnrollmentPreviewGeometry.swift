import CoreGraphics
import FaceUnlockCore

/// The preview and overlays use one aspect-fit image viewport, including letterboxing.
/// Vision coordinates are converted to top-left by the recognition layer; mirror display once.
enum EnrollmentPreviewGeometry {
    static func viewport(imageWidth: Int, imageHeight: Int, container: CGSize) -> CGRect {
        guard imageWidth > 0, imageHeight > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / Double(imageWidth), container.height / Double(imageHeight))
        let size = CGSize(width: Double(imageWidth) * scale, height: Double(imageHeight) * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    static func rect(_ face: FaceBounds, viewport: CGRect, mirrored: Bool = false) -> CGRect {
        let bounds = mirrored ? face.mirrored : face
        return CGRect(x: viewport.minX + bounds.x * viewport.width, y: viewport.minY + bounds.y * viewport.height,
                      width: bounds.width * viewport.width, height: bounds.height * viewport.height)
    }
}
