import XCTest
@testable import FaceUnlockCore

final class FaceComparisonTests: XCTestCase {
    private func embedding(_ score: Double = 1, model: String = "test") throws -> FaceEmbedding {
        var values = Array(repeating: Float(0), count: 512)
        values[0] = Float(score); values[1] = Float(sqrt(max(0, 1 - score * score)))
        return try FaceEmbedding(raw: values, modelIdentifier: model)
    }

    private func template(_ vectors: [FaceEmbedding]? = nil) throws -> EnrollmentTemplate {
        try EnrollmentTemplate(embeddings: vectors ?? Array(repeating: embedding(), count: 18), modelIdentifier: "test")
    }

    private func metrics(quality: Double = 0.8, bounds: FaceBounds? = FaceBounds(x: 0.3, y: 0.2, width: 0.3, height: 0.5)) -> EnrollmentMetrics {
        EnrollmentMetrics(quality: quality, yaw: 0, pitch: -0.4, roll: 0, faceWidthPixels: 180,
                          faceHeightPixels: 200, centered: true, luminance: 120, faceBounds: bounds)
    }

    func testFreshCameraCadenceReachesUnchangedWindowSoonerWithLessAnalysis() throws {
        func simulate(fps: Double, scheduled: Bool) throws -> (time: Double, analyzed: Int) {
            var window = try FaceComparisonWindow(template: template())
            var analyzed = 0
            for frame in 0..<200 {
                let time = Double(frame) / fps
                if scheduled && !window.shouldAnalyze(at: time) { continue }
                analyzed += 1
                if try window.observe(embedding(), metrics: metrics(), at: time) != nil { return (time, analyzed) }
            }
            throw EnrollmentError.incomplete
        }
        let old = try simulate(fps: 10, scheduled: false)
        let current = try simulate(fps: 30, scheduled: true)
        XCTAssertEqual(old.time, 2.2, accuracy: 1e-6)
        XCTAssertEqual(current.time, 11.0 / 6, accuracy: 1e-6)
        XCTAssertEqual(current.analyzed, 12)
        XCTAssertGreaterThan(old.analyzed, current.analyzed)
        XCTAssertGreaterThanOrEqual(current.time, FaceComparisonPolicy.minimumDuration)
    }

    func testEvaluationCandidateDoesNotChangeDefaultOrPretendToRejectReplay() throws {
        for mode in FaceComparisonMode.allCases {
            for (score, expected) in [(0.8, FaceComparisonOutcome.similar), (0.1, .different)] {
                var window = try FaceComparisonWindow(template: template(), mode: mode)
                for frame in 0..<mode.requiredFrames {
                    try window.observe(embedding(score), metrics: metrics(), at: Double(frame) * 0.15)
                    if frame < mode.requiredFrames - 1 { XCTAssertNil(window.result) }
                }
                XCTAssertEqual(window.result?.outcome, expected)
            }
            // Repeated identical embeddings also represent a matching photo/video: no PAD is implied.
            var replay = try FaceComparisonWindow(template: template(), mode: mode)
            for frame in 0..<mode.requiredFrames {
                try replay.observe(embedding(), metrics: metrics(), at: Double(frame) * 0.15)
            }
            XCTAssertEqual(replay.result?.outcome, .similar)
        }
        XCTAssertEqual(FaceComparisonMode.standard.requiredFrames, 12)
        var baseline = try FaceComparisonWindow(template: template())
        for frame in 0..<6 { try baseline.observe(embedding(), metrics: metrics(), at: Double(frame) * 0.15) }
        XCTAssertNil(baseline.result)
    }

