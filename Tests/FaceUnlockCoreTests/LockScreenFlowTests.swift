import AppKit
import Foundation
import XCTest
@testable import FaceUnlockApp
import FaceUnlockCore
import FaceUnlockMac

@MainActor
private final class LockTemplateReader: FaceTestTemplateReading {
    var sessionIsValid = false
    var authorizations = 0
    var authenticationError: (any Error)?
    var authenticationAction: (() -> Void)?
    let template: EnrollmentTemplate
    init() throws {
        var values = [Float](repeating: 0, count: 512); values[0] = 1
        template = try EnrollmentTemplate(embeddings: Array(repeating:
            FaceEmbedding(raw: values, modelIdentifier: "lock-test"), count: 18), modelIdentifier: "lock-test")
    }
    func authorizeReading() async throws {
        authorizations += 1
        if let authenticationError { throw authenticationError }
        sessionIsValid = true
        authenticationAction?()
    }
    func templateForVerification() throws -> EnrollmentTemplate { template }
    func lock() { sessionIsValid = false }
}

@MainActor
private final class LockFixture {
    let vault: LockTemplateReader
    let notifications = NotificationCenter()
    var time = 100.0
    var lock = ScreenLockState.unlocked
    var consoleUID: UInt32 = 501
    var foreground = true
    var suspended = false
    var credentialsReady = true
    var identity = UnlockCheck.verified
    var liveness = UnlockCheck.verified
    var comparison = FaceComparisonOutcome.similar
    var available = true
    var preparations = 0
    var preparationError: (any Error)?
    var scan: ((UUID) async throws -> LockScreenScanResult)?
    var scanCount = 0
    var stopped = 0
    var revoked = 0
    var submissions = 0
    var inputFails = false
    var autoDesktop = false
    var credentialAuthorizations = 0
    var credentialAuthenticationError: (any Error)?
    var inputPermission = true
    var reports: [LockScreenDiagnosticReport] = []
    var finishCamera: (() async -> Void)?
    var finishCalls = 0
    var capture = LockScreenCaptureDiagnostics()
    var model: LockScreenFlowModel!

    init(submissionEnabled: Bool = false, supportsExperimentalUnlock: Bool = false) throws {
        vault = try LockTemplateReader()
        let services = LockScreenFlowServices(now: { [unowned self] in time }, uptime: { 100 },
            snapshot: { [unowned self] in snapshot() }, foreground: { [unowned self] in foreground },
            available: { [unowned self] in available },
            suspended: { [unowned self] in suspended }, prepare: { [unowned self] in
                preparations += 1
                if let preparationError { throw preparationError }
            }, scan: { [unowned self] _, id, check in
                try check(); scanCount += 1
                if let scan { return try await scan(id) }
                return outcome(id)
            }, stopCamera: { [unowned self] in stopped += 1 },
            credentialsReady: { [unowned self] in credentialsReady }, revokeCredentials: { [unowned self] in revoked += 1 },
            submit: { [unowned self] attempt, evidence in
                try attempt.consume(now: time, verification: evidence, snapshot: snapshot(), uptime: 100,
                                    credentialsReady: credentialsReady, focusVerified: true)
                submissions += 1
                if inputFails { throw FaceUnlockAttemptError.focus }
                if autoDesktop { lock = .unlocked }
            }, submissionEnabled: submissionEnabled, supportsExperimentalUnlock: supportsExperimentalUnlock,
            authorizeCredentials: { [unowned self] in
                credentialAuthorizations += 1
                if let credentialAuthenticationError { throw credentialAuthenticationError }
                credentialsReady = true
            }, inputPermissionGranted: { [unowned self] in inputPermission },
            finishCamera: { [unowned self] in finishCalls += 1; if let finishCamera { await finishCamera() } },
            captureDiagnostics: { [unowned self] in capture },
            saveDiagnostic: { [unowned self] in reports.append($0) })
        model = LockScreenFlowModel(vault: vault, services: services, userID: 501, notifications: notifications)
    }

