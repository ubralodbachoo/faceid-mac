import AVFoundation
import Foundation

/// Queue-confined worker. Frames are discarded in the callback and never exported or saved.
private final class CameraProbeWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.faceunlock.development.camera-probe")
    private let frameQueue = DispatchQueue(label: "org.faceunlock.development.camera-frames")
    private var session: AVCaptureSession?
    private var canceled = false
    private var continuation: CheckedContinuation<Void, any Error>?

    func run() async throws {
        try await withTaskCancellationHandler {
            try await runOnQueue()
        } onCancel: {
            self.queue.async { self.canceled = true; self.finish(.failure(CancellationError())) }
        }
    }

    private func runOnQueue() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                guard !self.canceled else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                do {
                    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                          let device = AVCaptureDevice.default(for: .video) else { throw ProbeError.unavailable }
                    let session = AVCaptureSession()
                    session.beginConfiguration()
                    session.sessionPreset = .low
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    output.setSampleBufferDelegate(self, queue: self.frameQueue)
                    guard session.canAddInput(input), session.canAddOutput(output) else { throw ProbeError.unavailable }
                    session.addInput(input)
                    session.addOutput(output)
                    session.commitConfiguration()
                    self.session = session
                    session.startRunning()
                    self.queue.asyncAfter(deadline: .now() + 4) { self.finish(.failure(ProbeError.timeout)) }
                } catch { self.finish(.failure(ProbeError.unavailable)) }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Do not stop a capture session from its output delegate queue. No sample buffer is retained.
        queue.async { self.finish(.success(())) }
    }

    private func finish(_ result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session?.stopRunning()
        session = nil
        continuation.resume(with: result)
    }
}

enum ProbeError: Error, LocalizedError {
    case unavailable, timeout
    var errorDescription: String? {
        switch self {
        case .unavailable: "Camera permission or hardware is unavailable. No microphone is used."
        case .timeout: "No camera frame arrived within the probe window."
        }
    }
}

@MainActor
enum LockedCameraProbe {
    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    static func captureOneFrame() async throws {
        try await CameraProbeWorker().run()
    }
}
