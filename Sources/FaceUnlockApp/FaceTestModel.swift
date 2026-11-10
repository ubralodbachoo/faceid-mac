import AppKit
import AVFoundation
import Combine
import FaceUnlockCore
import FaceUnlockMac
import FaceUnlockRecognition

@MainActor
protocol FaceTestTemplateReading {
    var sessionIsValid: Bool { get }
    func authorizeReading() async throws
    func templateForVerification() throws -> EnrollmentTemplate
    func lock()
}

extension EnrollmentVault: FaceTestTemplateReading {}

enum FaceTestPhase { case idle, authorizing, preparing, capturing, finished, failed }

@MainActor
final class FaceTestModel: ObservableObject {
    @Published private(set) var phase: FaceTestPhase = .idle
    @Published private(set) var status = "Touch ID opens your encrypted enrollment. Then the camera compares your face."
    @Published private(set) var isBusy = false
    @Published private(set) var previewSession: AVCaptureSession?
    @Published private(set) var previewImage: CGImage?
    @Published private(set) var sampleCount = 0
    @Published private(set) var latestSimilarity: Double?
    @Published private(set) var result: FaceComparisonResult?
    @Published private(set) var analysisMilliseconds: Double?
    @Published private(set) var secondsRemaining = 15
    @Published private(set) var cameraSettingsNeeded = false
    private let vault: any FaceTestTemplateReading
    private let session: MacEnrollmentSession
    private let services: EnrollmentCaptureServices
    private var camera: (any EnrollmentCapturing)?
    private var operation: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var captureStarted: Double?
    private var cancellationMessage: String?
    private var observers: [FaceTestNotificationToken] = []

