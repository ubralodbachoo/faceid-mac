import XCTest
import FaceUnlockCore

final class VideoEnrollmentTests: XCTestCase {
    private let model = "synthetic-video-test"

    private func embedding(_ seed: Float = 1) throws -> FaceEmbedding {
        try FaceEmbedding(raw: (0..<512).map { Float($0 % 17) + seed }, modelIdentifier: model)
    }

    private func metrics(_ pose: EnrollmentPose = .center, yawOffset: Double = 0, pitchOffset: Double = 0,
                         quality: Double = 0.8) -> EnrollmentMetrics {
        let yaw: Double
        switch pose {
        case .left, .upperLeft, .lowerLeft: yaw = 0.25
        case .right, .upperRight, .lowerRight: yaw = -0.25
        default: yaw = 0
        }
        let pitch: Double
        switch pose {
        case .up, .upperLeft, .upperRight: pitch = -0.2
        case .down, .lowerLeft, .lowerRight: pitch = 0.2
        default: pitch = 0
        }
        return EnrollmentMetrics(quality: quality, yaw: yaw + yawOffset, pitch: pitch + pitchOffset, roll: 0,
            faceWidthPixels: 160, faceHeightPixels: 190, centered: true, luminance: 120,
            faceBounds: FaceBounds(x: 0.36, y: 0.3, width: 0.28, height: 0.4))
    }

    private func burst(_ pose: EnrollmentPose, collector: inout VideoEnrollmentCollector,
                       time: inout Double, offsetYaw: Double = 0, offsetPitch: Double = 0) throws {
        let target = pose.rawValue + 1
        for _ in 0..<24 {
            time += 0.125
            _ = try collector.observe(embedding(), metrics: metrics(pose, yawOffset: offsetYaw, pitchOffset: offsetPitch), at: time)
            if collector.completedPoses >= target { return }
        }
        XCTFail("A stable continuous burst did not complete its guided direction")
    }

    func testNaturalCameraAngleCalibratesAndNineDirectionsProduceEighteenSamplesWithoutLightTasks() throws {
        var collector = VideoEnrollmentCollector(modelIdentifier: model)
        var time = 0.0
        XCTAssertThrowsError(try collector.finish())
        for pose in EnrollmentPose.allCases {
            try burst(pose, collector: &collector, time: &time, offsetYaw: 0.12, offsetPitch: -0.4)
            XCTAssertEqual(collector.sampleCount, (pose.rawValue + 1) * 2)
        }
        let template = try collector.finish()
        XCTAssertEqual(template.format, .continuousVideo)
        XCTAssertEqual(template.embeddings.count, 18)
        XCTAssertTrue(String(reflecting: collector).contains("redacted"))
        XCTAssertTrue(String(reflecting: template).contains("redacted"))
    }

    func testSingleMatchingFramesRepeatedTimestampsAndDisconnectedBurstsCannotCompleteAnAngle() throws {
        var collector = VideoEnrollmentCollector(modelIdentifier: model)
        for index in 0..<20 {
            _ = try collector.observe(embedding(), metrics: metrics(), at: Double(index)) // Gaps exceed continuity limit.
        }
        XCTAssertEqual(collector.sampleCount, 0)
        collector.interrupt()
        for _ in 0..<20 { _ = try collector.observe(embedding(), metrics: metrics(), at: 50) }
        XCTAssertEqual(collector.sampleCount, 0)
        XCTAssertThrowsError(try collector.finish())
    }

    func testPauseKeepsCompletedAnglesButDiscardsUnfinishedWindowAndRequiresFreshWarmup() throws {
        var collector = VideoEnrollmentCollector(modelIdentifier: model)
        var time = 0.0
        try burst(.center, collector: &collector, time: &time)
        for _ in 0..<4 {
            time += 0.125
            _ = try collector.observe(embedding(), metrics: metrics(.left), at: time)
        }
        XCTAssertEqual(collector.completedPoses, 1)
        collector.interrupt(restartWarmup: true)
        for _ in 0..<5 {
            time += 0.125
            _ = try collector.observe(embedding(), metrics: metrics(.left), at: time)
        }
        XCTAssertEqual(collector.completedPoses, 1)
        try burst(.left, collector: &collector, time: &time)
        XCTAssertEqual(collector.completedPoses, 2)
    }

    func testNoisyAlternatingHeadTurnsCannotPassThroughSmoothedPoseLag() throws {
        var collector = VideoEnrollmentCollector(modelIdentifier: model)
        var time = 0.0
        try burst(.center, collector: &collector, time: &time)
        for index in 0..<80 {
            time += 0.125
            _ = try collector.observe(embedding(), metrics: metrics(index.isMultiple(of: 2) ? .left : .right), at: time)
        }
        XCTAssertEqual(collector.completedPoses, 1)
        try burst(.left, collector: &collector, time: &time)
        XCTAssertEqual(collector.completedPoses, 2)
    }

    func testLowQualityAndModelMismatchCannotContributeSamples() throws {
        var collector = VideoEnrollmentCollector(modelIdentifier: model)
        for index in 0..<30 {
            _ = try collector.observe(embedding(), metrics: metrics(quality: 0.19), at: Double(index) * 0.125)
        }
        XCTAssertEqual(collector.sampleCount, 0)
        let other = try FaceEmbedding(raw: Array(repeating: 1, count: 512), modelIdentifier: "other")
        XCTAssertThrowsError(try collector.observe(other, metrics: metrics(), at: 10))
        XCTAssertEqual(collector.sampleCount, 0)
        XCTAssertThrowsError(try collector.observe(embedding(), metrics: metrics(), at: .nan))
    }

    func testBestQualityPairIsSelectedFromDifferentMomentsInTheStableBurst() throws {
        var collector = VideoEnrollmentCollector(modelIdentifier: model)
        var time = 0.0
        for index in 0...6 {
            time = Double(index) * 0.125
            let quality = index == 4 ? 0.95 : index == 6 ? 0.99 : 0.5
            _ = try collector.observe(embedding(Float(index + 1)), metrics: metrics(quality: quality), at: time)
        }
        XCTAssertEqual(collector.completedPoses, 1)
        for pose in EnrollmentPose.allCases.dropFirst() { try burst(pose, collector: &collector, time: &time) }
        let template = try collector.finish()
        XCTAssertGreaterThan(try template.embeddings[0].cosineSimilarity(to: embedding(5)), 0.999999)
        XCTAssertGreaterThan(try template.embeddings[1].cosineSimilarity(to: embedding(7)), 0.999999)
    }

    func testBriefTrackingLossClearsBurstButDoesNotRestartCameraWarmup() throws {
        var collector = VideoEnrollmentCollector(modelIdentifier: model)
        for index in 0...3 {
            _ = try collector.observe(embedding(), metrics: metrics(), at: Double(index) * 0.125)
        }
        collector.interrupt()
        for index in 4...7 {
            _ = try collector.observe(embedding(), metrics: metrics(), at: Double(index) * 0.125)
        }
        XCTAssertEqual(collector.completedPoses, 1)
    }
}
