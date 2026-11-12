import CoreGraphics
import Foundation
import XCTest
@testable import FaceUnlockApp
import FaceUnlockCore
@testable import FaceUnlockRecognition

@MainActor
private final class HiddenCamera: EnrollmentCapturing {
    let frames: AsyncThrowingStream<CGImage, any Error>
    let continuation: AsyncThrowingStream<CGImage, any Error>.Continuation
    var started = false
    var stopped = false
    var joins = 0
    var afterJoin: (() -> Void)?
    init() {
        let stream = AsyncThrowingStream<CGImage, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        frames = stream.stream; continuation = stream.continuation
    }
    func start() { started = true }
    func stop() { stopped = true; continuation.finish() }
    func stopAndWait() async { stop(); joins += 1; afterJoin?() }
}

@MainActor
private final class HiddenScanFixture {
    let camera = HiddenCamera()
    var time = 100.0
    var noFace = false
    var score = 1.0
    var deadline: Double?
    var analysisCount = 0
    var canScan = true
    var scanner: LockScreenFaceScanner!
    let template: EnrollmentTemplate
    let analysis: FaceAnalysis
    init() throws {
        var values = [Float](repeating: 0, count: 512); values[0] = 1
        let embedding = try FaceEmbedding(raw: values, modelIdentifier: "hidden-test")
        template = try EnrollmentTemplate(embeddings: Array(repeating: embedding, count: 18), modelIdentifier: "hidden-test")
        let metrics = EnrollmentMetrics(quality: 0.8, yaw: 0, pitch: -0.4, roll: 0,
            faceWidthPixels: 180, faceHeightPixels: 200, centered: true, luminance: 120,
            faceBounds: FaceBounds(x: 0.3, y: 0.2, width: 0.3, height: 0.5))
        analysis = FaceAnalysis(embedding: embedding, quality: 0.8, inferenceMilliseconds: 1, enrollmentMetrics: metrics)
        let services = EnrollmentCaptureServices(prepare: { [unowned self] in
            return { _ in
                self.analysisCount += 1
                if self.noFace { throw RecognitionError.noFace }
                var values = [Float](repeating: 0, count: 512)
                values[0] = Float(self.score); values[1] = Float(sqrt(1 - self.score * self.score))
                return FaceAnalysis(embedding: try FaceEmbedding(raw: values, modelIdentifier: "hidden-test"),
                    quality: self.analysis.quality, inferenceMilliseconds: 1, enrollmentMetrics: self.analysis.enrollmentMetrics)
            }
        }, requestPermission: { true }, permissionDenied: { false }, makeCamera: { [unowned self] in camera }, now: { 0 })
        // A separate continuous-time clock binds evidence to the unlock permit, not capture uptime.
        scanner = LockScreenFaceScanner(services: services, now: { [unowned self] in time })
    }

    func check() throws {
        if !canScan { throw FaceUnlockAttemptError.session }
        if let deadline, time >= deadline { throw FaceUnlockAttemptError.expired }
    }

    func send(_ count: Int) async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        for _ in 0..<count {
            time += 0.2
            camera.continuation.yield(image)
            for _ in 0..<40 { await Task.yield() }
        }
    }
}

final class LockScreenScannerTests: XCTestCase {
    @MainActor
    func testHiddenScanUsesTwelveFramesAndNeverPromotesComparisonToAuthentication() async throws {
        let fixture = try HiddenScanFixture()
        try await fixture.scanner.prepare()
        let id = UUID()
        let scan = Task { try await fixture.scanner.scan(template: fixture.template, attemptID: id, check: fixture.check) }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(fixture.camera.started)
        try await fixture.send(12)
        // Finishing the stream makes insufficient-frame failures deterministic instead of hanging.
        fixture.camera.stop()
        let result = try await scan.value
        XCTAssertEqual(result.comparison, .similar)
        XCTAssertEqual(result.verification.identity, .experimentalMatch)
        XCTAssertEqual(result.verification.liveness, .unavailable)
        XCTAssertEqual(result.verification.attemptID, id)
        XCTAssertEqual(result.verification.observedAt, fixture.time, accuracy: 1e-6)
        XCTAssertTrue(fixture.camera.stopped)
    }

