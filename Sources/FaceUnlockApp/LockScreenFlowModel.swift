import AppKit
import Combine
import Darwin
import Foundation
import FaceUnlockCore
import FaceUnlockMac

enum LockScreenPhase: String, Equatable, Codable, Sendable {
    case idle, preparing, waitingForLock, scanning, waitingForPasswordField, submitting, awaitingDesktop, unlocked, fallback, canceled
}

@MainActor
struct LockScreenFlowServices {
    var now: () -> Double = { ContinuousTime.now }
    var uptime: () -> Double = { ProcessInfo.processInfo.systemUptime }
    var snapshot: () -> SessionSnapshot = { MacSessionReader().read() }
    var foreground: () -> Bool = { NSApp?.isActive == true }
    var available: () -> Bool = { true }
    var suspended: () -> Bool
    var prepare: () async throws -> Void
    var scan: (EnrollmentTemplate, UUID, @escaping @MainActor () throws -> Void, @escaping @MainActor () throws -> Bool) async throws -> LockScreenScanResult
    var stopCamera: () -> Void
    var credentialsReady: () -> Bool
    var revokeCredentials: () -> Void
    var submit: (inout FaceUnlockAttempt, UnlockVerification) throws -> Void
    // Default-off composition gate. It is not a user-tunable biometric cutoff.
    var submissionEnabled = false
    var supportsExperimentalUnlock = false
    var authorizeCredentials: () async throws -> Void = {}
    var inputPermissionGranted: () -> Bool = { true }
    var prepareInput: () throws -> Void = {}
    var revealInput: () throws -> Void = {}
    var finishCamera: () async -> Void = {}
    var indicatorDiagnostics: () -> LockScreenIndicatorDiagnostics? = { nil }
    var captureDiagnostics: () -> LockScreenCaptureDiagnostics = { LockScreenCaptureDiagnostics() }
    var inputDiagnostic: () -> InputTargetDiagnostic? = { nil }
    var saveDiagnostic: (LockScreenDiagnosticReport) -> Void = { _ in }
}

@MainActor
final class LockScreenFlowModel: ObservableObject {
    @Published private(set) var phase: LockScreenPhase = .idle
    @Published private(set) var status = "Finish setup to unlock with your face on every lock."
    @Published private(set) var isBusy = false
    @Published private(set) var automaticScanningEnabled = false
    @Published private(set) var automaticUnlockEnabled = false
    @Published private(set) var events: [String] = []
    @Published private(set) var failure: LockScreenFailure?
    let submissionEnabled: Bool
    private let vault: any FaceTestTemplateReading
    private let services: LockScreenFlowServices
    private let userID: UInt32
    private var operation: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var attempt: FaceUnlockAttempt?
    private var submittedAt: Double?
    private var automaticTemplate: EnrollmentTemplate?
    private var automaticPolling: Task<Void, Never>?
    private var automaticLockHandled = false
    private var automaticSleeping = false
    private var isAutomaticAttempt = false
    private var desktopReturnObserved = false
    private var inputConsumed = false
    private var activeMode = "off"
    private var evidenceAgeMilliseconds: Double?
    private var shouldSubmit: Bool { isAutomaticAttempt ? automaticUnlockEnabled : submissionEnabled }
    private var observers: [LockFlowNotificationToken] = []

