import AVFoundation
import CoreImage
import Foundation

public enum EnrollmentCameraError: Error, LocalizedError {
    case unavailable, timeout
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Camera permission or hardware is unavailable. Enrollment was not saved."
        case .timeout: "The camera capture session timed out. Enrollment was not saved."
        }
    }
}

/// Single-use, bounded camera capture. No audio, recording output, or disk-backed image is created.
/// Mutable session state is confined to queue; image conversion/throttling to frameQueue.
public final class EnrollmentCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let frames: AsyncThrowingStream<CGImage, any Error>
    private let continuation: AsyncThrowingStream<CGImage, any Error>.Continuation
    private let queue = DispatchQueue(label: "org.faceunlock.enrollment.camera")
    private let frameQueue = DispatchQueue(label: "org.faceunlock.enrollment.frames")
    private let context = CIContext(options: [.cacheIntermediates: false])
    public let previewSession = AVCaptureSession()
    private var stopped = false
    private var started = false
    private var receivedFrame = false
    private var lastFrameTime = -Double.infinity

    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    public override init() {
        let pair = AsyncThrowingStream<CGImage, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        frames = pair.stream
        continuation = pair.continuation
        super.init()
        continuation.onTermination = { [weak self] _ in self?.stop() }
    }

    public func start() {
        queue.async { [self] in
            guard !self.stopped, !self.started else { return }
            self.started = true
            do {
                guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                      let device = AVCaptureDevice.default(for: .video) else { throw EnrollmentCameraError.unavailable }
                let session = self.previewSession
                session.beginConfiguration()
                session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .vga640x480
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: self.frameQueue)
                guard session.canAddInput(input), session.canAddOutput(output) else { throw EnrollmentCameraError.unavailable }
                session.addInput(input); session.addOutput(output)
                if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
                session.commitConfiguration()
                session.startRunning()
                self.queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self, !self.receivedFrame else { return }
                    self.finish(EnrollmentCameraError.timeout)
                }
                self.queue.asyncAfter(deadline: .now() + 180) { [weak self] in self?.finish(EnrollmentCameraError.timeout) }
            } catch { self.finish(EnrollmentCameraError.unavailable) }
        }
    }

    public func stop() { queue.async { self.finish(nil) } }

    public func stopAndWait() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.finish(nil)
                self.frameQueue.async { continuation.resume() }
            }
        }
    }

    private func finish(_ error: (any Error)?) {
        guard !stopped else { return }
        stopped = true
        previewSession.stopRunning()
        previewSession.outputs.compactMap { $0 as? AVCaptureVideoDataOutput }.forEach { $0.setSampleBufferDelegate(nil, queue: nil) }
        continuation.finish(throwing: error)
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = ProcessInfo.processInfo.systemUptime
        // The native preview layer runs independently at the camera's rate. Analysis receives
        // a bounded latest-frame stream at up to 10 Hz, with no unbounded processing backlog.
        guard time - lastFrameTime >= 0.09 else { return }
        lastFrameTime = time
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // createCGImage materializes a bounded frame. Neither CMSampleBuffer nor CVPixelBuffer is retained.
        guard let image = Self.makeImage(from: buffer, context: context) else { return }
        queue.async { self.receivedFrame = true }
        continuation.yield(image)
    }

    static func makeImage(from buffer: CVPixelBuffer, context: CIContext) -> CGImage? {
        var source = CIImage(cvPixelBuffer: buffer)
        let edge = max(source.extent.width, source.extent.height)
        if edge > 640 { source = source.transformed(by: CGAffineTransform(scaleX: 640 / edge, y: 640 / edge)) }
        return context.createCGImage(source, from: source.extent, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB), deferred: false)
    }
}
