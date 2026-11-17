import XCTest
@testable import FaceUnlockApp

final class FaceIDAnimationTests: XCTestCase {
    func testOnlyConfirmedUnlockShowsSuccess() {
        XCTAssertEqual(FaceIDAnimationStage(.scanning), .scanning)
        for phase in [LockScreenPhase.waitingForPasswordField, .submitting, .awaitingDesktop] {
            XCTAssertEqual(FaceIDAnimationStage(phase), .processing)
        }
        XCTAssertEqual(FaceIDAnimationStage(.unlocked), .unlocked)
        XCTAssertEqual(FaceIDAnimationStage(.fallback), .fallback)
    }

    @MainActor
    func testProcessingSubstagesAndRepositioningPreserveAnimationClocks() {
        let presentation = LockScreenIndicatorPresentation()
        presentation.update(phase: .scanning, safeTop: 32, width: 196, failureCaption: nil, now: 10)
        presentation.update(phase: .waitingForPasswordField, safeTop: 32, width: 196, failureCaption: nil, now: 12)
        presentation.update(phase: .submitting, safeTop: 32, width: 196, failureCaption: nil, now: 12.1)
        presentation.update(phase: .awaitingDesktop, safeTop: 0, width: 180, failureCaption: nil, now: 12.2)
        XCTAssertEqual(presentation.startedAt, 10)
        XCTAssertEqual(presentation.stageBeganAt, 12)
        presentation.update(phase: .unlocked, safeTop: 0, width: 180, failureCaption: nil, now: 13)
        XCTAssertEqual(presentation.stageBeganAt, 13)
        presentation.reset()
        presentation.update(phase: .scanning, safeTop: 32, width: 196, failureCaption: nil, now: 20)
        XCTAssertEqual(presentation.startedAt, 20)
        XCTAssertEqual(presentation.stageBeganAt, 20)
    }
}
