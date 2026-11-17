import FaceUnlockCore
import FaceUnlockRecognition
import FaceUnlockMac
import Foundation

enum LockScreenLivenessMode { case heavy, passive }

struct LockScreenScanResult {
    let comparison: FaceComparisonOutcome
    let verification: UnlockVerification
}

/// Camera frames never enter published UI state, an image view, or disk storage.
@MainActor
final class LockScreenFaceScanner {
    private let services: EnrollmentCaptureServices
    private let now: () -> Double
    private let livenessMode: LockScreenLivenessMode
    private let mode: FaceComparisonMode
    private var camera: (any EnrollmentCapturing)?
    private var analyze: EnrollmentImageAnalyzer?
    private(set) var diagnostics = LockScreenCaptureDiagnostics()

    init(services: EnrollmentCaptureServices = .lockScreen, mode: FaceComparisonMode = .standard,
         livenessMode: LockScreenLivenessMode = .passive,
         now: @escaping () -> Double = { ContinuousTime.now }) {
        self.services = services; self.mode = mode; self.livenessMode = livenessMode; self.now = now
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
        diagnostics.requiredMatchFrames = mode.requiredFrames
        var window = try FaceComparisonWindow(template: template, mode: mode)
        var liveness = HeavyLivenessGate()
        var passive = PassivePADEvaluationWindow()
        diagnostics.livenessMode = livenessMode == .passive ? "passive-pair" : "heavy"
        var lastAnalysisAt: Double?
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
                // Sample liveness independently of identity voting; no movement is needed in passive mode.
                // Identity still uses its unchanged 150 ms vote spacing inside observe().
                if let lastAnalysisAt, frameTime > lastAnalysisAt, frameTime - lastAnalysisAt < 0.05 {
                    diagnostics.scheduledOutFrames += 1
                    continue
                }
                lastAnalysisAt = frameTime
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
                        window.interrupt(); liveness.reset(); passive.reset(); diagnostics.usableFrames = 0; continue
                    }
                    guard let metrics = analysis.enrollmentMetrics else {
                        diagnostics.lastQualityHint = "Face angle and capture quality unavailable."
                        reject(.quality)
                        window.interrupt(); liveness.reset(); passive.reset(); diagnostics.usableFrames = 0; continue
                    }
                    if let hint = FaceComparisonWindow.adjustment(for: metrics) {
                        diagnostics.lastQualityHint = hint
                        reject(.quality)
                        window.interrupt(); liveness.reset(); passive.reset(); diagnostics.usableFrames = 0; continue
                    }
                    let previousGeneration = window.continuityGeneration
                    let result = try window.observe(analysis.embedding, metrics: metrics, at: frameTime)
                    if window.continuityGeneration != previousGeneration { liveness.reset(); passive.reset() }
                    let live: ExperimentalLivenessDecision
                    let livenessTime: Double?
                    switch livenessMode {
                    case .heavy:
                        live = liveness.observe(analysis.livenessFrame, at: frameTime)
                        livenessTime = liveness.evidenceObservedAt
                        diagnostics.livenessCue = liveness.cue
                    case .passive:
                        switch passive.observe(analysis.passivePAD, at: frameTime) {
                        case .liveCandidate: live = .passed
                        case .spoofCandidate: live = .rejected
                        case .uncertain: live = .pending
                        case .unavailable: live = .unavailable
                        }
                        livenessTime = passive.evidenceObservedAt
                        diagnostics.livenessCue = "passivePair"
                    }
                    diagnostics.deviceRectangles = analysis.livenessFrame?.deviceDiagnostics
                    diagnostics.livenessDecision = live.rawValue
                    if live == .rejected {
                        diagnostics.lastIssue = .liveness
                        throw FaceUnlockAttemptError.liveness
                    }
                    diagnostics.usableFrames = window.count; diagnostics.lastIssue = .usable
                    diagnostics.peakUsableFrames = max(diagnostics.peakUsableFrames, window.count)
                    guard let result else { continue }
                    diagnostics.comparisonCounts[result.outcome.rawValue, default: 0] += 1
                    // A completed nonmatching window ends this attempt. Never open the prompt.
                    guard result.outcome == .similar else {
                        diagnostics.lastIssue = result.outcome == .different ? .different : .borderline
                        throw FaceUnlockAttemptError.identity
                    }
                    guard live == .passed, let livenessTime else {
                        diagnostics.livenessWaitFrames += 1
                        diagnostics.lastIssue = .liveness
                        continue
                    }
                    try Task.checkCancellation(); try check()
                    guard try readyToReturn() else {
                        diagnostics.passwordFieldWaitFrames += 1
                        continue
                    }
                    try Task.checkCancellation(); try check()
                    let evidenceTime = min(frameTime, livenessTime)
                    guard now() - evidenceTime <= FaceUnlockAttempt.evidenceMaximumAge else {
                        reject(.staleAnalysis); window.interrupt(); liveness.reset(); passive.reset(); diagnostics.usableFrames = 0; continue
                    }
                    // Request shutdown immediately; join it after the guarded input path. Waiting
                    // for stopRunning here used up the match's 750 ms freshness allowance.
                    capture.stop()
                    // Experimental RGB model evidence remains distinct from evaluated biometric/PAD verification.
                    return LockScreenScanResult(comparison: result.outcome,
                        verification: UnlockVerification(attemptID: attemptID,
                            identity: result.outcome == .similar ? .experimentalMatch : .rejected,
                            liveness: .experimentalLiveness, observedAt: evidenceTime))
                } catch let error as RecognitionError {
                    switch error {
                    case .noFace, .multipleFaces, .landmarks, .poseUnavailable, .captureQualityUnavailable:
                        reject(error == .noFace ? .noFace : error == .multipleFaces ? .multipleFaces : .pose)
                        window.interrupt()
                        liveness.reset(); passive.reset()
                        diagnostics.livenessDecision = ExperimentalLivenessDecision.unavailable.rawValue
                        diagnostics.livenessCue = nil
                        diagnostics.usableFrames = 0
                    default: throw error
                    }
                }
            }
            if let result = window.result, result.outcome != .similar { throw FaceUnlockAttemptError.identity }
            if diagnostics.livenessWaitFrames > 0 { throw FaceUnlockAttemptError.liveness }
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
