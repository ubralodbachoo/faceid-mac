import Darwin
import Foundation
import FaceUnlockCore
import FaceUnlockMac
import FaceUnlockRecognition

enum LockScreenCaptureIssue: String, Codable, Sendable {
    case starting, usable, noFace, multipleFaces, pose, quality, staleAnalysis, different, borderline
}

struct LockScreenCaptureDiagnostics: Codable, Sendable {
    var analyzedFrames = 0
    var rejectedFrames = 0
    var usableFrames = 0
    var lastIssue = LockScreenCaptureIssue.starting
}

enum LockScreenFailure: String, Codable, Sendable {
    case scanOnly, identity, liveness, timeout, session, credentials, focus, accessibility
    case staleEvidence, camera, input, unconfirmed, canceled, setup

    var caption: String {
        switch self {
        case .scanOnly: "Scan-only mode"
        case .identity: "Face not recognized"
        case .liveness: "Liveness not verified"
        case .timeout: "Scan timed out"
        case .session: "Session changed"
        case .credentials: "Password authorization needed"
        case .focus: "Password field not ready"
        case .accessibility: "Accessibility needed"
        case .staleEvidence: "Match expired before input"
        case .camera: "Camera unavailable"
        case .input: "Password input stopped"
        case .unconfirmed: "Unlock not confirmed"
        case .canceled: "Scan canceled"
        case .setup: "Setup did not complete"
        }
    }

    static func classify(_ error: any Error) -> Self {
        if error is CancellationError { return .canceled }
        if let error = error as? FaceUnlockAttemptError {
            switch error {
            case .expired: return .timeout
            case .consumed: return .input
            case .session: return .session
            case .identity: return .identity
            case .liveness: return .liveness
            case .staleEvidence: return .staleEvidence
            case .credentials: return .credentials
            case .focus: return .focus
            }
        }
        if let error = error as? InputError {
            switch error {
            case .accessibility: return .accessibility
            case .target, .field: return .focus
            case .changed: return .session
            case .event: return .input
            }
        }
        if error is VaultError || error is EnrollmentError { return .credentials }
        if error is EnrollmentCameraError || error is RecognitionError { return .camera }
        return .setup
    }
}

/// One local operational report. Deliberately excludes images, embeddings, scores, account IDs and secrets.
struct LockScreenDiagnosticReport: Codable, Sendable {
    let schema: Int
    let recordedAt: Date
    let appVersion: String
    let mode: String
    let stage: LockScreenPhase
    let outcome: LockScreenPhase
    let failure: LockScreenFailure?
    let inputConsumed: Bool
    let passwordSubmitted: Bool
    let evidenceAgeMilliseconds: Double?
    let capture: LockScreenCaptureDiagnostics
}

/// Serial, atomic, private storage; disk I/O never runs on the fresh-evidence/password-input path.
final class LockScreenReportStore: @unchecked Sendable {
    let directory: URL
    var file: URL { directory.appendingPathComponent("last-lock-attempt.json") }
    private let queue = DispatchQueue(label: "org.faceunlock.last-attempt-report")

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("FaceUnlockDevelopment", isDirectory: true)) {
        self.directory = directory
    }

    func save(_ report: LockScreenDiagnosticReport) {
        queue.async { [self] in try? write(report) }
    }

    func waitForPendingWrites() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    private func write(_ report: LockScreenDiagnosticReport) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw VaultError.storage }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if manager.fileExists(atPath: file.path) {
            let old = try manager.attributesOfItem(atPath: file.path)
            guard old[.type] as? FileAttributeType == .typeRegular,
                  (old[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw VaultError.storage }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let temporary = directory.appendingPathComponent(".lock-report-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(temporary.path, file.path) == 0 else { throw VaultError.storage }
    }
}
