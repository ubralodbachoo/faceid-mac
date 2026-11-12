import Foundation
import XCTest
@testable import FaceUnlockApp
import FaceUnlockMac

@MainActor
private final class SetupFixture {
    var permissions = false
    var face = false
    var passwordSaved = false
    var saveFails = false
    var enableFails = false
    var saves = 0
    var enables = 0
    var enabled = false
    var pendingEnable: CheckedContinuation<Void, any Error>?
    var delayEnable = false
    lazy var model = SetupFlowModel(services: SetupFlowServices(
        permissionsGranted: { [unowned self] in permissions },
        hasFace: { [unowned self] in face }, hasPassword: { [unowned self] in passwordSaved },
        savePassword: { [unowned self] bytes in
            XCTAssertFalse(bytes.isEmpty)
            saves += 1
            if saveFails { throw VaultError.storage }
            passwordSaved = true
        }, enableUnlock: { [unowned self] consent in
            XCTAssertTrue(consent)
            enables += 1
            if enableFails { throw VaultError.authentication }
            if delayEnable { try await withCheckedThrowingContinuation { pendingEnable = $0 } }
            try Task.checkCancellation()
            enabled = true
        }, disableUnlock: { [unowned self] in enabled = false }))

    func reachFinish() {
        permissions = true; model.continuePermissions()
        face = true; model.continueFace()
        passwordSaved = true; model.useSavedPassword()
    }
}

final class SetupFlowTests: XCTestCase {
    @MainActor
    private func idle(_ model: SetupFlowModel) async throws {
        for _ in 0..<1000 {
            if !model.isBusy { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Setup did not finish its operation")
    }

    @MainActor
    func testFourStepsEnableAutomaticUnlockOnlyAtFinish() async throws {
        let fixture = SetupFixture()
        let model = fixture.model
        XCTAssertEqual(model.step, .permissions)
        model.continuePermissions()
        XCTAssertEqual(model.step, .permissions)
        fixture.permissions = true; model.continuePermissions()
        XCTAssertEqual(model.step, .face)
        model.continueFace()
        XCTAssertEqual(model.step, .face)
        fixture.face = true; model.continueFace()
        XCTAssertEqual(model.step, .password)
        model.savePassword(Data("fixture-only".utf8))
        try await idle(model)
        XCTAssertEqual(model.step, .finish)
        XCTAssertEqual(fixture.saves, 1)
        XCTAssertFalse(fixture.enabled)
        XCTAssertFalse(model.isComplete)
        model.finish()
        XCTAssertEqual(fixture.enables, 0, "Consent must be explicit")
        model.acknowledgesPhotoRisk = true; model.finish()
        try await idle(model)
        XCTAssertTrue(fixture.enabled)
        XCTAssertTrue(model.isComplete)
    }

    @MainActor
    func testSaveFailureKeepsPasswordStepAndCanBeRetried() async throws {
        let fixture = SetupFixture()
        fixture.permissions = true; fixture.model.continuePermissions()
        fixture.face = true; fixture.model.continueFace()
        fixture.saveFails = true
        fixture.model.savePassword(Data("fixture-only".utf8))
        try await idle(fixture.model)
        XCTAssertEqual(fixture.model.step, .password)
        XCTAssertFalse(fixture.passwordSaved)
        XCTAssertEqual(fixture.enables, 0)
        fixture.saveFails = false
        fixture.model.savePassword(Data("fixture-only".utf8))
        try await idle(fixture.model)
        XCTAssertEqual(fixture.model.step, .finish)
    }

    @MainActor
    func testFailedEnablementNeverClaimsSetupIsComplete() async throws {
        let fixture = SetupFixture()
        fixture.reachFinish(); fixture.model.acknowledgesPhotoRisk = true
        fixture.enableFails = true; fixture.model.finish()
        try await idle(fixture.model)
        XCTAssertFalse(fixture.model.isComplete)
        XCTAssertEqual(fixture.model.status, VaultError.authentication.localizedDescription)
        fixture.enableFails = false; fixture.model.finish()
        try await idle(fixture.model)
        XCTAssertTrue(fixture.model.isComplete)
    }

    @MainActor
    func testFinishRechecksRevokedPermissionsRemovedFaceAndDeletedPassword() async throws {
        for scenario in 0..<3 {
            let fixture = SetupFixture()
            fixture.reachFinish(); fixture.model.acknowledgesPhotoRisk = true
            if scenario == 0 { fixture.permissions = false }
            if scenario == 1 { fixture.face = false }
            if scenario == 2 { fixture.passwordSaved = false }
            fixture.model.finish()
            XCTAssertEqual(fixture.model.step, [.permissions, .face, .password][scenario])
            XCTAssertFalse(fixture.model.isComplete)
            XCTAssertEqual(fixture.enables, 0)
        }
    }

    @MainActor
    func testPendingAuthorizationDoesNotCompleteAndDuplicateFinishDoesNotEnableTwice() async throws {
        let fixture = SetupFixture()
        fixture.reachFinish(); fixture.model.acknowledgesPhotoRisk = true
        fixture.delayEnable = true; fixture.model.finish()
        for _ in 0..<1000 {
            if fixture.pendingEnable != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNotNil(fixture.pendingEnable)
        XCTAssertTrue(fixture.model.isBusy)
        XCTAssertFalse(fixture.model.isComplete)
        fixture.model.finish()
        XCTAssertEqual(fixture.enables, 1)
        fixture.pendingEnable?.resume()
        try await idle(fixture.model)
        XCTAssertTrue(fixture.model.isComplete)
        fixture.model.turnOff()
        XCTAssertFalse(fixture.enabled)
        XCTAssertFalse(fixture.model.isComplete)
    }

    @MainActor
    func testCanceledSetupRejectsLateAuthorization() async throws {
        let fixture = SetupFixture()
        fixture.reachFinish(); fixture.model.acknowledgesPhotoRisk = true
        fixture.delayEnable = true; fixture.model.finish()
        for _ in 0..<1000 {
            if fixture.pendingEnable != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNotNil(fixture.pendingEnable)
        fixture.model.cancel()
        fixture.pendingEnable?.resume()
        try await idle(fixture.model)
        XCTAssertFalse(fixture.enabled)
        XCTAssertFalse(fixture.model.isComplete)
    }
}
