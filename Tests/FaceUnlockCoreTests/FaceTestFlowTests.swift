import CoreGraphics
import Foundation
import XCTest
@testable import FaceUnlockApp
@testable import FaceUnlockCore
@testable import FaceUnlockMac
@testable import FaceUnlockRecognition

@MainActor
private final class TestTemplateReader: FaceTestTemplateReading {
    var sessionIsValid = false
    var authorizations = 0
    var reads = 0
    var error: (any Error)?
    let template: EnrollmentTemplate
    init() throws {
        var values = Array(repeating: Float(0), count: 512); values[0] = 1
        let embedding = try FaceEmbedding(raw: values, modelIdentifier: ArcFaceContract.identifier)
        template = try EnrollmentTemplate(embeddings: Array(repeating: embedding, count: 18), modelIdentifier: ArcFaceContract.identifier)
    }
    func authorizeReading() async throws {
        authorizations += 1
        if let error { throw error }
        sessionIsValid = true
    }
    func templateForVerification() throws -> EnrollmentTemplate {
        guard sessionIsValid else { throw EnrollmentError.expired }
        reads += 1
        return template
    }
    func lock() { sessionIsValid = false }
}

@MainActor
private final class TestComparisonCamera: EnrollmentCapturing {
    let frames: AsyncThrowingStream<CGImage, any Error>
    let continuation: AsyncThrowingStream<CGImage, any Error>.Continuation
    var started = false
    var stopped = false
    var beforeStopCompletes: (() -> Void)?
    init() {
        let pair = AsyncThrowingStream<CGImage, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        frames = pair.stream; continuation = pair.continuation
    }
    func start() { started = true }
    func stop() { stopped = true; continuation.finish() }
    func stopAndWait() async { stop(); beforeStopCompletes?() }
}

@MainActor
private final class ComparisonFixture {
    let vault: TestTemplateReader
    let camera = TestComparisonCamera()
    let notifications = NotificationCenter()
    var time = 100.0
    var foreground = true
    var consoleUID: UInt32? = 501
    var permission = true
    var preparationError: (any Error)?
    var customAnalysis: EnrollmentImageAnalyzer?
    var score = 0.8
    var analysisCount = 0
    var model: FaceTestModel!

    init() throws {
        vault = try TestTemplateReader()
        let session = MacEnrollmentSession(snapshot: { [unowned self] in
            SessionSnapshot(processUserID: 501, consoleUserID: consoleUID, sessionUserID: 501,
                            isOnConsole: true, loginComplete: true, screenLock: .unknown, sampledAtUptime: 100)
        }, isForeground: { [unowned self] in foreground }, uptime: { 100 })
        let services = EnrollmentCaptureServices(prepare: { [unowned self] in
            if let preparationError { throw preparationError }
            return { [unowned self] image in
                analysisCount += 1
                if let customAnalysis { return try await customAnalysis(image) }
                return try analysis()
            }
        }, requestPermission: { [unowned self] in permission }, permissionDenied: { true },
           makeCamera: { [unowned self] in camera }, now: { [unowned self] in time })
        model = FaceTestModel(vault: vault, session: session, services: services, notifications: notifications)
    }

    func analysis() throws -> FaceAnalysis {
        var values = Array(repeating: Float(0), count: 512)
        values[0] = Float(score); values[1] = Float(sqrt(1 - score * score))
        let metrics = EnrollmentMetrics(quality: 0.8, yaw: 0, pitch: -0.4, roll: 0,
                                        faceWidthPixels: 180, faceHeightPixels: 200, centered: true, luminance: 120,
                                        faceBounds: FaceBounds(x: 0.3, y: 0.2, width: 0.3, height: 0.5))
        return FaceAnalysis(embedding: try FaceEmbedding(raw: values, modelIdentifier: ArcFaceContract.identifier),
                            quality: 0.8, inferenceMilliseconds: 1, enrollmentMetrics: metrics)
    }

    func send(_ count: Int = 1) async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        for _ in 0..<count {
            time += 0.2
            camera.continuation.yield(image)
            for _ in 0..<40 { await Task.yield() }
        }
    }
}

