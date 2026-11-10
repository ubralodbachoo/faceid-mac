import AppKit
import AVFoundation
import Combine
import Foundation
import FaceUnlockCore
import FaceUnlockMac
import FaceUnlockRecognition

enum EnrollmentPhase: Equatable {
    case idle, authorizing, preparing, cameraPermission, capturing, paused, review, saved, validating, deleting, failed

    var isPreparing: Bool {
        [.authorizing, .preparing, .cameraPermission, .validating, .deleting].contains(self)
    }
}

@MainActor
final class EnrollmentModel: ObservableObject {
    @Published private(set) var phase: EnrollmentPhase = .idle
    @Published private(set) var status = "Your camera stays off until you start setup."
    @Published private(set) var currentPose = EnrollmentPose.center
    @Published private(set) var completedPoses = 0
    @Published private(set) var holdProgress = 0.0
    @Published private(set) var previewSession: AVCaptureSession?
    @Published private(set) var sampleCount = 0
    @Published private(set) var isBusy = false
    @Published private(set) var hasEnrollment = false
    @Published private(set) var canSave = false
    @Published private(set) var previewImage: CGImage?
    @Published private(set) var faceIsReady = false
    @Published private(set) var detectedFaceBounds: FaceBounds?
    @Published private(set) var secondsRemaining = 0
    @Published private(set) var cameraSettingsNeeded = false
    private let vault: EnrollmentVault
    private let session: MacEnrollmentSession
    private let captureServices: EnrollmentCaptureServices
    private var camera: (any EnrollmentCapturing)?
    private var pendingTemplate: EnrollmentTemplate?
    private var operation: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var cancellationMessage: String?
    private var pauseRequested = false
    private var resumeRequested = false
    private var resumeContinuation: CheckedContinuation<Void, any Error>?
    private var observers: [EnrollmentNotificationToken] = []