    func snapshot() -> SessionSnapshot {
        SessionSnapshot(processUserID: 501, consoleUserID: consoleUID, sessionUserID: 501,
            isOnConsole: true, loginComplete: true, screenLock: lock, sampledAtUptime: 100)
    }

    func outcome(_ id: UUID, observedAt: Double? = nil) -> LockScreenScanResult {
        LockScreenScanResult(comparison: comparison, verification: UnlockVerification(attemptID: id,
            identity: identity, liveness: liveness, observedAt: observedAt ?? time))
    }
}

final class LockScreenFlowTests: XCTestCase {
    @MainActor
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Lock-screen flow did not reach expected state", file: file, line: line)
    }

    @MainActor
    private func arm(_ fixture: LockFixture) async throws {
        fixture.model.arm()
        try await waitUntil { fixture.model.phase == .waitingForLock }
    }

    @MainActor
    func testDefaultScanOnlyCannotSubmitEvenIfAProviderReportsVerified() async throws {
        let fixture = try LockFixture()
        try await arm(fixture)
        XCTAssertEqual(fixture.scanCount, 0, "The desktop arm does not start a camera scan")
        fixture.lock = .locked
        try await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.scanCount, 1)
        XCTAssertEqual(fixture.submissions, 0)
        XCTAssertEqual(fixture.model.phase, .fallback)
        XCTAssertTrue(fixture.model.status.contains("No password entered"))
        XCTAssertFalse(fixture.vault.sessionIsValid)
    }

    @MainActor
    func testUnknownLockDoesNotStartCameraAndArmExpires() async throws {
        let fixture = try LockFixture()
        fixture.lock = .unknown
        try await arm(fixture)
        fixture.time += 60
        fixture.model.watchdogTick()
        try await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.scanCount, 0)
        XCTAssertEqual(fixture.submissions, 0)
        XCTAssertEqual(fixture.model.phase, .fallback)
    }

    @MainActor
    func testUnavailableOrRejectedIdentityAndLivenessNeverSubmit() async throws {
        for scenario in 0..<4 {
            let fixture = try LockFixture(submissionEnabled: true)
            if scenario == 0 { fixture.identity = .unavailable }
            if scenario == 1 { fixture.identity = .rejected }
            if scenario == 2 { fixture.liveness = .unavailable }
            if scenario == 3 { fixture.liveness = .rejected }
            try await arm(fixture)
            fixture.lock = .locked
            try await waitUntil { !fixture.model.isBusy }
            XCTAssertEqual(fixture.submissions, 0)
            XCTAssertEqual(fixture.model.phase, .fallback)
        }
    }

    @MainActor
    func testVerifiedSubmissionAndObservedDesktopAreDistinct() async throws {
        let fixture = try LockFixture(submissionEnabled: true)
        try await arm(fixture)
        fixture.lock = .locked
        try await waitUntil { fixture.model.phase == .awaitingDesktop }
        XCTAssertEqual(fixture.submissions, 1)
        XCTAssertNotEqual(fixture.model.phase, .unlocked)
        fixture.model.arm(); fixture.model.arm()
        XCTAssertEqual(fixture.submissions, 1)
        fixture.lock = .unlocked
        try await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.model.phase, .unlocked)
        XCTAssertFalse(fixture.vault.sessionIsValid)
        XCTAssertGreaterThan(fixture.revoked, 0)
    }

    @MainActor
    func testNoDesktopConfirmationNeverRetriesPassword() async throws {
        let fixture = try LockFixture(submissionEnabled: true)
        try await arm(fixture)
        fixture.lock = .locked
        try await waitUntil { fixture.model.phase == .awaitingDesktop }
        fixture.time += 8
        try await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.model.phase, .fallback)
        XCTAssertEqual(fixture.submissions, 1)
        XCTAssertTrue(fixture.model.status.contains("no retry"))
    }

    @MainActor
    func testInputFailureConsumesAttemptAndNeverRetries() async throws {
        let fixture = try LockFixture(submissionEnabled: true)
        fixture.inputFails = true
        try await arm(fixture)
        fixture.lock = .locked
        try await waitUntil { !fixture.model.isBusy }
        fixture.model.watchdogTick()
        XCTAssertEqual(fixture.submissions, 1)
        XCTAssertEqual(fixture.scanCount, 1)
        XCTAssertEqual(fixture.model.phase, .fallback)
    }

    @MainActor
    func testCancelSleepAccountChangeManualUnlockLeaseLossAndTimeoutDiscardLateResult() async throws {
        for scenario in 0..<7 {
            let fixture = try LockFixture(submissionEnabled: true)
            var pending: CheckedContinuation<LockScreenScanResult, any Error>?
            var id: UUID?
            fixture.scan = { attemptID in
                id = attemptID
                return try await withCheckedThrowingContinuation { pending = $0 }
            }
            try await arm(fixture)
            fixture.lock = .locked
            try await waitUntil { pending != nil }
            switch scenario {
            case 0: fixture.model.cancel()
            case 1:
                fixture.notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
                try await waitUntil { fixture.model.phase == .canceled }
            case 2: fixture.consoleUID = 502
            case 3: fixture.lock = .unlocked
            case 4: fixture.vault.sessionIsValid = false
            case 5: fixture.time += 15
            default: fixture.credentialsReady = false
            }
            fixture.model.watchdogTick()
            fixture.model.arm() // A late inference cannot overlap a new attempt.
            pending?.resume(returning: fixture.outcome(try XCTUnwrap(id)))
            try await waitUntil { !fixture.model.isBusy }
            XCTAssertEqual(fixture.submissions, 0, "scenario \(scenario)")
            XCTAssertNotEqual(fixture.model.phase, .unlocked)
            XCTAssertEqual(fixture.vault.authorizations, 1)
            XCTAssertGreaterThan(fixture.stopped, 0)
        }
    }

    @MainActor
    func testForeignAndStaleEvidenceCannotReachPasswordDelivery() async throws {
        for foreign in [false, true] {
            let fixture = try LockFixture(submissionEnabled: true)
            fixture.scan = { id in fixture.outcome(foreign ? UUID() : id, observedAt: fixture.time - 1) }
            try await arm(fixture)
            fixture.lock = .locked
            try await waitUntil { !fixture.model.isBusy }
            XCTAssertEqual(fixture.submissions, 0)
            XCTAssertEqual(fixture.model.phase, .fallback)
        }
    }

    @MainActor
    func testCanceledAuthenticationAndFailedPreparationNeverStartScan() async throws {
        for scenario in 0..<2 {
            let fixture = try LockFixture()
            if scenario == 0 { fixture.vault.authenticationError = CancellationError() }
            else { fixture.preparationError = EnrollmentError.incompatible }
            fixture.model.arm()
            try await waitUntil { !fixture.model.isBusy }
            XCTAssertEqual(fixture.scanCount, 0)
            XCTAssertEqual(fixture.submissions, 0)
        }
    }

    @MainActor
    func testArmingRequiresForegroundDesktopAndCurrentAccount() throws {
        for scenario in 0..<4 {
            let fixture = try LockFixture()
            if scenario == 0 { fixture.foreground = false }
            if scenario == 1 { fixture.consoleUID = 502 }
            if scenario == 2 { fixture.lock = .locked }
            if scenario == 3 { fixture.suspended = true }
            fixture.model.arm()
            XCTAssertFalse(fixture.model.isBusy)
            XCTAssertEqual(fixture.vault.authorizations, 0)
        }
    }

    @MainActor
    func testEnablementWaitsForForegroundToReturnAfterSystemAuthentication() async throws {
        let fixture = try LockFixture()
        defer { fixture.model.disableAutomaticScanning() }
        fixture.vault.authenticationAction = { fixture.foreground = false }
        fixture.model.enableAutomaticScanning()
        try await waitUntil { fixture.vault.authorizations == 1 && !fixture.foreground }
        XCTAssertFalse(fixture.model.automaticScanningEnabled)
        fixture.foreground = true
        try await waitUntil { fixture.model.automaticScanningEnabled && !fixture.model.isBusy }
        XCTAssertEqual(fixture.scanCount, 0)
    }

    @MainActor
    func testEveryNewLockScansWithoutReauthenticationOrManualArming() async throws {
        let fixture = try LockFixture()
        defer { fixture.model.disableAutomaticScanning() }
        fixture.model.enableAutomaticScanning()
        try await waitUntil { fixture.model.automaticScanningEnabled && !fixture.model.isBusy }
        XCTAssertFalse(fixture.vault.sessionIsValid, "The read-vault key is dropped after loading the in-memory template")
        fixture.time += 3600
        fixture.foreground = false
        for expectedCount in 1...3 {
            fixture.lock = .locked
            fixture.model.automaticTick()
            try await waitUntil { fixture.scanCount == expectedCount && !fixture.model.isBusy }
            for _ in 0..<20 { fixture.model.automaticTick() }
            XCTAssertEqual(fixture.scanCount, expectedCount, "No repeat scan within the same lock")
            fixture.lock = .unlocked
            fixture.model.automaticTick()
        }
        XCTAssertEqual(fixture.vault.authorizations, 1)
        XCTAssertEqual(fixture.preparations, 1)
        XCTAssertEqual(fixture.submissions, 0)
    }

    @MainActor
    func testUnknownLockAndDuplicateLockSignalsCannotRearmSameCycle() async throws {
        let fixture = try LockFixture()
        defer { fixture.model.disableAutomaticScanning() }
        fixture.model.enableAutomaticScanning()
        try await waitUntil { fixture.model.automaticScanningEnabled && !fixture.model.isBusy }
        fixture.lock = .unknown
        fixture.model.automaticTick()
        XCTAssertEqual(fixture.scanCount, 0)
        fixture.lock = .locked
        fixture.model.automaticTick()
        try await waitUntil { fixture.scanCount == 1 && !fixture.model.isBusy }
        fixture.lock = .unknown
        fixture.model.automaticTick()
        fixture.lock = .locked
        for _ in 0..<10 {
            fixture.notifications.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(fixture.scanCount, 1)
        // macOS can omit its desktop lock flag; a checked unlock signal resets the cycle.
        fixture.lock = .unknown
        fixture.notifications.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        for _ in 0..<100 { await Task.yield() }
        fixture.lock = .locked
        fixture.model.automaticTick()
        try await waitUntil { fixture.scanCount == 2 && !fixture.model.isBusy }
    }

    @MainActor
    func testActualSleepWakeAllowsOneFreshScanButDuplicateWakeDoesNot() async throws {
        let fixture = try LockFixture()
        defer { fixture.model.disableAutomaticScanning() }
        fixture.model.enableAutomaticScanning()
        try await waitUntil { fixture.model.automaticScanningEnabled && !fixture.model.isBusy }
        fixture.lock = .locked
        fixture.model.automaticTick()
        try await waitUntil { fixture.scanCount == 1 && !fixture.model.isBusy }
        fixture.notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        for _ in 0..<100 { await Task.yield() }
        fixture.time += 1000
        fixture.notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await waitUntil { fixture.scanCount == 2 && !fixture.model.isBusy }
        for _ in 0..<10 { fixture.notifications.post(name: NSWorkspace.didWakeNotification, object: nil) }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(fixture.scanCount, 2)
        XCTAssertEqual(fixture.vault.authorizations, 1)
    }

    @MainActor
    func testDisableRejectsLateAutomaticResultAndDoesNotStartOnNextLock() async throws {
        let fixture = try LockFixture()
        var pending: CheckedContinuation<LockScreenScanResult, any Error>?
        var attemptID: UUID?
        fixture.scan = { id in
            attemptID = id
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        fixture.model.enableAutomaticScanning()
        try await waitUntil { fixture.model.automaticScanningEnabled && !fixture.model.isBusy }
        fixture.lock = .locked
        fixture.model.automaticTick()
        try await waitUntil { pending != nil }
        fixture.model.disableAutomaticScanning()
        pending?.resume(returning: fixture.outcome(try XCTUnwrap(attemptID)))
        try await waitUntil { !fixture.model.isBusy }
        fixture.lock = .unlocked; fixture.model.automaticTick()
        fixture.lock = .locked; fixture.model.automaticTick()
        XCTAssertFalse(fixture.model.automaticScanningEnabled)
        XCTAssertEqual(fixture.scanCount, 1)
        XCTAssertEqual(fixture.submissions, 0)
        XCTAssertNotEqual(fixture.model.phase, .unlocked)
    }

    @MainActor
    func testAccountAndEnrollmentChangesClearAutomaticAuthorization() async throws {
        for scenario in 0..<3 {
            let fixture = try LockFixture()
            defer { fixture.model.disableAutomaticScanning() }
            fixture.model.enableAutomaticScanning()
            try await waitUntil { fixture.model.automaticScanningEnabled && !fixture.model.isBusy }
            switch scenario {
            case 0: fixture.consoleUID = 502; fixture.model.automaticTick()
            case 1: fixture.notifications.post(name: EnrollmentVault.didChangeNotification, object: nil)
            default: fixture.notifications.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            }
            try await waitUntil { !fixture.model.automaticScanningEnabled }
            fixture.consoleUID = 501; fixture.lock = .locked
            fixture.model.automaticTick()
            XCTAssertEqual(fixture.scanCount, 0)
        }
    }

    @MainActor
    func testAutomaticEnablementFailureAndConflictingWorkNeverTurnCameraOn() async throws {
        for scenario in 0..<4 {
            let fixture = try LockFixture()
            defer { fixture.model.disableAutomaticScanning() }
            if scenario == 0 { fixture.vault.authenticationError = CancellationError() }
            if scenario == 1 { fixture.preparationError = EnrollmentError.incompatible }
            if scenario == 2 { fixture.foreground = false }
            if scenario == 3 { fixture.available = false }
            fixture.model.enableAutomaticScanning()
            try await waitUntil { !fixture.model.isBusy }
            XCTAssertFalse(fixture.model.automaticScanningEnabled)
            XCTAssertFalse(fixture.vault.sessionIsValid)
            XCTAssertEqual(fixture.scanCount, 0)
        }
    }

    @MainActor
    private func enableExperimental(_ fixture: LockFixture) async throws {
        fixture.identity = .experimentalMatch; fixture.liveness = .unavailable
        fixture.model.enableExperimentalUnlock(acknowledgingPhotoRisk: true)
        try await waitUntil { fixture.model.automaticUnlockEnabled && !fixture.model.isBusy }
    }

    @MainActor
    func testFinishingSetupUpgradesScanOnlyAndActuallySubmitsAfterMatch() async throws {
        let fixture = try LockFixture(supportsExperimentalUnlock: true)
        defer { fixture.model.disableAutomaticScanning() }
        fixture.model.enableAutomaticScanning()
        try await waitUntil { fixture.model.automaticScanningEnabled && !fixture.model.isBusy }
        XCTAssertFalse(fixture.model.automaticUnlockEnabled)
        fixture.identity = .experimentalMatch; fixture.liveness = .unavailable
        try await fixture.model.enableForSetup(acknowledgingPhotoRisk: true)
        XCTAssertTrue(fixture.model.automaticUnlockEnabled)
        XCTAssertEqual(fixture.credentialAuthorizations, 1)
        fixture.autoDesktop = true
        fixture.lock = .locked; fixture.model.automaticTick()
        try await waitUntil { fixture.submissions == 1 && !fixture.model.isBusy }
        XCTAssertEqual(fixture.model.phase, .unlocked)
        XCTAssertEqual(fixture.reports.last?.mode, "experimental-unlock")
    }

    @MainActor
    func testSetupEnablementPropagatesMissingCredentialsInsteadOfClaimingCompletion() async throws {
        let fixture = try LockFixture(supportsExperimentalUnlock: true)
        fixture.credentialAuthenticationError = VaultError.missingPassword
        do {
            try await fixture.model.enableForSetup(acknowledgingPhotoRisk: true)
            XCTFail("Missing password must fail setup")
        } catch {
            XCTAssertEqual(error.localizedDescription, VaultError.missingPassword.localizedDescription)
        }
        XCTAssertFalse(fixture.model.automaticUnlockEnabled)
        XCTAssertFalse(fixture.model.automaticScanningEnabled)
        XCTAssertEqual(fixture.scanCount, 0)
    }

    @MainActor
    func testExperimentalModeRequiresConsentPermissionAndCredentialAuthorization() async throws {
        for scenario in 0..<4 {
            let fixture = try LockFixture(supportsExperimentalUnlock: scenario != 3)
            defer { fixture.model.disableAutomaticScanning() }
            if scenario == 1 { fixture.inputPermission = false }
            if scenario == 2 { fixture.credentialAuthenticationError = CancellationError() }
            fixture.model.enableExperimentalUnlock(acknowledgingPhotoRisk: scenario != 0)
            try await waitUntil { !fixture.model.isBusy }
            XCTAssertFalse(fixture.model.automaticUnlockEnabled)
            XCTAssertFalse(fixture.model.automaticScanningEnabled)
            XCTAssertEqual(fixture.submissions, 0)
            XCTAssertEqual(fixture.credentialAuthorizations, scenario == 2 ? 1 : 0)
        }
    }

    @MainActor
    func testExperimentalMatchCanSubmitOncePerLockWithLivenessStillUnavailable() async throws {
        let fixture = try LockFixture(supportsExperimentalUnlock: true)
        defer { fixture.model.disableAutomaticScanning() }
        try await enableExperimental(fixture)
        for expected in 1...3 {
            fixture.time += 1000
            fixture.lock = .locked
            fixture.model.automaticTick()
            try await waitUntil { fixture.model.phase == .awaitingDesktop }
            XCTAssertEqual(fixture.submissions, expected)
            for _ in 0..<10 { fixture.model.automaticTick() }
            XCTAssertEqual(fixture.submissions, expected)
            fixture.lock = .unlocked
            fixture.model.automaticTick() // Must not cancel a legitimate desktop confirmation.
            try await waitUntil { !fixture.model.isBusy }
            XCTAssertEqual(fixture.model.phase, .unlocked)
            XCTAssertTrue(fixture.model.automaticUnlockEnabled)
        }
        XCTAssertEqual(fixture.credentialAuthorizations, 1)
        XCTAssertEqual(fixture.vault.authorizations, 1)
        XCTAssertEqual(fixture.liveness, .unavailable)
    }

    @MainActor
    func testUnknownDesktopLockFlagNeedsAnUnlockSignalAfterSubmission() async throws {
        let fixture = try LockFixture(supportsExperimentalUnlock: true)
        defer { fixture.model.disableAutomaticScanning() }
        try await enableExperimental(fixture)
        fixture.lock = .locked; fixture.model.automaticTick()
        try await waitUntil { fixture.model.phase == .awaitingDesktop }
        fixture.lock = .unknown
        fixture.model.automaticTick()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(fixture.model.phase, .awaitingDesktop)
        fixture.notifications.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        try await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.model.phase, .unlocked)
        XCTAssertEqual(fixture.submissions, 1)
    }

    @MainActor
    func testUnconfirmedOrFailedExperimentalInputDisablesFurtherAutomaticSubmissions() async throws {
        for failsDuringInput in [false, true] {
            let fixture = try LockFixture(supportsExperimentalUnlock: true)
            defer { fixture.model.disableAutomaticScanning() }
            fixture.inputFails = failsDuringInput
            try await enableExperimental(fixture)
            fixture.lock = .locked; fixture.model.automaticTick()
            if !failsDuringInput {
                try await waitUntil { fixture.model.phase == .awaitingDesktop }
                fixture.time += 8
            }
            try await waitUntil { !fixture.model.isBusy }
            XCTAssertFalse(fixture.model.automaticUnlockEnabled)
            XCTAssertFalse(fixture.model.automaticScanningEnabled)
            XCTAssertEqual(fixture.submissions, 1)
            fixture.lock = .unlocked; fixture.model.automaticTick()
            fixture.lock = .locked; fixture.model.automaticTick()
            XCTAssertEqual(fixture.submissions, 1)
        }
    }

    @MainActor
    func testExperimentalModeRejectsNonMatchPADDenialAndStaleEvidence() async throws {
        for scenario in 0..<4 {
            let fixture = try LockFixture(supportsExperimentalUnlock: true)
            defer { fixture.model.disableAutomaticScanning() }
            try await enableExperimental(fixture)
            if scenario == 0 { fixture.identity = .rejected }
            if scenario == 1 { fixture.liveness = .rejected }
            if scenario == 2 { fixture.identity = .unavailable }
            if scenario == 3 { fixture.scan = { id in fixture.outcome(id, observedAt: fixture.time - 1) } }
            fixture.lock = .locked; fixture.model.automaticTick()
            try await waitUntil { !fixture.model.isBusy }
            XCTAssertEqual(fixture.submissions, 0)
            XCTAssertNotEqual(fixture.model.phase, .unlocked)
        }
    }

    @MainActor
    func testPasswordChangeAndDisableRevokeExperimentalSession() async throws {
        for passwordChanged in [false, true] {
            let fixture = try LockFixture(supportsExperimentalUnlock: true)
            defer { fixture.model.disableAutomaticScanning() }
            try await enableExperimental(fixture)
            if passwordChanged { fixture.notifications.post(name: CredentialVault.didChangeNotification, object: nil) }
            else { fixture.model.disableAutomaticScanning() }
            try await waitUntil { !fixture.model.automaticUnlockEnabled }
            XCTAssertGreaterThan(fixture.revoked, 0)
            fixture.lock = .locked; fixture.model.automaticTick()
            XCTAssertEqual(fixture.submissions, 0)
        }
    }

    @MainActor
    func testSleepOrManualUnlockBeforeSubmissionPreservesOptInForNextScan() async throws {
        for sleep in [false, true] {
            let fixture = try LockFixture(supportsExperimentalUnlock: true)
            defer { fixture.model.disableAutomaticScanning() }
            var pending: CheckedContinuation<LockScreenScanResult, any Error>?
            var firstID: UUID?
            fixture.scan = { id in
                if fixture.scanCount == 1 {
                    firstID = id
                    return try await withCheckedThrowingContinuation { pending = $0 }
                }
                return fixture.outcome(id)
            }
            try await enableExperimental(fixture)
            fixture.lock = .locked; fixture.model.automaticTick()
            try await waitUntil { pending != nil }
            if sleep { fixture.notifications.post(name: NSWorkspace.willSleepNotification, object: nil) }
            else { fixture.lock = .unlocked; fixture.model.automaticTick() }
            try await waitUntil { fixture.model.phase == .canceled }
            pending?.resume(returning: fixture.outcome(try XCTUnwrap(firstID)))
            try await waitUntil { !fixture.model.isBusy }
            XCTAssertTrue(fixture.model.automaticUnlockEnabled)
            XCTAssertEqual(fixture.submissions, 0)
            fixture.autoDesktop = true
            fixture.lock = .locked
            if sleep { fixture.notifications.post(name: NSWorkspace.didWakeNotification, object: nil) }
            else { fixture.model.automaticTick() }
            try await waitUntil { fixture.submissions == 1 && !fixture.model.isBusy }
            XCTAssertEqual(fixture.model.phase, .unlocked)
            XCTAssertEqual(fixture.credentialAuthorizations, 1)
            XCTAssertEqual(fixture.revoked, 0)
        }
    }

    @MainActor
    func testInputPrecedesCameraJoinAndNewAttemptWaitsForCleanup() async throws {
        let fixture = try LockFixture(submissionEnabled: true)
        fixture.autoDesktop = true
        var pending: CheckedContinuation<Void, Never>?
        fixture.finishCamera = { await withCheckedContinuation { pending = $0 } }
        try await arm(fixture)
        fixture.lock = .locked
        try await waitUntil { pending != nil }
        XCTAssertEqual(fixture.submissions, 1)
        XCTAssertTrue(fixture.model.isBusy)
        fixture.model.arm()
        XCTAssertEqual(fixture.vault.authorizations, 1)
        pending?.resume()
        try await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.finishCalls, 1)
        XCTAssertEqual(fixture.model.phase, .unlocked)
    }

    @MainActor
    func testFailureReportRetainsActualModeStageAndInputStateAfterRevocation() async throws {
        let fixture = try LockFixture(supportsExperimentalUnlock: true)
        defer { fixture.model.disableAutomaticScanning() }
        fixture.inputFails = true
        try await enableExperimental(fixture)
        fixture.lock = .locked; fixture.model.automaticTick()
        try await waitUntil { !fixture.model.isBusy }
        let report = try XCTUnwrap(fixture.reports.last)
        XCTAssertEqual(report.mode, "experimental-unlock")
        XCTAssertEqual(report.stage, .submitting)
        XCTAssertEqual(report.outcome, .fallback)
        XCTAssertEqual(report.failure, .focus)
        XCTAssertTrue(report.inputConsumed)
        XCTAssertFalse(report.passwordSubmitted)
        XCTAssertFalse(fixture.model.automaticUnlockEnabled)
        XCTAssertEqual(fixture.model.failure, .focus)
    }

    @MainActor
    func testFailedReenablementDoesNotReportInputOrFramesFromPreviousAttempt() async throws {
        let fixture = try LockFixture(supportsExperimentalUnlock: true)
        defer { fixture.model.disableAutomaticScanning() }
        fixture.autoDesktop = true; fixture.capture.analyzedFrames = 12
        try await enableExperimental(fixture)
        fixture.lock = .locked; fixture.model.automaticTick()
        try await waitUntil { fixture.submissions == 1 && !fixture.model.isBusy }
        fixture.model.disableAutomaticScanning()
        fixture.vault.authenticationError = CancellationError()
        fixture.model.enableExperimentalUnlock(acknowledgingPhotoRisk: true)
        try await waitUntil { !fixture.model.isBusy }
        let report = try XCTUnwrap(fixture.reports.last)
        XCTAssertEqual(report.stage, .preparing)
        XCTAssertFalse(report.inputConsumed)
        XCTAssertFalse(report.passwordSubmitted)
        XCTAssertEqual(report.capture.analyzedFrames, 0)
        XCTAssertNil(report.evidenceAgeMilliseconds)
    }

    func testIndicatorWidthMatchesActualNotchGapOnOffsetDisplay() {
        let screen = CGRect(x: -1728, y: 240, width: 1728, height: 1117)
        let left = CGRect(x: -1728, y: 1325, width: 766, height: 32)
        let right = CGRect(x: -766, y: 1325, width: 766, height: 32)
        let frame = LockScreenIndicatorGeometry.frame(screen: screen, safeTop: 32, leftArea: left, rightArea: right)
        XCTAssertEqual(frame.width, 196)
        XCTAssertEqual(frame.minX, left.maxX)
        XCTAssertEqual(frame.maxX, right.minX)
        XCTAssertEqual(frame.height, 186.2, accuracy: 0.001, "Notch-width drop-down follows the supplied reference")
        XCTAssertEqual(frame.maxY, screen.maxY)
    }

    func testIndicatorGeometryUsesScreenOriginAndExtendsBelowHardwareNotch() {
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1920, y: 300, width: 1920, height: 1080)] {
            for top in [CGFloat(0), 32] {
                let frame = LockScreenIndicatorGeometry.frame(screen: screen, safeTop: top)
                XCTAssertEqual(frame.midX, screen.midX)
                XCTAssertEqual(frame.maxY, screen.maxY)
                XCTAssertEqual(frame.height, 171)
                XCTAssertTrue(screen.contains(frame))
            }
        }
    }
}