    func testSeveralFramesAreRequiredForSimilarDifferentAndBorderlineDecisions() throws {
        for (score, expected) in [(0.8, FaceComparisonOutcome.similar), (0.1, .different), (0.45, .inconclusive)] {
            var window = try FaceComparisonWindow(template: template())
            let probe = try embedding(score)
            for index in 0..<11 {
                XCTAssertNil(try window.observe(probe, metrics: metrics(), at: 10 + Double(index) * 0.2))
            }
            let result = try XCTUnwrap(window.observe(probe, metrics: metrics(), at: 12.2))
            XCTAssertEqual(result.outcome, expected)
            XCTAssertEqual(result.medianSimilarity, score, accuracy: 1e-6)
            XCTAssertEqual(result.frameCount, 12)
        }
    }

    func testOneHighTemplateCannotMakeAnUnknownFaceSimilar() throws {
        let enrolled = try embedding()
        let other = try embedding(0)
        var window = try FaceComparisonWindow(template: template([enrolled] + Array(repeating: other, count: 17)))
        for index in 0..<12 { try window.observe(enrolled, metrics: metrics(), at: Double(index) * 0.2) }
        XCTAssertEqual(window.result?.outcome, .different)
        XCTAssertEqual(try XCTUnwrap(window.result).medianSimilarity, 1.0 / 3, accuracy: 1e-6)
    }

    func testHighMedianWithInconsistentFramesIsInconclusive() throws {
        var window = try FaceComparisonWindow(template: template())
        for index in 0..<12 {
            try window.observe(embedding(index < 9 ? 0.8 : 0.45), metrics: metrics(), at: Double(index) * 0.2)
        }
        XCTAssertEqual(window.result?.outcome, .inconclusive)
        XCTAssertEqual(window.result?.aboveCutoff, 9)
    }

    func testDuplicateTooFastAndGappedObservationsCannotCompleteWindow() throws {
        var window = try FaceComparisonWindow(template: template())
        try window.observe(embedding(), metrics: metrics(), at: 10)
        for index in 1..<100 { try window.observe(embedding(), metrics: metrics(), at: 10 + Double(index) * 0.0005) }
        XCTAssertEqual(window.count, 1)
        try window.observe(embedding(), metrics: metrics(), at: 11)
        XCTAssertEqual(window.count, 1, "A gap clears earlier evidence")
        try window.observe(embedding(), metrics: metrics(), at: 11)
        XCTAssertEqual(window.count, 0, "A duplicate/backward timestamp clears evidence")
        XCTAssertNil(window.result)
    }

    func testQualityFailureOrDetectionLossClearsPreviousScores() throws {
        var window = try FaceComparisonWindow(template: template())
        for index in 0..<5 { try window.observe(embedding(), metrics: metrics(), at: Double(index) * 0.2) }
        try window.observe(embedding(), metrics: metrics(quality: .nan), at: 1.0)
        XCTAssertEqual(window.count, 0)
        XCTAssertNil(window.latestSimilarity)
        try window.observe(embedding(), metrics: metrics(), at: 1.2)
        window.interrupt()
        XCTAssertEqual(window.count, 0)
        XCTAssertNotNil(FaceComparisonWindow.adjustment(for: metrics(bounds: nil)))
        XCTAssertNotNil(FaceComparisonWindow.adjustment(for: metrics(bounds: FaceBounds(x: -0.1, y: 0, width: 0.5, height: 0.5))))
    }

    func testModestMovementRelativeToFaceSizeKeepsEvidence() throws {
        var window = try FaceComparisonWindow(template: template())
        for index in 0..<5 { try window.observe(embedding(), metrics: metrics(), at: Double(index) * 0.2) }
        try window.observe(embedding(), metrics: metrics(bounds: FaceBounds(x: 0.44, y: 0.2, width: 0.3, height: 0.5)), at: 1)
        XCTAssertEqual(window.count, 6, "Overlapping same-size face movement should not use a fixed screen-distance cutoff")
        XCTAssertNil(window.result)
    }

