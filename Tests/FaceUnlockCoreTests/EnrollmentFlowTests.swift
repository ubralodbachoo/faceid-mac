import CoreGraphics
import Foundation
import XCTest
@testable import FaceUnlockApp
@testable import FaceUnlockCore
@testable import FaceUnlockMac
@testable import FaceUnlockRecognition

@MainActor
private final class FlowKeys: CredentialKeyStoring {
    var data: Data?
    func read() throws -> Data? { data }
    func create(_ data: Data) throws { self.data = data }
    func delete() throws { data = nil }
}

@MainActor
private final class FlowBlobs: CredentialBlobStoring {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
    func delete() throws { data = nil }
}

@MainActor
private final class FlowAuth: SystemAuthenticating {
    var calls = 0
    func authenticate(reason: String) async throws { calls += 1 }
    func cancel() {}
}

@MainActor
private final class FlowCamera: EnrollmentCapturing {
    let frames: AsyncThrowingStream<CGImage, any Error>
    let continuation: AsyncThrowingStream<CGImage, any Error>.Continuation
    var started = false
    var stopped = false
    init() {
        let pair = AsyncThrowingStream<CGImage, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        frames = pair.stream; continuation = pair.continuation
    }
    func start() { started = true }
    func stop() { stopped = true; continuation.finish() }
    func stopAndWait() async { stop() }
}

@MainActor
private final class FlowFixture {
    let keys = FlowKeys(), blobs = FlowBlobs(), auth = FlowAuth(), camera = FlowCamera()
    var time = 100.0
    var leaseTime = 100.0
    var foreground = true
    var consoleUID: UInt32? = 501
    var cameraSources: [FlowCamera] = []
    var index = 0
    var permission = true
    var denied = false
    var preparationError: (any Error)?
    var customAnalysis: EnrollmentImageAnalyzer?
    var analysisCount = 0
    var previewObserved = false
    var model: EnrollmentModel!

    init() {
        cameraSources = [camera]
        let session = MacEnrollmentSession(snapshot: { [unowned self] in
            SessionSnapshot(processUserID: 501, consoleUserID: consoleUID, sessionUserID: 501,
                            isOnConsole: true, loginComplete: true, screenLock: .unknown, sampledAtUptime: 100)
        }, isForeground: { [unowned self] in foreground }, uptime: { 100 })
        let vault = EnrollmentVault(keys: keys, blobs: blobs, authenticator: auth,
                                    modelIdentifier: ArcFaceContract.identifier, userID: 501, now: { [unowned self] in leaseTime })
        let services = EnrollmentCaptureServices(prepare: { [unowned self] in
            if let preparationError { throw preparationError }
            return { [unowned self] image in
                analysisCount += 1
                previewObserved = model.previewImage != nil
                if let customAnalysis { return try await customAnalysis(image) }
                return try result()
            }
        }, requestPermission: { [unowned self] in permission },
           permissionDenied: { [unowned self] in denied },
           makeCamera: { [unowned self] in
               if !camera.started { return camera }
               let replacement = FlowCamera()
               cameraSources.append(replacement)
               return replacement
           }, now: { [unowned self] in time })
        model = EnrollmentModel(vault: vault, session: session, captureServices: services)
    }

    func result() throws -> FaceAnalysis {
        let pose = EnrollmentPose.allCases[min(index, 8)]
        let yaw: Double
        switch pose {
        case .left, .upperLeft, .lowerLeft: yaw = 0.25
        case .right, .upperRight, .lowerRight: yaw = -0.25
        default: yaw = 0
        }
        let pitch: Double
        switch pose {
        case .up, .upperLeft, .upperRight: pitch = -0.20
        case .down, .lowerLeft, .lowerRight: pitch = 0.20
        default: pitch = 0
        }
        let light = 120.0
        let metrics = EnrollmentMetrics(quality: 0.8, yaw: yaw, pitch: pitch, roll: 0,
                                        faceWidthPixels: 180, faceHeightPixels: 200, centered: true, luminance: light,
                                        faceBounds: FaceBounds(x: 0.36, y: 0.3, width: 0.28, height: 0.4))
        return FaceAnalysis(embedding: try FaceEmbedding(raw: Array(repeating: 1, count: 512), modelIdentifier: ArcFaceContract.identifier),
                            quality: 0.8, inferenceMilliseconds: 1, enrollmentMetrics: metrics)
    }

