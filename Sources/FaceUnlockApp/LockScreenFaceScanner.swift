import FaceUnlockCore
import FaceUnlockRecognition
import FaceUnlockMac
import Foundation

struct LockScreenScanResult {
    let comparison: FaceComparisonOutcome
    let verification: UnlockVerification
}

/// Camera frames never enter published UI state, an image view, or disk storage.
@MainActor
final class LockScreenFaceScanner {
    private let services: EnrollmentCaptureServices
    private let now: () -> Double
    private var camera: (any EnrollmentCapturing)?
    private var analyze: EnrollmentImageAnalyzer?
    private(set) var diagnostics = LockScreenCaptureDiagnostics()

    init(services: EnrollmentCaptureServices = .comparison, now: @escaping () -> Double = { ContinuousTime.now }) {
        self.services = services; self.now = now
    }

    func prepare() async throws {
        analyze = try await services.prepare()
        guard await services.requestPermission() else { throw EnrollmentCameraError.unavailable }
    }

    func stop() { camera?.stop() }

    func finish() async {
        guard let capture = camera else { return }
        await capture.stopAndWait()
        camera = nil
    }

    func scan(template: EnrollmentTemplate, attemptID: UUID,
              check: @MainActor () throws -> Void,
              readyToReturn: @MainActor () throws -> Bool = { true }) async throws -> LockScreenScanResult {
        guard let analyze else { throw RecognitionError.reference }
        try check()
        diagnostics = LockScreenCaptureDiagnostics()
        var window = try FaceComparisonWindow(template: template)
        let capture = services.makeCamera()
        camera = capture
        let startedAt = now()
        var firstFrameAt: Double?
        var analysisTotal = 0.0
        var analysisCompleted = 0
        capture.start()
        do {
            for try await image in capture.frames {
                try Task.checkCancellation(); try check()
                let frameTime = now()
                if firstFrameAt == nil {
                    firstFrameAt = frameTime
                    diagnostics.cameraStartupMilliseconds = max(0, (frameTime - startedAt) * 1000)
                }
                guard window.shouldAnalyze(at: frameTime) else {
                    diagnostics.scheduledOutFrames += 1
                    continue
                }
                do {
                    diagnostics.analyzedFrames += 1
                    let analysis = try await analyze(image)
                    try Task.checkCancellation(); try check()
                    let elapsed = now() - frameTime
                    analysisCompleted += 1
                    analysisTotal += max(0, elapsed * 1000)
                    diagnostics.meanAnalysisMilliseconds = analysisTotal / Double(analysisCompleted)
                    diagnostics.scanMilliseconds = max(0, (now() - (firstFrameAt ?? startedAt)) * 1000)
                    guard elapsed.isFinite, elapsed >= 0, elapsed <= FaceUnlockAttempt.evidenceMaximumAge else {
                        reject(.staleAnalysis)
                        window.interrupt(); diagnostics.usableFrames = 0; continue
                    }
                    guard let metrics = analysis.enrollmentMetrics else {
                        diagnostics.lastQualityHint = "Face angle and capture quality unavailable."
                        reject(.quality)
                        window.interrupt(); diagnostics.usableFrames = 0; continue
                    }
                    if let hint = FaceComparisonWindow.adjustment(for: metrics) {
                        diagnostics.lastQualityHint = hint
                        reject(.quality)
                        window.interrupt(); diagnostics.usableFrames = 0; continue
                    }
                    let result = try window.observe(analysis.embedding, metrics: metrics, at: frameTime)
                    diagnostics.usableFrames = window.count; diagnostics.lastIssue = .usable
                    diagnostics.peakUsableFrames = max(diagnostics.peakUsableFrames, window.count)
                    guard let result else { continue }
                    diagnostics.comparisonCounts[result.outcome.rawValue, default: 0] += 1
                    // Warm-up/poor initial frames cannot end a still-eligible scan early.
                    guard result.outcome == .similar else {
                        diagnostics.lastIssue = result.outcome == .different ? .different : .borderline
                        continue
                    }
                    try Task.checkCancellation(); try check()
                    guard try readyToReturn() else {
                        diagnostics.passwordFieldWaitFrames += 1
                        continue
                    }
                    try Task.checkCancellation(); try check()
                    guard now() - frameTime <= FaceUnlockAttempt.evidenceMaximumAge else {
                        reject(.staleAnalysis); window.interrupt(); diagnostics.usableFrames = 0; continue
                    }
                    // Request shutdown immediately; join it after the guarded input path. Waiting
                    // for stopRunning here used up the match's 750 ms freshness allowance.
                    capture.stop()
                    // Explicit experimental evidence only; this never fabricates liveness.
                    return LockScreenScanResult(comparison: result.outcome,
                        verification: UnlockVerification(attemptID: attemptID,
                            identity: result.outcome == .similar ? .experimentalMatch : .rejected,
                            liveness: .unavailable, observedAt: frameTime))
                } catch let error as RecognitionError {
                    switch error {
                    case .noFace, .multipleFaces, .landmarks, .poseUnavailable, .captureQualityUnavailable:
                        reject(error == .noFace ? .noFace : error == .multipleFaces ? .multipleFaces : .pose)
                        window.interrupt()
                        diagnostics.usableFrames = 0
                    default: throw error
                    }
                }
            }
            if let result = window.result, result.outcome != .similar { throw FaceUnlockAttemptError.identity }
            throw EnrollmentCameraError.unavailable
        } catch {
            await capture.stopAndWait()
            camera = nil
            throw error
        }
    }
    private func reject(_ issue: LockScreenCaptureIssue) {
        diagnostics.rejectedFrames += 1
        diagnostics.lastIssue = issue
        diagnostics.rejectionCounts[issue.rawValue, default: 0] += 1
    }

}