    init(vault: any FaceTestTemplateReading, services: LockScreenFlowServices,
         userID: UInt32 = getuid(), notifications: NotificationCenter? = nil) {
        self.vault = vault; self.services = services; self.userID = userID
        submissionEnabled = services.submissionEnabled
        let center = notifications ?? NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willPowerOffNotification] {
            observe(center, name)
        }
        let distributed = notifications ?? DistributedNotificationCenter.default()
        observe(distributed, NSNotification.Name("com.apple.screenIsLocked"))
        observe(distributed, NSNotification.Name("com.apple.screenIsUnlocked"))
        observe(notifications ?? NotificationCenter.default, EnrollmentVault.didChangeNotification)
        observe(notifications ?? NotificationCenter.default, CredentialVault.didChangeNotification)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleEvent(name) }
        }
        observers.append(LockFlowNotificationToken(center: center, token: token))
    }

    private func handleEvent(_ name: Notification.Name) {
        switch name {
        case NSWorkspace.willSleepNotification:
            automaticSleeping = true
            cancel(reason: "The Mac slept. The current scan stopped.")
        case NSWorkspace.didWakeNotification:
            if automaticSleeping { automaticLockHandled = false }
            automaticSleeping = false
            automaticTick()
        case NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willPowerOffNotification:
            disableAutomaticScanning(reason: "The Mac session changed. Enable scanning again from your desktop.")
            cancel(reason: "The Mac session changed. Test canceled.")
        case EnrollmentVault.didChangeNotification:
            disableAutomaticScanning(reason: "Your saved face changed. Enable scanning again to use it.")
        case CredentialVault.didChangeNotification:
            if automaticUnlockEnabled || isBusy {
                disableAutomaticScanning(reason: "Your saved password changed. Enable face unlock again to authorize it.")
            }
        case NSNotification.Name("com.apple.screenIsUnlocked"):
            let observed = services.snapshot()
            let assessment = observed.assessment(at: services.uptime(), maximumAge: 0.5)
            if observed.processUserID == userID, !services.suspended(),
               assessment == .unlocked || assessment == .lockUnknown {
                automaticLockHandled = false
                if phase == .awaitingDesktop, submittedAt != nil { desktopReturnObserved = true }
                else if isAutomaticAttempt { cancel(reason: "The Mac was unlocked. Camera stopped.") }
            }
        default: automaticTick()
        }
    }

    func enableAutomaticScanning() { enableAutomaticMode(experimentalUnlock: false) }

    func enableExperimentalUnlock(acknowledgingPhotoRisk: Bool) {
        guard acknowledgingPhotoRisk else {
            finish(.fallback, VaultError.experimentalConsent.localizedDescription); return
        }
        guard services.supportsExperimentalUnlock else { return }
        enableAutomaticMode(experimentalUnlock: true)
    }

    func enableForSetup(acknowledgingPhotoRisk: Bool) async throws {
        guard !isBusy else { throw LockScreenSetupError(message: "Wait for the current scan to finish.") }
        if automaticUnlockEnabled { return }
        enableExperimentalUnlock(acknowledgingPhotoRisk: acknowledgingPhotoRisk)
        await operation?.value
        try Task.checkCancellation()
        guard automaticUnlockEnabled else { throw LockScreenSetupError(message: status) }
    }

    private func enableAutomaticMode(experimentalUnlock: Bool) {
        guard !isBusy, !submissionEnabled else { return }
        if automaticScanningEnabled {
            // A diagnostic scan-only session must not silently block finishing real setup.
            guard experimentalUnlock, !automaticUnlockEnabled else { return }
            clearAutomaticSession()
        }
        activeMode = experimentalUnlock ? "experimental-unlock" : "scan-only"
        inputConsumed = false; submittedAt = nil; evidenceAgeMilliseconds = nil
        guard !experimentalUnlock || services.inputPermissionGranted() else {
            finish(.fallback, "Enable this app in System Settings → Privacy & Security → Accessibility before enabling face unlock."); return
        }
        let observed = services.snapshot()
        let assessment = observed.assessment(at: services.uptime(), maximumAge: 0.5)
        guard services.foreground(), services.available(), !services.suspended(), observed.processUserID == userID,
              assessment == .unlocked || assessment == .lockUnknown else {
            finish(.fallback, "Enable automatic scanning from this account's desktop after other tests finish."); return
        }
        failure = nil
        vault.lock(); isBusy = true; phase = .preparing
        record("Authenticate once to scan on every lock while Face Unlock is open.")
        operation = Task { [self] in
            defer { vault.lock(); operation = nil; isBusy = false }
            do {
                try await vault.authorizeReading()
                try Task.checkCancellation(); try await waitForDesktop()
                let template = try vault.templateForVerification()
                try await services.prepare()
                try Task.checkCancellation(); try await waitForDesktop()
                if experimentalUnlock {
                    record("Authorize access to the saved Mac password for experimental face unlock.")
                    try await services.authorizeCredentials()
                    try Task.checkCancellation(); try await waitForDesktop()
                    guard services.credentialsReady() else { throw FaceUnlockAttemptError.credentials }
                }
                automaticTemplate = template
                automaticUnlockEnabled = experimentalUnlock
                automaticScanningEnabled = true
                automaticLockHandled = false; automaticSleeping = false
                finish(.idle, experimentalUnlock
                    ? "Experimental face unlock is on. Each lock can submit your saved password once after a match. Photos/video may also unlock."
                    : "Every lock scanning is on. Lock your Mac normally; no manual arming is needed.")
                automaticPolling = Task { [weak self] in
                    while !Task.isCancelled {
                        guard self != nil else { return }
                        self?.automaticTick()
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    }
                }
            } catch {
                automaticTemplate = nil; automaticUnlockEnabled = false
                services.revokeCredentials()
                if phase != .canceled { finish(.fallback, error.localizedDescription, failure: .classify(error)) }
            }
        }
    }

    func disableAutomaticScanning(reason: String = "Every lock scanning is off.") {
        clearAutomaticSession()
        cancel(reason: reason)
        if !isBusy { finish(.idle, reason) }
    }

    private func clearAutomaticSession() {
        automaticPolling?.cancel(); automaticPolling = nil
        automaticScanningEnabled = false; automaticUnlockEnabled = false
        automaticTemplate = nil; automaticLockHandled = false
        services.revokeCredentials()
    }

    func automaticTick() {
        guard automaticScanningEnabled, automaticTemplate != nil else { return }
        let observed = services.snapshot()
        let assessment = observed.assessment(at: services.uptime(), maximumAge: 0.5)
        guard observed.processUserID == userID else {
            disableAutomaticScanning(reason: "Account changed. Automatic scanning is off."); return
        }
        switch assessment {
        case .wrongAccount, .inactive, .loginIncomplete:
            disableAutomaticScanning(reason: "Account changed. Automatic scanning is off."); return
        case .unlocked:
            automaticLockHandled = false
            if isAutomaticAttempt, phase != .awaitingDesktop { cancel(reason: "The Mac was unlocked. Camera stopped.") }
            return
        case .observedLocked: break
        default: return // Missing observations cannot start a scan or reset the lock-cycle latch.
        }
        guard !automaticSleeping, !services.suspended(), !isBusy, !automaticLockHandled,
              services.available(), let template = automaticTemplate else { return }
        automaticLockHandled = true
        launch(automaticTemplate: template)
    }

    func arm() {
        guard !isBusy else { return }
        guard !automaticScanningEnabled else {
            record("Every lock scanning is on. Lock normally, or turn it off before a one-time test."); return
        }
        guard services.available() else {
            finish(.fallback, "Finish the other face or credential test before arming a lock-screen scan."); return
        }
        let snapshot = services.snapshot()
        let assessment = snapshot.assessment(at: services.uptime(), maximumAge: 0.5)
        guard services.foreground(), services.available(), !services.suspended(), snapshot.processUserID == userID,
              assessment == .unlocked || assessment == .lockUnknown else {
            finish(.fallback, "Start the lock-screen test from this account's desktop."); return
        }
        events.removeAll()
        launch()
    }

    private func launch(automaticTemplate preparedTemplate: EnrollmentTemplate? = nil) {
        activeMode = preparedTemplate != nil && automaticUnlockEnabled ? "experimental-unlock" : submissionEnabled ? "verified-test" : "scan-only"
        failure = nil; evidenceAgeMilliseconds = nil
        vault.lock(); submittedAt = nil; desktopReturnObserved = false; inputConsumed = false
        isAutomaticAttempt = preparedTemplate != nil
        isBusy = true; phase = .preparing
        if !isAutomaticAttempt { record("Use Touch ID or your Mac password to open your saved face for this test.") }
        operation = Task { [self] in
            defer {
                watchdog?.cancel(); watchdog = nil
                services.stopCamera(); vault.lock()
                if !automaticUnlockEnabled { services.revokeCredentials() }
                attempt = nil; operation = nil; isAutomaticAttempt = false; isBusy = false
            }
            await executeAttempt(preparedTemplate: preparedTemplate)
            await services.finishCamera()
        }
    }

    private func executeAttempt(preparedTemplate: EnrollmentTemplate?) async {
        do {
            let template: EnrollmentTemplate
            if let preparedTemplate {
                guard automaticScanningEnabled else { throw CancellationError() }
                template = preparedTemplate
            } else {
                try await vault.authorizeReading()
                try Task.checkCancellation(); try await waitForDesktop()
                template = try vault.templateForVerification()
                try await services.prepare()
                try Task.checkCancellation(); try await waitForDesktop()
            }
            if shouldSubmit && !services.credentialsReady() { throw FaceUnlockAttemptError.credentials }
            attempt = FaceUnlockAttempt(userID: userID, now: services.now(),
                policy: automaticUnlockEnabled ? .experimentalSimilarity : .verifiedBiometrics)
            if !isAutomaticAttempt {
                phase = .waitingForLock
                record("Ready for one lock-screen scan. Lock your Mac normally within 60 seconds.")
                startWatchdog()
                while phase == .waitingForLock {
                    try Task.checkCancellation(); try checkWaiting()
                    if services.snapshot().assessment(at: services.uptime(), maximumAge: 0.5) == .observedLocked { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } else { startWatchdog() }
            try Task.checkCancellation()
            guard var current = attempt else { throw FaceUnlockAttemptError.expired }
            try current.beginScan(now: services.now(), snapshot: services.snapshot(), uptime: services.uptime())
            attempt = current
            phase = .scanning; record("Looking for your face…")
            var promptRevealAttempted = false
            let result = try await services.scan(template, current.id, { [weak self] in
                guard let self else { throw CancellationError() }
                try self.checkScanning()
            }, { [weak self] in
                guard let self else { throw CancellationError() }
                try self.checkScanning()
                guard self.shouldSubmit else { return true }
                do {
                    try self.services.prepareInput()
                    return true
                } catch let error as InputError where error == .target || error == .field {
                    if self.phase != .waitingForPasswordField {
                        self.phase = .waitingForPasswordField
                        self.record("Face matched. Waiting for the Mac password field; keeping the camera active for a fresh match.")
                    }
                    if !promptRevealAttempted {
                        do {
                            try self.services.revealInput()
                            promptRevealAttempted = true
                        } catch let revealError as InputError where revealError == .target || revealError == .field {
                            // loginwindow may still be transitioning; keep analyzing fresh frames.
                        }
                    }
                    return false
                }
            })
            let age = (services.now() - result.verification.observedAt) * 1000
            evidenceAgeMilliseconds = age.isFinite && age >= 0 ? age : nil
            try Task.checkCancellation(); try checkScanning()
            guard shouldSubmit else {
                let message = result.comparison == .similar
                    ? "Face looks similar. Scan-only test complete; identity calibration and liveness are unfinished. No password entered."
                    : "Face not verified. No password entered. Use password or Touch ID."
                finish(.fallback, message, failure: result.comparison == .similar ? .scanOnly : .identity)
                return
            }
            if automaticUnlockEnabled {
                guard result.verification.identity == .experimentalMatch || result.verification.identity == .verified else {
                    throw FaceUnlockAttemptError.identity
                }
                guard result.verification.liveness != .rejected else { throw FaceUnlockAttemptError.liveness }
            } else {
                guard result.verification.identity == .verified else { throw FaceUnlockAttemptError.identity }
                guard result.verification.liveness == .verified else { throw FaceUnlockAttemptError.liveness }
            }
            guard var oneShot = attempt else { throw FaceUnlockAttemptError.expired }
            phase = .submitting; record("Verification passed. Checking the locked account and password field.")
            // The submitter commits consumption before plaintext access. Never retry this call.
            do { try services.submit(&oneShot, result.verification) }
            catch {
                let age = (services.now() - result.verification.observedAt) * 1000
                evidenceAgeMilliseconds = age.isFinite && age >= 0 ? age : nil
                attempt = oneShot; inputConsumed = oneShot.consumed; throw error
            }
            let inputAge = (services.now() - result.verification.observedAt) * 1000
            evidenceAgeMilliseconds = inputAge.isFinite && inputAge >= 0 ? inputAge : nil
            attempt = oneShot
            inputConsumed = oneShot.consumed
            guard oneShot.consumed else { throw FaceUnlockAttemptError.consumed }
            submittedAt = services.now()
            phase = .awaitingDesktop; record("Password submitted once. Waiting for the desktop.")
            while phase == .awaitingDesktop {
                try Task.checkCancellation()
                let snapshot = services.snapshot()
                guard !services.suspended(), snapshot.processUserID == userID else { throw FaceUnlockAttemptError.session }
                switch snapshot.assessment(at: services.uptime(), maximumAge: 0.5) {
                case .unlocked:
                    finish(.unlocked, "Desktop observed after one password submission."); return
                case .lockUnknown:
                    if desktopReturnObserved {
                        finish(.unlocked, "Desktop return reported after one password submission."); return
                    }
                case .observedLocked: break
                default: throw FaceUnlockAttemptError.session
                }
                guard let submittedAt, services.now() >= submittedAt, services.now() - submittedAt < 8 else {
                    if automaticUnlockEnabled { clearAutomaticSession() }
                    finish(.fallback, "Desktop return was not confirmed. Use password or Touch ID; no retry will be made.", failure: .unconfirmed); return
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            if automaticUnlockEnabled && (inputConsumed || !services.credentialsReady()) {
                clearAutomaticSession()
            }
            if phase != .canceled && phase != .fallback {
                finish(.fallback, error is CancellationError ? "Test canceled." : error.localizedDescription, failure: .classify(error))
            }
        }
    }

    func cancel(reason: String = "Lock-screen test canceled.") {
        guard isBusy else { return }
        operation?.cancel(); attempt?.cancel()
        services.stopCamera(); vault.lock()
        if !automaticUnlockEnabled { services.revokeCredentials() }
        watchdog?.cancel(); watchdog = nil
        finish(.canceled, reason, failure: .canceled)
    }

    private func checkDesktop(requireForeground: Bool = true) throws {
        let snapshot = services.snapshot()
        let assessment = snapshot.assessment(at: services.uptime(), maximumAge: 0.5)
        guard (!requireForeground || services.foreground()), services.available(), !services.suspended(), snapshot.processUserID == userID,
              assessment == .unlocked || assessment == .lockUnknown else { throw FaceUnlockAttemptError.session }
        guard vault.sessionIsValid else { throw EnrollmentError.expired }
    }

    private func waitForDesktop() async throws {
        // System authentication/permission sheets can return before AppKit restores activation.
        for poll in 0...50 {
            try Task.checkCancellation()
            try checkDesktop(requireForeground: false)
            if services.foreground() { return }
            guard poll < 50 else { throw FaceUnlockAttemptError.session }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func checkWaiting() throws {
        guard services.available(), !services.suspended(), vault.sessionIsValid, let attempt else { throw FaceUnlockAttemptError.session }
        try attempt.checkTime(services.now())
        let snapshot = services.snapshot()
        guard snapshot.processUserID == userID else { throw FaceUnlockAttemptError.session }
        switch snapshot.assessment(at: services.uptime(), maximumAge: 0.5) {
        case .unlocked, .lockUnknown, .observedLocked: break
        default: throw FaceUnlockAttemptError.session
        }
    }

    private func checkScanning() throws {
        try Task.checkCancellation()
        let templateValid = isAutomaticAttempt ? automaticScanningEnabled && automaticTemplate != nil : vault.sessionIsValid
        guard (phase == .scanning || phase == .waitingForPasswordField), !automaticSleeping, !services.suspended(), templateValid, let attempt else {
            throw FaceUnlockAttemptError.session
        }
        try attempt.checkTime(services.now())
        try attempt.checkSession(services.snapshot(), uptime: services.uptime())
        if shouldSubmit && !services.credentialsReady() { throw FaceUnlockAttemptError.credentials }
    }

    func watchdogTick() {
        guard isBusy else { return }
        do {
            if phase == .waitingForLock { try checkWaiting() }
            if phase == .scanning || phase == .waitingForPasswordField { try checkScanning() }
        } catch {
            operation?.cancel(); services.stopCamera(); vault.lock()
            if automaticUnlockEnabled && !services.credentialsReady() { clearAutomaticSession() }
            if !automaticUnlockEnabled { services.revokeCredentials() }
            finish(.fallback, error.localizedDescription, failure: .classify(error))
        }
    }

    private func startWatchdog() {
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                self?.watchdogTick()
            }
        }
    }

    deinit {
        automaticPolling?.cancel(); watchdog?.cancel(); operation?.cancel()
    }

    private func finish(_ phase: LockScreenPhase, _ message: String, failure: LockScreenFailure? = nil) {
        let origin = self.phase
        self.failure = failure ?? (phase == .fallback ? .setup : nil)
        self.phase = phase; record(message)
        guard phase == .fallback || phase == .canceled || phase == .unlocked else { return }
        services.saveDiagnostic(LockScreenDiagnosticReport(schema: 1, recordedAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            mode: activeMode, stage: origin, outcome: phase, failure: self.failure,
            inputConsumed: inputConsumed, passwordSubmitted: submittedAt != nil,
            evidenceAgeMilliseconds: evidenceAgeMilliseconds,
            capture: attempt == nil ? LockScreenCaptureDiagnostics() : services.captureDiagnostics(),
            indicator: services.indicatorDiagnostics(), inputTarget: attempt == nil ? nil : services.inputDiagnostic()))
    }
    private func record(_ message: String) {
        status = message
        events.insert(message, at: 0)
        if events.count > 8 { events.removeLast() }
    }
}

private struct LockScreenSetupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class LockFlowNotificationToken: @unchecked Sendable {
    let center: NotificationCenter
    let token: NSObjectProtocol
    init(center: NotificationCenter, token: NSObjectProtocol) { self.center = center; self.token = token }
    deinit { center.removeObserver(token) }
}
