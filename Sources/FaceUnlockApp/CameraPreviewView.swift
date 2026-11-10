import AppKit
import AVFoundation
import SwiftUI

/// Native camera rendering is independent of Vision/Core ML latency. It never records a movie.
struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewSurface { PreviewSurface() }

    func updateNSView(_ view: PreviewSurface, context: Context) {
        if view.previewLayer.session !== session { view.previewLayer.session = session }
        if let connection = view.previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }

    static func dismantleNSView(_ view: PreviewSurface, coordinator: ()) { view.previewLayer.session = nil }

    final class PreviewSurface: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            previewLayer.videoGravity = .resizeAspectFill
            layer = previewLayer
        }
        required init?(coder: NSCoder) { nil }
        override func layout() { super.layout(); previewLayer.frame = bounds }
    }
}