    @MainActor
    func testDetectionLossClearsPartialWindowAndRequiresTwelveNewFrames() async throws {
        let fixture = try HiddenScanFixture()
        try await fixture.scanner.prepare()
        let scan = Task { try await fixture.scanner.scan(template: fixture.template, attemptID: UUID(), check: fixture.check) }
        for _ in 0..<100 { await Task.yield() }
        try await fixture.send(5)
        fixture.noFace = true
        try await fixture.send(1)
        fixture.noFace = false
        try await fixture.send(11)
        XCTAssertFalse(fixture.camera.stopped)
        try await fixture.send(1)
        fixture.camera.stop()
        let result = try await scan.value
        XCTAssertEqual(result.comparison, .similar)
        XCTAssertEqual(fixture.analysisCount, 18)
    }

    @MainActor
    func testLockedAccountLossStopsCaptureWithoutReturningComparison() async throws {
        let fixture = try HiddenScanFixture()
        try await fixture.scanner.prepare()
        let scan = Task { try await fixture.scanner.scan(template: fixture.template, attemptID: UUID(), check: fixture.check) }
        for _ in 0..<100 { await Task.yield() }
        try await fixture.send(3)
        fixture.canScan = false
        try await fixture.send(1)
        fixture.camera.stop()
        do { _ = try await scan.value; XCTFail("A changed account must stop the scan") }
        catch { XCTAssertTrue(fixture.camera.stopped) }
    }
    @MainActor
    func testInitialDifferentOrBorderlineWindowDoesNotEndScanBeforeLaterMatch() async throws {
        for score in [0.1, 0.45] {
            let fixture = try HiddenScanFixture()
            fixture.score = score
            try await fixture.scanner.prepare()
            let scan = Task { try await fixture.scanner.scan(template: fixture.template, attemptID: UUID(), check: fixture.check) }
            for _ in 0..<100 { await Task.yield() }
            try await fixture.send(12)
            XCTAssertFalse(fixture.camera.stopped, "A negative initial window must not reject the owner immediately")
            fixture.score = 1
            try await fixture.send(12)
            fixture.camera.stop()
            let result = try await scan.value
            XCTAssertEqual(result.comparison, .similar)
            XCTAssertGreaterThanOrEqual(fixture.scanner.diagnostics.analyzedFrames, 22)
            await fixture.scanner.finish()
        }
    }

    @MainActor
    func testNonmatchingInputStillCannotContinueBeyondDeadline() async throws {
        let fixture = try HiddenScanFixture()
        fixture.score = 0.1; fixture.deadline = 103
        try await fixture.scanner.prepare()
        let scan = Task { try await fixture.scanner.scan(template: fixture.template, attemptID: UUID(), check: fixture.check) }
        for _ in 0..<100 { await Task.yield() }
        try await fixture.send(16)
        fixture.camera.stop()
        do { _ = try await scan.value; XCTFail("No match may authorize beyond the deadline") }
        catch { XCTAssertEqual(error as? FaceUnlockAttemptError, .expired) }
        XCTAssertTrue(fixture.camera.stopped)
    }

    @MainActor
    func testCameraShutdownIsJoinedAfterReturningFreshEvidence() async throws {
        let fixture = try HiddenScanFixture()
        fixture.camera.afterJoin = { fixture.time += 1 }
        try await fixture.scanner.prepare()
        let scan = Task { try await fixture.scanner.scan(template: fixture.template, attemptID: UUID(), check: fixture.check) }
        for _ in 0..<100 { await Task.yield() }
        try await fixture.send(12)
        fixture.camera.stop()
        let result = try await scan.value
        XCTAssertEqual(fixture.camera.joins, 0)
        XCTAssertEqual(result.verification.observedAt, fixture.time, accuracy: 1e-6)
        await fixture.scanner.finish()
        XCTAssertEqual(fixture.camera.joins, 1)
        XCTAssertGreaterThan(fixture.time - result.verification.observedAt, FaceUnlockAttempt.evidenceMaximumAge)
    }

}
