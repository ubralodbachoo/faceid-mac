import ApplicationServices
import AVFoundation
import FaceUnlockCore

@MainActor
public struct MacReadinessProvider: ReadinessProviding {
    public init() {}

    public func inspect() -> ReadinessReport {
        // All unimplemented capabilities are omitted and therefore remain blocked.
        // Do not add placeholder implementations that return success.
        ReadinessReport(statuses: [
            .cameraPermission: cameraPermission,
            .accessibilityPermission: AXIsProcessTrusted() ? .available : .permissionRequired,
            .lockSession: .diagnosticOnly,
            .credentialVault: .diagnosticOnly,
            .passwordEntry: .diagnosticOnly,
            .faceRecognition: .diagnosticOnly
        ])
    }

    private var cameraPermission: ComponentStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .available
        case .notDetermined, .denied: .permissionRequired
        case .restricted: .unavailable
        @unknown default: .unavailable
        }
    }
}