    func testNewestNonmatchCannotUseOlderOwnerVotesAndReentryStartsFresh() throws {
        var window = try FaceComparisonWindow(template: template())
        for frame in 0..<12 { try window.observe(embedding(0.8), metrics: metrics(), at: Double(frame) * 0.2) }
        XCTAssertEqual(window.result?.outcome, .similar)
        try window.observe(embedding(0.45), metrics: metrics(), at: 2.4)
        XCTAssertNotEqual(window.result?.outcome, .similar, "Newest frame must independently match")
        try window.observe(embedding(0.1), metrics: metrics(), at: 2.6)
        try window.observe(embedding(0.8), metrics: metrics(), at: 2.8)
        XCTAssertEqual(window.count, 1)
        XCTAssertNil(window.result)
    }

    func testRelativeContinuityRejectsTinyFaceJumpsLargeScaleChangesAndInvalidBounds() {
        let face = FaceBounds(x: 0.3, y: 0.3, width: 0.1, height: 0.1)
        XCTAssertFalse(FaceTrackContinuity.isContinuous(from: face, to: FaceBounds(x: 0.4, y: 0.3, width: 0.1, height: 0.1)))
        XCTAssertFalse(FaceTrackContinuity.isContinuous(from: face, to: FaceBounds(x: 0.3, y: 0.3, width: 0.3, height: 0.3)))
        XCTAssertFalse(FaceTrackContinuity.isContinuous(from: face, to: FaceBounds(x: .nan, y: 0, width: 0.1, height: 0.1)))
    }

    func testAbruptFacePositionChangesRestartEvidence() throws {
        var window = try FaceComparisonWindow(template: template())
        for index in 0..<5 { try window.observe(embedding(), metrics: metrics(), at: Double(index) * 0.2) }
        try window.observe(embedding(), metrics: metrics(bounds: FaceBounds(x: 0.6, y: 0.2, width: 0.3, height: 0.5)), at: 1.0)
        XCTAssertEqual(window.count, 1)
        XCTAssertNil(window.result)
    }

    func testModelMismatchAndLegacyTemplatesFailClosed() throws {
        var window = try FaceComparisonWindow(template: template())
        try window.observe(embedding(), metrics: metrics(), at: 0)
        XCTAssertThrowsError(try window.observe(embedding(model: "different"), metrics: metrics(), at: 0.2))
        XCTAssertEqual(window.count, 0)
        let legacy = try EnrollmentTemplate(embeddings: Array(repeating: embedding(), count: 7), modelIdentifier: "test", format: .legacySevenViews)
        XCTAssertThrowsError(try FaceComparisonWindow(template: legacy))
    }

    func testPrintableFormsRedactDescriptorsAndScores() throws {
        var window = try FaceComparisonWindow(template: template())
        for index in 0..<12 { try window.observe(embedding(0.812345), metrics: metrics(), at: Double(index) * 0.2) }
        XCTAssertTrue(String(reflecting: window).contains("redacted"))
        XCTAssertTrue(String(reflecting: try XCTUnwrap(window.result)).contains("redacted"))
        XCTAssertFalse(String(describing: window).contains("0.812"))
    }

    func testRollingComparisonDoesNotFreezeAnOldMatch() throws {
        var window = try FaceComparisonWindow(template: template())
        for index in 0..<12 { try window.observe(embedding(0.8), metrics: metrics(), at: Double(index) * 0.2) }
        XCTAssertEqual(window.result?.outcome, .similar)
        for index in 12..<24 { try window.observe(embedding(0.1), metrics: metrics(), at: Double(index) * 0.2) }
        XCTAssertEqual(window.result?.outcome, .different, "A prior match cannot remain frozen while another face supplies a response")
        XCTAssertEqual(window.count, 12)
    }

    func testRestoredWindowRequiresTwelveDistinctSpacedFrames() throws {
        var window = try FaceComparisonWindow(template: template())
        for index in 0..<11 {
            XCTAssertNil(try window.observe(embedding(0.8), metrics: metrics(), at: Double(index) * 0.2))
        }
        XCTAssertEqual(try window.observe(embedding(0.8), metrics: metrics(), at: 2.2)?.outcome, .similar)
    }
}
