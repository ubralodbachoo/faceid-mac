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

/// Retains configuration between captures. The sensor runs only during an active capture.
/// All session, delegate and lease mutations run on the same queue.
public final class EnrollmentCameraSession: @unchecked Sendable {
    let queue = DispatchQueue(label: "org.faceunlock.camera.session")
    let session = AVCaptureSession()
    fileprivate let context = CIContext(options: [.cacheIntermediates: false])
    private var output: AVCaptureVideoDataOutput?
    private var active: EnrollmentCamera?
    public init() {}

    func start(_ camera: EnrollmentCamera) {
        queue.async { [self] in
            guard !camera.stopped else { return }
            guard active == nil else { camera.complete(EnrollmentCameraError.unavailable); return }
            do {
                guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                    throw EnrollmentCameraError.unavailable
                }
                if output == nil {
                    guard let device = AVCaptureDevice.default(for: .video) else { throw EnrollmentCameraError.unavailable }
                    let input = try AVCaptureDeviceInput(device: device)
                    let candidate = AVCaptureVideoDataOutput()
                    candidate.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    candidate.alwaysDiscardsLateVideoFrames = true
                    session.beginConfiguration()
                    defer { session.commitConfiguration() }
                    session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .vga640x480
                    guard session.canAddInput(input), session.canAddOutput(candidate) else { throw EnrollmentCameraError.unavailable }
                    session.addInput(input); session.addOutput(candidate)
                    if let connection = candidate.connection(with: .video), connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = false
                    }
                    output = candidate
                }
                active = camera
                output?.setSampleBufferDelegate(camera, queue: queue)
                session.startRunning()
                queue.asyncAfter(deadline: .now() + 8) { [weak self, weak capture = camera] in
                    guard let self, let capture, active === capture, !capture.receivedFrame else { return }
                    finish(capture, error: EnrollmentCameraError.timeout)
                }
                queue.asyncAfter(deadline: .now() + 180) { [weak self, weak capture = camera] in
                    guard let self, let capture, active === capture else { return }
                    finish(capture, error: EnrollmentCameraError.timeout)
                }
            } catch { finish(camera, error: EnrollmentCameraError.unavailable) }
        }
    }

    func finish(_ camera: EnrollmentCamera, error: (any Error)? = nil) {
        // An old stream's cancellation/timeout can never stop a later capture.
        if active === camera {
            output?.setSampleBufferDelegate(nil, queue: nil)
            session.stopRunning()
            active = nil
        }
        camera.complete(error)
    }
}

/// One fresh bounded stream per capture, backed by a reusable configured session.
public final class EnrollmentCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let frames: AsyncThrowingStream<CGImage, any Error>
    private let continuation: AsyncThrowingStream<CGImage, any Error>.Continuation
    private let backend: EnrollmentCameraSession
    private let minimumFrameInterval: Double
    public var previewSession: AVCaptureSession { backend.session }
    fileprivate var stopped = false
    fileprivate var receivedFrame = false
    private var started = false
    private var lastFrameTime = -Double.infinity

    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    public override convenience init() { self.init(session: EnrollmentCameraSession()) }

    public init(session: EnrollmentCameraSession, minimumFrameInterval: Double = 0.09) {
        backend = session
        self.minimumFrameInterval = max(0, minimumFrameInterval)
        let pair = AsyncThrowingStream<CGImage, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        frames = pair.stream; continuation = pair.continuation
        super.init()
        continuation.onTermination = { [weak self] _ in self?.stop() }
    }

    public func start() {
        backend.queue.async { [self] in
            guard !started, !stopped else { return }
            started = true
            backend.start(self)
        }
    }

    public func stop() {
        backend.queue.async { [self] in backend.finish(self) }
    }

    public func stopAndWait() async {
        await withCheckedContinuation { continuation in
            backend.queue.async { [self] in
                backend.finish(self)
                continuation.resume()
            }
        }
    }

    fileprivate func complete(_ error: (any Error)?) {
        guard !stopped else { return }
        stopped = true
        continuation.finish(throwing: error)
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !stopped else { return }
        let time = ProcessInfo.processInfo.systemUptime
        guard time - lastFrameTime >= minimumFrameInterval else { return }
        lastFrameTime = time
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let image = Self.makeImage(from: buffer, context: backend.context) else { return }
        receivedFrame = true
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