    init(vault: EnrollmentVault = EnrollmentVault(modelIdentifier: ArcFaceContract.identifier),
         session: MacEnrollmentSession = MacEnrollmentSession(), captureServices: EnrollmentCaptureServices = .live) {
        self.vault = vault
        self.session = session
        self.captureServices = captureServices
        refresh()
        for event in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            let center = NSWorkspace.shared.notificationCenter
            let token = center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.sessionChanged() }
            }
            observers.append(EnrollmentNotificationToken(center: center, token: token))
        }
        let center = DistributedNotificationCenter.default()
        let token = center.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sessionChanged() }
        }
        observers.append(EnrollmentNotificationToken(center: center, token: token))
    }

    func refresh() {
        vault.refreshPresence()
        hasEnrollment = vault.hasEnrollment
        if phase == .saved && !hasEnrollment { phase = .idle }
    }

    private func checkSession() throws { try session.check() }

    private func waitForForeground() async throws {
        do { try session.check() }
        catch EnrollmentSessionError.foregroundRequired { status = "Click this window to continue setup." }
        try await session.waitForForeground()
    }

    func start() {
        guard !isBusy else { return }
        resetPending()
        vault.lock()
        cancellationMessage = nil
        cameraSettingsNeeded = false
        isBusy = true
        phase = .authorizing
        status = "Use Touch ID or your Mac password in the macOS dialog."
        operation = Task {
            do {
                try await waitForForeground()
                try await vault.beginEnrollment()
                try Task.checkCancellation()
                try await waitForForeground()
                secondsRemaining = vault.secondsRemaining
                phase = .preparing
                status = "Getting face setup ready. This can take a moment."
                let analyze = try await captureServices.prepare()
                try Task.checkCancellation()
                try await waitForForeground()
                phase = .cameraPermission
                status = "Choose Allow in the camera permission dialog."
                guard await captureServices.requestPermission() else {
                    cameraSettingsNeeded = captureServices.permissionDenied()
                    throw EnrollmentCameraError.unavailable
                }
                try Task.checkCancellation()
                try await waitForForeground()
                guard vault.sessionIsValid else { throw EnrollmentError.expired }
                startWatchdog()
                pendingTemplate = try await collectViews(analyze: analyze)
                try Task.checkCancellation()
                try session.check(requireForeground: false)
                guard vault.sessionIsValid else { throw EnrollmentError.expired }
                canSave = true
                phase = .review
                status = "Your scan is complete. Save your face to finish."
            } catch {
                resetPending()
                vault.lock()
                watchdog?.cancel(); watchdog = nil
                if let cancellationMessage {
                    status = cancellationMessage
                } else {
                    phase = .failed
                    status = error is CancellationError ? "Setup canceled. No enrollment was saved." : error.localizedDescription
                }
            }
            camera = nil
            previewImage = nil
            isBusy = false
            refresh()
        }
    }

    private func collectViews(analyze: EnrollmentImageAnalyzer) async throws -> EnrollmentTemplate {
        var collector = VideoEnrollmentCollector(modelIdentifier: ArcFaceContract.identifier)
        while collector.currentPose != nil {
            try Task.checkCancellation()
            try checkSession()
            guard vault.sessionIsValid else { throw EnrollmentError.expired }
            pauseRequested = false
            phase = .capturing
            status = collector.sampleCount == 0 ? "Look naturally at the camera. The scan starts automatically." : currentPose.title
            try await collectSegment(analyze: analyze, collector: &collector)
            try Task.checkCancellation()
            if collector.currentPose == nil { break }
            guard pauseRequested else { throw EnrollmentError.incomplete }
            collector.interrupt(restartWarmup: true)
            holdProgress = 0
            phase = .paused
            status = "Camera paused. Your captured views are kept until the timer expires."
            try await waitForResume()
        }
        return try collector.finish()
    }

    // Keep each camera/stream in this scope so a paused workflow retains descriptors only,
    // never a queued image from the stopped capture stream.
    private func collectSegment(analyze: EnrollmentImageAnalyzer, collector: inout VideoEnrollmentCollector) async throws {
        let capture = captureServices.makeCamera()
        camera = capture
        capture.start()
        do {
            try await consumeFrames(from: capture, analyze: analyze, collector: &collector)
        } catch EnrollmentSessionError.foregroundRequired {
            pauseRequested = true
        } catch {
            await capture.stopAndWait()
            camera = nil
            clearPreview()
            throw error
        }
        await capture.stopAndWait()
        camera = nil
        clearPreview()
    }

    private func consumeFrames(from camera: any EnrollmentCapturing, analyze: EnrollmentImageAnalyzer,
                               collector: inout VideoEnrollmentCollector) async throws {
        for try await image in camera.frames {
            try Task.checkCancellation()
            try checkSession()
            guard vault.sessionIsValid else { throw EnrollmentError.expired }
            // The native preview continues at camera rate while this bounded stream is analyzed.
            if previewSession == nil { previewSession = camera.previewSessionForUI }
            previewImage = image
            let frameTime = captureServices.now()
            do {
                let analysis = try await analyze(image)
                try Task.checkCancellation()
                try checkSession()
                guard vault.sessionIsValid else { throw EnrollmentError.expired }
                guard let metrics = analysis.enrollmentMetrics else { throw RecognitionError.poseUnavailable }
                let update = try collector.observe(analysis.embedding, metrics: metrics, at: frameTime)
                detectedFaceBounds = update.trackedBounds ?? metrics.faceBounds
                sampleCount = update.sampleCount
                completedPoses = update.completedPoses
                holdProgress = update.holdProgress
                faceIsReady = update.holdProgress > 0 || update.capturedPose
                status = update.feedback
                if let pose = update.pose { currentPose = pose }
                else { break }
            } catch let error as RecognitionError {
                collector.interrupt()
                holdProgress = 0
                faceIsReady = false
                detectedFaceBounds = nil
                switch error {
                case .noFace: status = "Bring your face into the circle to start scanning."
                case .multipleFaces: status = "Keep only your face in the camera view."
                case .landmarks: status = "Face the camera and keep your eyes and mouth visible."
                case .poseUnavailable, .captureQualityUnavailable: status = error.localizedDescription
                default: throw error
                }
            }
        }
    }

    private func waitForResume() async throws {
        try Task.checkCancellation()
        try session.check(requireForeground: false)
        guard vault.sessionIsValid else { throw EnrollmentError.expired }
        if !resumeRequested {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                resumeContinuation = continuation
            }
        }
        resumeRequested = false
        try Task.checkCancellation()
        try checkSession()
        guard vault.sessionIsValid else { throw EnrollmentError.expired }
    }

    func resume() {
        guard phase == .paused else { return }
        do {
            try checkSession()
            guard vault.sessionIsValid else { throw EnrollmentError.expired }
            resumeRequested = true
            let continuation = resumeContinuation
            resumeContinuation = nil
            continuation?.resume()
        } catch EnrollmentSessionError.foregroundRequired {
            status = "Click this window, then choose Continue scan."
        } catch { stop(reason: error.localizedDescription, phase: .failed) }
    }

    private func clearPreview() {
        previewImage = nil
        previewSession = nil
        detectedFaceBounds = nil
        faceIsReady = false
    }

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                do {
                    try session.check(requireForeground: false)
                    guard vault.sessionIsValid else { throw EnrollmentError.expired }
                    secondsRemaining = vault.secondsRemaining
                    if phase == .capturing {
                        do { try checkSession() }
                        catch EnrollmentSessionError.foregroundRequired {
                            pauseRequested = true
                            clearPreview()
                            camera?.stop()
                        }
                    }
                } catch { stop(reason: error.localizedDescription, phase: .failed); return }
            }
        }
    }

    func save() {
        guard !isBusy, let pendingTemplate else { return }
        do {
            try checkSession()
            try vault.save(pendingTemplate)
            phase = .saved
            status = "Your face template is saved on this Mac."
        } catch EnrollmentSessionError.foregroundRequired {
            status = "Bring this window to the front, then choose Save face."
            return
        } catch {
            phase = .failed
            status = error.localizedDescription
            vault.lock()
        }
        resetPending()
        watchdog?.cancel(); watchdog = nil
        refresh()
    }

    func inspectSaved() {
        runAuthenticated(phase: .validating) {
            try await self.vault.authorizeReading()
            try await self.waitForForeground()
            _ = try self.vault.templateForVerification()
            self.phase = .saved
            self.status = "Your saved face data is valid for this account and model."
        }
    }

    func delete() {
        runAuthenticated(phase: .deleting) {
            try await self.vault.delete()
            self.phase = .idle
            self.status = "Your saved face was removed from this Mac."
        }
    }

    private func runAuthenticated(phase: EnrollmentPhase, _ action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        resetPending()
        watchdog?.cancel(); watchdog = nil
        vault.lock()
        cancellationMessage = nil
        isBusy = true
        self.phase = phase
        status = "Confirm with Touch ID or your Mac password."
        operation = Task {
            defer { vault.lock(); isBusy = false; refresh() }
            do { try await waitForForeground(); try await action(); try Task.checkCancellation() }
            catch {
                if let cancellationMessage { status = cancellationMessage }
                else {
                    self.phase = .failed
                    status = error is CancellationError ? "Operation canceled." : error.localizedDescription
                }
            }
        }
    }

    private func resetPending() {
        pendingTemplate = nil
        canSave = false
        sampleCount = 0
        currentPose = .center
        completedPoses = 0
        holdProgress = 0
        clearPreview()
        secondsRemaining = 0
        pauseRequested = false
        resumeRequested = false
    }

    func cancel() { stop(reason: "Setup canceled. Any saved face is unchanged.", phase: .idle) }

    private func sessionChanged() {
        guard isBusy || canSave else { vault.lock(); return }
        stop(reason: "Setup stopped because your Mac locked, slept, or changed account. Start again when you return.", phase: .failed)
    }

    private func stop(reason: String, phase: EnrollmentPhase) {
        cancellationMessage = reason
        operation?.cancel()
        let continuation = resumeContinuation
        resumeContinuation = nil
        continuation?.resume(throwing: CancellationError())
        camera?.stop()
        watchdog?.cancel(); watchdog = nil
        resetPending()
        vault.lock()
        self.phase = phase
        status = reason
    }

    func openCameraSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Immutable registration; NotificationCenter removal is thread safe even during destruction.
private final class EnrollmentNotificationToken: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol
    init(center: NotificationCenter, token: NSObjectProtocol) { self.center = center; self.token = token }
    deinit { center.removeObserver(token) }
}