final class FaceTestFlowTests: XCTestCase {
    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Face test did not reach the expected state", file: file, line: line)
    }

    @MainActor
    func testCameraFailureBeforeFirstFrameStillCountsAsIncompleteEvaluation() async throws {
        let fixture = try ComparisonFixture()
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        fixture.camera.stop()
        await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.model.evaluationTrials.count, 1)
        XCTAssertNil(fixture.model.evaluationTrials.first?.outcome)
        XCTAssertNil(fixture.model.evaluationTrials.first?.cameraMilliseconds)
    }

    @MainActor
    func testShortWindowIsDesktopOnlyAndRecordsPresentationWithoutMixingModes() async throws {
        let fixture = try ComparisonFixture()
        fixture.model.setEvaluationMode(.shortEvaluation)
        fixture.model.evaluationPresentation = .screen
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        fixture.model.setEvaluationMode(.standard)
        XCTAssertEqual(fixture.model.evaluationMode, .shortEvaluation, "Cannot change evidence policy during capture")
        try await fixture.send(6)
        await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.model.result?.frameCount, 6)
        let trial = try XCTUnwrap(fixture.model.evaluationTrials.last)
        XCTAssertEqual(trial.mode, .shortEvaluation)
        XCTAssertEqual(trial.presentation, .screen)
        XCTAssertEqual(trial.outcome, .similar, "Matching screen-photo embeddings are not liveness evidence")
        XCTAssertNotNil(trial.cameraMilliseconds)
        fixture.model.setEvaluationMode(.standard)
        XCTAssertNil(fixture.model.result)
        XCTAssertEqual(fixture.model.requiredFrames, 12)
        XCTAssertTrue(fixture.model.completedCameraTimes.isEmpty)
        XCTAssertEqual(fixture.model.evaluationTrials.count, 1)
    }

    @MainActor
    func testReadAuthorizationThenLiveComparisonStopsCameraBeforeShowingResult() async throws {
        for score in [0.8, 0.1, 0.45] {
            let fixture = try ComparisonFixture()
            fixture.score = score
            fixture.model.start()
            await waitUntil { fixture.model.phase == .capturing }
            XCTAssertEqual(fixture.vault.authorizations, 1)
            XCTAssertEqual(fixture.vault.reads, 1)
            try await fixture.send(12)
            await waitUntil { !fixture.model.isBusy }
            XCTAssertEqual(fixture.model.phase, .finished)
            XCTAssertEqual(fixture.model.result?.outcome, score == 0.8 ? .similar : score == 0.1 ? .different : .inconclusive)
            XCTAssertTrue(fixture.camera.stopped)
            XCTAssertNil(fixture.model.previewImage)
            XCTAssertFalse(fixture.vault.sessionIsValid)
        }
    }

    @MainActor
    func testCancelAndLateInferenceCannotPublishResult() async throws {
        let fixture = try ComparisonFixture()
        var pending: CheckedContinuation<FaceAnalysis, any Error>?
        fixture.customAnalysis = { _ in try await withCheckedThrowingContinuation { pending = $0 } }
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        try await fixture.send()
        await waitUntil { pending != nil }
        fixture.model.cancel()
        pending?.resume(returning: try fixture.analysis())
        await waitUntil { !fixture.model.isBusy }
        XCTAssertNil(fixture.model.result)
        XCTAssertNil(fixture.model.previewImage)
        XCTAssertEqual(fixture.model.sampleCount, 0)
        XCTAssertTrue(fixture.camera.stopped)
        XCTAssertFalse(fixture.vault.sessionIsValid)
    }

    @MainActor
    func testBackgroundAccountChangeOrExpiredLeaseDiscardsLateInference() async throws {
        for scenario in 0..<3 {
            let fixture = try ComparisonFixture()
            var pending: CheckedContinuation<FaceAnalysis, any Error>?
            fixture.customAnalysis = { _ in try await withCheckedThrowingContinuation { pending = $0 } }
            fixture.model.start()
            await waitUntil { fixture.model.phase == .capturing }
            try await fixture.send()
            await waitUntil { pending != nil }
            if scenario == 0 { fixture.foreground = false }
            if scenario == 1 { fixture.consoleUID = 502 }
            if scenario == 2 { fixture.vault.sessionIsValid = false }
            pending?.resume(returning: try fixture.analysis())
            await waitUntil { !fixture.model.isBusy }
            XCTAssertNil(fixture.model.result)
            XCTAssertNil(fixture.model.previewImage)
            XCTAssertEqual(fixture.model.sampleCount, 0)
            XCTAssertTrue(fixture.camera.stopped)
        }
    }

    @MainActor
    func testSlowAnalysisAndDetectionLossResetProgress() async throws {
        let fixture = try ComparisonFixture()
        defer { fixture.model.cancel() }
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        try await fixture.send(4)
        XCTAssertEqual(fixture.model.sampleCount, 4)
        fixture.customAnalysis = { _ in throw RecognitionError.multipleFaces }
        try await fixture.send()
        XCTAssertEqual(fixture.model.sampleCount, 0)
        XCTAssertTrue(fixture.model.status.contains("only one face"))
        XCTAssertNil(fixture.model.latestSimilarity)
        fixture.customAnalysis = { _ in fixture.time += 0.8; return try fixture.analysis() }
        try await fixture.send()
        XCTAssertEqual(fixture.model.sampleCount, 0)
        XCTAssertNil(fixture.model.result)
        XCTAssertTrue(fixture.model.status.contains("catching up"))
    }

    @MainActor
    func testMissingMetadataAndNoFaceDoNotProduceScores() async throws {
        let fixture = try ComparisonFixture()
        defer { fixture.model.cancel() }
        fixture.customAnalysis = { _ in throw RecognitionError.noFace }
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        try await fixture.send()
        XCTAssertTrue(fixture.model.status.contains("Bring your face"))
        let analysis = try fixture.analysis()
        fixture.customAnalysis = { _ in
            FaceAnalysis(embedding: analysis.embedding, quality: 0.8, inferenceMilliseconds: 1, enrollmentMetrics: nil)
        }
        try await fixture.send()
        XCTAssertEqual(fixture.model.sampleCount, 0)
        XCTAssertNil(fixture.model.latestSimilarity)
        XCTAssertTrue(fixture.model.status.contains("measure its angle"))
    }

    @MainActor
    func testWatchdogStopsStalledCameraWithoutWaitingForAnotherFrame() async throws {
        let fixture = try ComparisonFixture()
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        fixture.time += FaceTestModel.captureTimeout
        fixture.model.watchdogTick()
        await waitUntil { !fixture.model.isBusy }
        XCTAssertTrue(fixture.camera.stopped)
        XCTAssertNil(fixture.model.result)
        XCTAssertTrue(fixture.model.status.contains("15 seconds"))
    }

    @MainActor
    func testCanceledAuthenticationDeniedPermissionAndInvalidModelNeverOpenCamera() async throws {
        for scenario in 0..<3 {
            let fixture = try ComparisonFixture()
            if scenario == 0 { fixture.vault.error = CancellationError() }
            if scenario == 1 { fixture.permission = false }
            if scenario == 2 { fixture.preparationError = RecognitionError.reference }
            fixture.model.start()
            await waitUntil { !fixture.model.isBusy }
            XCTAssertEqual(fixture.model.phase, .failed)
            XCTAssertFalse(fixture.camera.started)
            XCTAssertNil(fixture.model.result)
            XCTAssertFalse(fixture.vault.sessionIsValid)
            XCTAssertEqual(fixture.model.cameraSettingsNeeded, scenario == 1)
        }
    }

    @MainActor
    func testRepeatedStartCannotCreateOverlappingReadsOrCameraSessions() async throws {
        let fixture = try ComparisonFixture()
        defer { fixture.model.cancel() }
        fixture.model.start(); fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        fixture.model.start()
        XCTAssertEqual(fixture.vault.authorizations, 1)
        XCTAssertEqual(fixture.vault.reads, 1)
    }

    @MainActor
    func testRestoredComparisonCollectsTwelveFramesWithoutEyeMeasurementsOrGesture() async throws {
        let fixture = try ComparisonFixture()
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        try await fixture.send(12)
        await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.model.result?.outcome, .similar)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(fixture.model.scanMilliseconds), 1650)
        XCTAssertTrue(fixture.model.status.contains("Liveness is unverified"))
        XCTAssertTrue(fixture.camera.stopped)
        XCTAssertEqual(fixture.model.completedCameraTimes.count, 1)
        XCTAssertEqual(try XCTUnwrap(fixture.model.averageCameraMilliseconds), try XCTUnwrap(fixture.model.scanMilliseconds), accuracy: 0.001)
        XCTAssertEqual(fixture.model.failedCameraTests, 0)
    }

    @MainActor
    func testMissingFaceEventuallyTimesOutWithoutRestartingTheTimeout() async throws {
        let fixture = try ComparisonFixture()
        fixture.customAnalysis = { _ in throw RecognitionError.noFace }
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        try await fixture.send()
        fixture.time += FaceTestModel.captureTimeout
        fixture.model.watchdogTick()
        await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.model.phase, .failed)
        XCTAssertTrue(fixture.model.status.contains("15 seconds"), fixture.model.status)
        XCTAssertNil(fixture.model.result)
        XCTAssertNil(fixture.model.previewImage)
        XCTAssertFalse(fixture.vault.sessionIsValid)
        XCTAssertEqual(fixture.model.failedCameraTests, 1)
        XCTAssertNil(fixture.model.averageCameraMilliseconds)
        XCTAssertTrue(fixture.model.acquisitionSummary?.contains("Bring your face") == true)
    }

    @MainActor
    func testAnalysisReturningAfterDeadlineCannotPublishSimilarity() async throws {
        let fixture = try ComparisonFixture()
        var pending: CheckedContinuation<FaceAnalysis, any Error>?
        fixture.customAnalysis = { _ in try await withCheckedThrowingContinuation { pending = $0 } }
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        try await fixture.send()
        await waitUntil { pending != nil }
        fixture.time += FaceTestModel.captureTimeout
        fixture.model.watchdogTick()
        pending?.resume(returning: try fixture.analysis())
        await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.model.phase, .failed)
        XCTAssertNil(fixture.model.result)
        XCTAssertEqual(fixture.model.sampleCount, 0)
        XCTAssertTrue(fixture.camera.stopped)
    }

    @MainActor
    func testRealTimeoutStopsAStalledStreamWithoutNewFramesOrClockPolling() async throws {
        let fixture = try ComparisonFixture()
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        try await fixture.send()
        try await Task.sleep(for: .milliseconds(15150))
        await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.model.phase, .failed)
        XCTAssertTrue(fixture.model.status.contains("15 seconds"))
        XCTAssertTrue(fixture.camera.stopped)
        XCTAssertNil(fixture.model.result)
    }

    @MainActor
    func testCameraStartupIsMeasuredSeparatelyWithinOriginalScanTimeout() async throws {
        let fixture = try ComparisonFixture()
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        fixture.time += 5
        fixture.model.watchdogTick()
        try await fixture.send(12)
        await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.model.result?.outcome, .similar)
        XCTAssertEqual(try XCTUnwrap(fixture.model.cameraStartupMilliseconds), 5200, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(fixture.model.scanMilliseconds), 1650)
    }

    @MainActor
    func testCameraShutdownCannotPublishAResultAfterTimeout() async throws {
        let fixture = try ComparisonFixture()
        fixture.camera.beforeStopCompletes = { [weak fixture] in fixture?.time += FaceTestModel.captureTimeout }
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        try await fixture.send(12)
        await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.model.phase, .failed)
        XCTAssertNil(fixture.model.result)
        XCTAssertTrue(fixture.model.status.contains("15 seconds"))
    }

    @MainActor
    func testRestoredScanAllowsAcquisitionBeyondFormerEightSecondTimeout() async throws {
        let fixture = try ComparisonFixture()
        fixture.customAnalysis = { _ in throw RecognitionError.noFace }
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        try await fixture.send(45)
        XCTAssertTrue(fixture.model.isBusy)
        XCTAssertNil(fixture.model.result)
        fixture.customAnalysis = nil
        try await fixture.send(12)
        await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.model.result?.outcome, .similar)
        XCTAssertGreaterThan(try XCTUnwrap(fixture.model.scanMilliseconds), 8000)
        XCTAssertLessThan(try XCTUnwrap(fixture.model.scanMilliseconds), 15000)
        XCTAssertEqual(fixture.model.completedCameraTimes.count, 1)
    }

    @MainActor
    func testLockNotificationStillCancelsAndRevokesTemplateAccess() async throws {
        let fixture = try ComparisonFixture()
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        try await fixture.send()
        fixture.notifications.post(name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        await waitUntil { !fixture.model.isBusy }
        XCTAssertNil(fixture.model.result)
        XCTAssertTrue(fixture.camera.stopped)
        XCTAssertFalse(fixture.vault.sessionIsValid)
        XCTAssertTrue(fixture.model.status.contains("Mac session changed"))
    }

}