    func sendFrame(frames: Int = 16) async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let image = try XCTUnwrap(context.makeImage())
        for _ in 0..<frames {
            time += 0.125
            cameraSources.last!.continuation.yield(image)
            for _ in 0..<24 { await Task.yield() }
        }
    }
}

final class EnrollmentFlowTests: XCTestCase {
    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("The enrollment flow did not reach the expected state", file: file, line: line)
    }

    @MainActor
    func testSwitchingAppsStopsCameraAndResumesWithCapturedViewsAndOriginalAuthorization() async throws {
        let fixture = FlowFixture()
        defer { fixture.model.cancel() }
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        try await fixture.sendFrame()
        await waitUntil { fixture.model.sampleCount == 2 }
        XCTAssertNotNil(fixture.model.detectedFaceBounds)
        fixture.foreground = false
        try await fixture.sendFrame()
        await waitUntil { fixture.model.phase == .paused }
        XCTAssertTrue(fixture.camera.stopped)
        XCTAssertNil(fixture.model.previewImage)
        XCTAssertNil(fixture.model.detectedFaceBounds)
        XCTAssertEqual(fixture.model.sampleCount, 2)
        XCTAssertFalse(fixture.model.canSave)
        fixture.foreground = true
        await Task.yield()
        XCTAssertEqual(fixture.model.phase, .paused, "Returning to the app alone must not restart the camera")
        fixture.model.resume()
        await waitUntil { fixture.model.phase == .capturing && fixture.cameraSources.count == 2 }
        for index in 1..<EnrollmentPose.allCases.count {
            fixture.index = index
            try await fixture.sendFrame()
            await waitUntil { fixture.model.sampleCount == (index + 1) * 2 }
        }
        await waitUntil { fixture.model.phase == .review && !fixture.model.isBusy }
        XCTAssertEqual(fixture.auth.calls, 1)
        XCTAssertTrue(fixture.cameraSources.allSatisfy(\.stopped))
        XCTAssertNil(fixture.blobs.data)
        fixture.model.save()
        XCTAssertEqual(fixture.model.phase, .saved)
        XCTAssertTrue(fixture.model.hasEnrollment)
    }

    @MainActor
    func testCanceledPausedScanDiscardsProgressAndReleasesWaitingTask() async throws {
        let fixture = FlowFixture()
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        try await fixture.sendFrame()
        await waitUntil { fixture.model.sampleCount == 2 }
        fixture.foreground = false
        try await fixture.sendFrame()
        await waitUntil { fixture.model.phase == .paused }
        fixture.model.cancel()
        await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.model.sampleCount, 0)
        XCTAssertNil(fixture.model.previewImage)
        XCTAssertNil(fixture.blobs.data)
        XCTAssertEqual(fixture.cameraSources.count, 1)
    }

    @MainActor
    func testPauseDoesNotExtendLeaseAndAccountChangeCannotResume() async throws {
        for changeAccount in [false, true] {
            let fixture = FlowFixture()
            defer { fixture.model.cancel() }
            fixture.model.start()
            await waitUntil { fixture.model.phase == .capturing }
            try await fixture.sendFrame()
            await waitUntil { fixture.model.sampleCount == 2 }
            fixture.foreground = false
            try await fixture.sendFrame()
            await waitUntil { fixture.model.phase == .paused }
            fixture.foreground = true
            if changeAccount { fixture.consoleUID = 502 }
            else { fixture.leaseTime = 280 }
            fixture.model.resume()
            await waitUntil { fixture.model.phase == .failed && !fixture.model.isBusy }
            XCTAssertEqual(fixture.model.sampleCount, 0)
            XCTAssertEqual(fixture.cameraSources.count, 1)
            XCTAssertNil(fixture.model.previewImage)
            XCTAssertNil(fixture.blobs.data)
        }
    }

    @MainActor
    func testLateAnalysisAfterFocusLossIsDiscardedAndCameraPauses() async throws {
        let fixture = FlowFixture()
        defer { fixture.model.cancel() }
        var continuation: CheckedContinuation<FaceAnalysis, any Error>?
        fixture.customAnalysis = { _ in try await withCheckedThrowingContinuation { continuation = $0 } }
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        try await fixture.sendFrame()
        await waitUntil { continuation != nil }
        fixture.foreground = false
        continuation?.resume(returning: try fixture.result())
        await waitUntil { fixture.model.phase == .paused }
        XCTAssertEqual(fixture.model.sampleCount, 0)
        XCTAssertTrue(fixture.camera.stopped)
        XCTAssertNil(fixture.model.previewImage)
        XCTAssertNil(fixture.model.detectedFaceBounds)
        XCTAssertNil(fixture.blobs.data)
    }

    @MainActor
    func testCompletedScanCanWaitInBackgroundButSavingRequiresForeground() async throws {
        let fixture = FlowFixture()
        defer { fixture.model.cancel() }
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        for index in 0..<EnrollmentPose.allCases.count {
            fixture.index = index
            try await fixture.sendFrame()
            await waitUntil { fixture.model.sampleCount == (index + 1) * 2 }
        }
        await waitUntil { fixture.model.phase == .review && !fixture.model.isBusy }
        fixture.foreground = false
        fixture.model.save()
        XCTAssertTrue(fixture.model.canSave)
        XCTAssertNil(fixture.blobs.data)
        try await Task.sleep(for: .milliseconds(1100)) // Exercise the actual watchdog while backgrounded.
        XCTAssertEqual(fixture.model.phase, .review)
        XCTAssertTrue(fixture.model.canSave)
        fixture.foreground = true
        fixture.model.save()
        XCTAssertEqual(fixture.model.phase, .saved)
        XCTAssertTrue(fixture.model.hasEnrollment)
    }

    @MainActor
    func testRingProgressRequiresAStableBurstInsteadOfOneMatchingFrame() async throws {
        let fixture = FlowFixture()
        defer { fixture.model.cancel() }
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        try await fixture.sendFrame()
        await waitUntil { fixture.model.sampleCount == 2 }
        fixture.index = 1
        try await fixture.sendFrame(frames: 4)
        XCTAssertEqual(fixture.model.sampleCount, 2)
        XCTAssertGreaterThan(fixture.model.holdProgress, 0)
        XCTAssertLessThan(fixture.model.holdProgress, 1)
        XCTAssertNotNil(fixture.model.detectedFaceBounds)
        XCTAssertNil(fixture.blobs.data)
    }

    @MainActor
    func testGuidedCaptureStopsCameraBeforeReviewAndOnlySavesOnExplicitAction() async throws {
        let fixture = FlowFixture()
        defer { fixture.model.cancel() }
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        XCTAssertTrue(fixture.camera.started)
        XCTAssertEqual(fixture.auth.calls, 1)
        for index in 0..<EnrollmentPose.allCases.count {
            fixture.index = index
            try await fixture.sendFrame()
            await waitUntil { fixture.model.sampleCount == (index + 1) * 2 }
        }
        await waitUntil { fixture.model.phase == .review && !fixture.model.isBusy }
        XCTAssertTrue(fixture.previewObserved)
        XCTAssertTrue(fixture.camera.stopped)
        XCTAssertNil(fixture.model.previewImage)
        XCTAssertTrue(fixture.model.canSave)
        XCTAssertNil(fixture.blobs.data)
        fixture.model.save()
        XCTAssertEqual(fixture.model.phase, .saved)
        XCTAssertTrue(fixture.model.hasEnrollment)
        XCTAssertFalse(fixture.model.canSave)
        XCTAssertTrue(fixture.blobs.data?.starts(with: Data("FUE1".utf8)) == true)
    }

    @MainActor
    func testCancelClearsPreviewAndPendingDescriptorsWithoutSaving() async throws {
        let fixture = FlowFixture()
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        try await fixture.sendFrame()
        await waitUntil { fixture.model.sampleCount == 2 }
        XCTAssertNotNil(fixture.model.previewImage)
        fixture.model.cancel()
        XCTAssertNil(fixture.model.previewImage)
        XCTAssertEqual(fixture.model.phase, .idle)
        await waitUntil { !fixture.model.isBusy }
        XCTAssertTrue(fixture.camera.stopped)
        XCTAssertEqual(fixture.model.sampleCount, 0)
        XCTAssertFalse(fixture.model.canSave)
        XCTAssertNil(fixture.blobs.data)
        XCTAssertEqual(fixture.model.status, "Setup canceled. Any saved face is unchanged.")
    }

    @MainActor
    func testLateAnalysisAfterCancelCannotRestorePreviewOrAdvanceCapture() async throws {
        let fixture = FlowFixture()
        var continuation: CheckedContinuation<FaceAnalysis, any Error>?
        fixture.customAnalysis = { _ in try await withCheckedThrowingContinuation { continuation = $0 } }
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        try await fixture.sendFrame()
        await waitUntil { continuation != nil }
        fixture.model.cancel()
        continuation?.resume(returning: try fixture.result())
        await waitUntil { !fixture.model.isBusy }
        XCTAssertNil(fixture.model.previewImage)
        XCTAssertEqual(fixture.model.sampleCount, 0)
        XCTAssertFalse(fixture.model.canSave)
        XCTAssertNil(fixture.blobs.data)
        XCTAssertEqual(fixture.model.phase, .idle)
    }

    @MainActor
    func testNoFaceShowsPositioningHintWhilePreviewRemainsLive() async throws {
        let fixture = FlowFixture()
        defer { fixture.model.cancel() }
        fixture.customAnalysis = { _ in throw RecognitionError.noFace }
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        try await fixture.sendFrame()
        await waitUntil { fixture.model.status.contains("Bring your face into the circle") }
        XCTAssertNotNil(fixture.model.previewImage)
        XCTAssertEqual(fixture.model.phase, .capturing)
        XCTAssertEqual(fixture.model.sampleCount, 0)
        XCTAssertFalse(fixture.model.faceIsReady)
    }

    @MainActor
    func testMissingCaptureMetadataShowsDetectorFeedbackInsteadOfBlamingLighting() async throws {
        let fixture = FlowFixture()
        defer { fixture.model.cancel() }
        let embedding = try fixture.result().embedding
        fixture.customAnalysis = { _ in
            FaceAnalysis(embedding: embedding, quality: 0.8, inferenceMilliseconds: 1, enrollmentMetrics: nil)
        }
        fixture.model.start()
        await waitUntil { fixture.model.phase == .capturing }
        try await fixture.sendFrame()
        await waitUntil { fixture.model.status.contains("measure its angle") }
        XCTAssertEqual(fixture.model.sampleCount, 0)
        XCTAssertFalse(fixture.model.canSave)
        XCTAssertFalse(fixture.model.faceIsReady)
        XCTAssertNotEqual(fixture.model.status, "Face the camera in even light and hold still.")
    }

    @MainActor
    func testCameraDenialOffersSettingsAndNeverStartsCapture() async throws {
        let fixture = FlowFixture()
        fixture.permission = false; fixture.denied = true
        fixture.model.start()
        await waitUntil { fixture.model.phase == .failed && !fixture.model.isBusy }
        XCTAssertTrue(fixture.model.cameraSettingsNeeded)
        XCTAssertFalse(fixture.camera.started)
        XCTAssertNil(fixture.model.previewImage)
        XCTAssertNil(fixture.blobs.data)
    }

    @MainActor
    func testBadModelCannotOpenCamera() async throws {
        let fixture = FlowFixture()
        fixture.preparationError = RecognitionError.reference
        fixture.model.start()
        await waitUntil { fixture.model.phase == .failed && !fixture.model.isBusy }
        XCTAssertFalse(fixture.camera.started)
        XCTAssertNil(fixture.model.previewImage)
        XCTAssertNil(fixture.blobs.data)
    }
}
