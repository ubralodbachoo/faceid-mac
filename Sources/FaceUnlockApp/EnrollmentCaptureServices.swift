import AppKit
import AVFoundation
import FaceUnlockRecognition

@MainActor
protocol EnrollmentCapturing {
    var previewSessionForUI: AVCaptureSession? { get }
    var frames: AsyncThrowingStream<CGImage, any Error> { get }
    func start()
    func stop()
    func stopAndWait() async
}

extension EnrollmentCapturing {
    var previewSessionForUI: AVCaptureSession? { nil }
}

// The stable capture-session reference is handed to a native preview layer; camera mutations
// remain on EnrollmentCamera's session queue.
extension EnrollmentCamera: EnrollmentCapturing {
    var previewSessionForUI: AVCaptureSession? { previewSession }
}

typealias EnrollmentImageAnalyzer = @MainActor (CGImage) async throws -> FaceAnalysis

/// The live implementation always validates the real bundled model before camera capture.
/// Injectable boundaries let tests drive cancellation and camera feedback without using a camera.
@MainActor
struct EnrollmentCaptureServices {
    private static let cameraSession = EnrollmentCameraSession()
    private static var captureRecognizer: ArcFaceRecognizer?
    let prepare: () async throws -> EnrollmentImageAnalyzer
    let requestPermission: () async -> Bool
    let permissionDenied: () -> Bool
    let makeCamera: () -> any EnrollmentCapturing
    let now: () -> Double

    static var live: Self { live(minimumFrameInterval: 0.09) }
    static var comparison: Self { live(minimumFrameInterval: 0) }

    private static func live(minimumFrameInterval: Double) -> Self {
        Self(prepare: {
            guard let model = Bundle.main.url(forResource: "ArcFace", withExtension: "mlmodelc"),
                  let reference = Bundle.main.url(forResource: "ArcFaceReference", withExtension: "json") else {
                throw RecognitionError.missingModel
            }
            let recognizer = captureRecognizer ?? ArcFaceRecognizer(modelURL: model)
            captureRecognizer = recognizer
            _ = try await recognizer.prepareForCapture(referenceURL: reference)
            return { image in try await recognizer.analyze(image) }
        }, requestPermission: { await EnrollmentCamera.requestPermission() },
           permissionDenied: { AVCaptureDevice.authorizationStatus(for: .video) == .denied },
           makeCamera: { EnrollmentCamera(session: cameraSession, minimumFrameInterval: minimumFrameInterval) }, now: { ProcessInfo.processInfo.systemUptime })
    }
}
