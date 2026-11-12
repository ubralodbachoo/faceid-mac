import AVFoundation
import XCTest
@testable import FaceUnlockRecognition

final class CameraReuseTests: XCTestCase {
    @MainActor
    func testFreshCapturesShareConfiguredSessionButNeverReuseEndedStreams() async throws {
        let backend = EnrollmentCameraSession()
        let first = EnrollmentCamera(session: backend)
        let second = EnrollmentCamera(session: backend)
        XCTAssertTrue(first.previewSession === second.previewSession)
        await first.stopAndWait()
        var oldIterator = first.frames.makeAsyncIterator()
        let oldFrame = try await oldIterator.next()
        XCTAssertNil(oldFrame)
        var ended = false
        let reader = Task {
            var iterator = second.frames.makeAsyncIterator()
            _ = try await iterator.next()
            ended = true
        }
        await first.stopAndWait()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(ended, "Stopping the old capture cannot terminate the new stream")
        // No camera permission or hardware capture is used by this lifecycle test.
        await second.stopAndWait()
        try await reader.value
    }

    func testStopBeforeStartDoesNotOpenSensorOrResurrectStream() async throws {
        let camera = EnrollmentCamera(session: EnrollmentCameraSession())
        await camera.stopAndWait()
        camera.start()
        await camera.stopAndWait()
        XCTAssertFalse(camera.previewSession.isRunning)
        var iterator = camera.frames.makeAsyncIterator()
        let frame = try await iterator.next()
        XCTAssertNil(frame)
    }
}