    init(vault: any FaceTestTemplateReading = EnrollmentVault(modelIdentifier: ArcFaceContract.identifier),
         session: MacEnrollmentSession = MacEnrollmentSession(), services: EnrollmentCaptureServices = .live) {
        self.vault = vault; self.session = session; self.services = services
        for event in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observe(NSWorkspace.shared.notificationCenter, event)
        }
        observe(DistributedNotificationCenter.default(), NSNotification.Name("com.apple.screenIsLocked"))
        observe(NotificationCenter.default, NSApplication.didResignActiveNotification, foregroundOnly: true)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, foregroundOnly: Bool = false) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isBusy, !foregroundOnly || self.phase == .capturing else { return }
                self.stop("Test stopped because the app lost focus or the Mac session changed. Return here and test again.")
            }
        }
        observers.append(FaceTestNotificationToken(center: center, token: token))
    }

    func start() {
        guard !isBusy else { return }
        vault.lock()
        result = nil; sampleCount = 0; latestSimilarity = nil; analysisMilliseconds = nil
        cameraSettingsNeeded = false; cancellationMessage = nil; captureStarted = nil
        isBusy = true; phase = .authorizing
        status = "Use Touch ID or your Mac password to open the saved face. The camera test follows."
        operation = Task {
            do {
                try await session.waitForForeground()
                try await vault.authorizeReading()
                try Task.checkCancellation()
                try await session.waitForForeground()
                try checkLease()
                let template = try vault.templateForVerification()
                phase = .preparing
                status = "Preparing the camera and validating the face model."
                startWatchdog()
                let analyze = try await services.prepare()
                try Task.checkCancellation()
                try await session.waitForForeground()
                guard await services.requestPermission() else {
                    cameraSettingsNeeded = services.permissionDenied()
                    throw FaceTestError.camera
                }
                try Task.checkCancellation()
                try await session.waitForForeground()
                try checkLease()
                let completed = try await capture(template: template, analyze: analyze)
                try Task.checkCancellation()
                try session.check()
                try checkLease()
                result = completed.result
                latestSimilarity = completed.result.medianSimilarity
                sampleCount = completed.result.frameCount
                analysisMilliseconds = completed.medianMilliseconds
                phase = .finished
                switch completed.result.outcome {
                case .similar: status = "The camera face looks similar to your saved enrollment."
                case .different: status = "The camera face looks different from your saved enrollment."
                case .inconclusive: status = "The scores are borderline or inconsistent. Try again in even light."
                }
            } catch {
                result = nil; sampleCount = 0; latestSimilarity = nil
                phase = cancellationMessage == nil ? .failed : .idle
                status = cancellationMessage ?? message(for: error)
            }
            watchdog?.cancel(); watchdog = nil
            camera = nil; clearPreview(); captureStarted = nil
            vault.lock()
            isBusy = false
        }
    }

    private struct Completed {
        let result: FaceComparisonResult
        let medianMilliseconds: Double
    }

    private func capture(template: EnrollmentTemplate, analyze: EnrollmentImageAnalyzer) async throws -> Completed {
        var window = try FaceComparisonWindow(template: template)
        var timings: [Double] = []
        let capture = services.makeCamera()
        camera = capture
        phase = .capturing; secondsRemaining = 15
        status = "Look naturally toward the camera and hold still for a moment."
        captureStarted = services.now()
        capture.start()
        do {
            for try await image in capture.frames {
                try Task.checkCancellation()
                try checkCapture()
                previewImage = image
                previewSession = capture.previewSessionForUI
                let time = services.now()
                do {
                    let analysis = try await analyze(image)
                    try Task.checkCancellation()
                    try checkCapture()
                    // Slow/stale inference never contributes a score to a fresh temporal window.
                    guard services.now() - time <= 0.75, services.now() >= time else {
                        window.interrupt(); timings.removeAll(); update(window)
                        status = "The camera analysis is catching up. Hold still and try brighter light."
                        continue
                    }
                    guard let metrics = analysis.enrollmentMetrics else { throw RecognitionError.poseUnavailable }
                    if let hint = FaceComparisonWindow.adjustment(for: metrics) {
                        window.interrupt(); timings.removeAll(); update(window); status = hint
                        continue
                    }
                    let before = window.count
                    let completed = try window.observe(analysis.embedding, metrics: metrics, at: time)
                    if window.count < before { timings.removeAll() }
                    if window.count > before || window.count == 1 {
                        timings.append((services.now() - time) * 1000)
                    }
                    update(window)
                    status = "Comparing your face… \(sampleCount) of \(FaceComparisonPolicy.requiredFrames) usable frames."
                    if let completed {
                        let ordered = timings.sorted()
                        let milliseconds = ordered.isEmpty ? 0 : ordered[ordered.count / 2]
                        await capture.stopAndWait()
                        camera = nil; clearPreview()
                        return Completed(result: completed, medianMilliseconds: milliseconds)
                    }
                } catch let error as RecognitionError {
                    window.interrupt(); timings.removeAll(); update(window)
                    switch error {
                    case .noFace: status = "Bring your face into view. Look toward the camera."
                    case .multipleFaces: status = "Keep only one face in the camera view."
                    case .landmarks, .poseUnavailable, .captureQualityUnavailable: status = error.localizedDescription
                    default: throw error
                    }
                }
            }
            throw FaceTestError.camera
        } catch {
            await capture.stopAndWait()
            camera = nil; clearPreview()
            throw error
        }
    }

    private func update(_ window: FaceComparisonWindow) {
        sampleCount = window.count; latestSimilarity = window.latestSimilarity
    }

    private func checkLease() throws {
        guard vault.sessionIsValid else { throw EnrollmentError.expired }
    }

    private func checkCapture() throws {
        try session.check()
        try checkLease()
        guard let captureStarted else { throw FaceTestError.timeout }
        let elapsed = services.now() - captureStarted
        guard elapsed.isFinite, elapsed >= 0, elapsed < 15 else { throw FaceTestError.timeout }
        secondsRemaining = max(0, Int(ceil(15 - elapsed)))
    }

    // Also runs without incoming frames, so a disconnected/stalled camera cannot keep a test alive.
    func watchdogTick() {
        guard isBusy else { return }
        do {
            try session.check(requireForeground: phase == .capturing)
            try checkLease()
            if phase == .capturing { try checkCapture() }
        } catch { stop(message(for: error)) }
    }

    private func message(for error: any Error) -> String {
        if error is CancellationError { return "Test canceled." }
        if let sessionError = error as? EnrollmentSessionError {
            if sessionError == .foregroundRequired { return "Test stopped when the app lost focus. Keep Face Unlock in front and test again." }
            return "Test stopped because your Mac locked, slept, or changed account. Return to your desktop and test again."
        }
        return error.localizedDescription
    }

    private func startWatchdog() {
        watchdog = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                watchdogTick()
            }
        }
    }

    private func clearPreview() { previewSession = nil; previewImage = nil }

    func cancel() { if isBusy { stop("Test canceled. Your saved face is unchanged.") } }

    private func stop(_ message: String) {
        cancellationMessage = message
        operation?.cancel(); camera?.stop()
        watchdog?.cancel(); watchdog = nil
        clearPreview(); result = nil; latestSimilarity = nil; sampleCount = 0
        vault.lock()
        phase = .idle; status = message
    }

    func openCameraSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }

}

/// Immutable registration; NotificationCenter supports removal from any thread.
private final class FaceTestNotificationToken: @unchecked Sendable {
    let center: NotificationCenter
    let token: NSObjectProtocol
    init(center: NotificationCenter, token: NSObjectProtocol) { self.center = center; self.token = token }
    deinit { center.removeObserver(token) }
}

private enum FaceTestError: Error, LocalizedError {
    case timeout, camera
    var errorDescription: String? {
        switch self {
        case .timeout: "No comparison completed within 15 seconds. Try again with one well-lit face near the camera."
        case .camera: "The camera could not provide a complete test. Check Camera permission and try again."
        }
    }
}
