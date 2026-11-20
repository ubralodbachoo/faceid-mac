import SwiftUI
import Combine
import ApplicationServices
import FaceUnlockCore
import FaceUnlockMac
import FaceUnlockRecognition

@main
@MainActor
struct FaceUnlockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            Button("System Settings…") { delegate.openSettings() }
                .keyboardShortcut(",")
            Divider()
            Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            FaceUnlockMenuLabel(model: delegate.model.lockScreen)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct FaceUnlockMenuLabel: View {
    @ObservedObject var model: LockScreenFlowModel
    var body: some View {
        Image(systemName: "faceid")
            .accessibilityLabel(model.automaticUnlockEnabled ? "Face Unlock, on" : "Face Unlock, off")
            .help(model.automaticUnlockEnabled ? "Face Unlock is on" : "Face Unlock is off")
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var report = ReadinessReport(statuses: [:])
    private let provider: any ReadinessProviding
    let sessionMonitor = MacSessionMonitor()
    let vault = CredentialVault()
    private let automaticCredentials = CredentialVault()
    let manualTest: ManualUnlockController
    let recognition = RecognitionTestModel()
    let enrollment = EnrollmentModel()
    let faceTest = FaceTestModel()
    let lockScreen: LockScreenFlowModel
    let setup: SetupFlowModel
    let passwordSettings: PasswordSettingsModel
    let preferences = AppPreferences()
    let lockIndicator: LockScreenIndicator
    private var setupObservation: AnyCancellable?

    init(provider: any ReadinessProviding) {
        self.provider = provider
        lockIndicator = LockScreenIndicator(preferences: preferences)
        manualTest = ManualUnlockController(monitor: sessionMonitor, vault: vault)
        let scanner = LockScreenFaceScanner(mode: .shortEvaluation)
        let reports = LockScreenReportStore()
        let indicator = lockIndicator
        let monitor = sessionMonitor
        let credentials = automaticCredentials
        let manualCredentials = vault
        let manual = manualTest
        let enrollment = enrollment
        let comparison = faceTest
        let submitter = VerifiedUnlockSubmitter(vault: credentials)
        lockScreen = LockScreenFlowModel(
            vault: EnrollmentVault(modelIdentifier: ArcFaceContract.identifier),
            services: LockScreenFlowServices(
                available: { !manual.isArmed && !manualCredentials.isBusy && !enrollment.isBusy && !enrollment.canSave && !comparison.isBusy },
                suspended: { monitor.isSuspended },
                prepare: {
                    // Prepare the decorative bridge before the next lock.
                    indicator.prepareForLockScreen()
                    try await scanner.prepare()
                },
                scan: { try await scanner.scan(template: $0, attemptID: $1, check: $2, readyToReturn: $3) },
                stopCamera: { scanner.stop(); submitter.clearPreparedTarget() }, credentialsReady: { credentials.sessionIsValid && credentials.hasCredential },
                revokeCredentials: { credentials.lock() },
                submit: { attempt, verification in
                    try submitter.submit(attempt: &attempt, verification: verification, isSuspended: { monitor.isSuspended })
                }, supportsExperimentalUnlock: true,
                authorizeCredentials: { try await credentials.authorizeExperimentalFaceUnlock(acknowledgingPhotoRisk: true) },
                inputPermissionGranted: { AXIsProcessTrusted() },
                prepareInput: { try submitter.prepareInput() },
                revealInput: { try submitter.revealPasswordPrompt() },
                finishCamera: { await scanner.finish() }, indicatorDiagnostics: { indicator.diagnostics }, captureDiagnostics: { scanner.diagnostics },
                inputDiagnostic: { submitter.inputDiagnostic },
                saveDiagnostic: { reports.save($0) },
                desktopFocused: { InputDiagnostics.desktopApplicationFocused() }))
        let lockScreen = lockScreen
        setup = SetupFlowModel(services: SetupFlowServices(
            permissionsGranted: {
                let report = provider.inspect()
                return report.status(for: .cameraPermission) == .available && report.status(for: .accessibilityPermission) == .available
            }, hasFace: { enrollment.refresh(); return enrollment.hasEnrollment },
            hasPassword: { manualCredentials.refreshPresence(); return manualCredentials.hasCredential },
            savePassword: { password in
                defer { manualCredentials.lock() }
                try await manualCredentials.authorizeForPasswordSetup()
                try Task.checkCancellation()
                try manualCredentials.save(password)
            }, enableUnlock: { consent in try await lockScreen.enableForSetup(acknowledgingPhotoRisk: consent) },
            disableUnlock: { lockScreen.disableAutomaticScanning() }))
        passwordSettings = PasswordSettingsModel(services: PasswordSettingsServices(save: { password in
            lockScreen.disableAutomaticScanning()
            defer { manualCredentials.lock() }
            try await manualCredentials.authorizeForPasswordSetup()
            try Task.checkCancellation()
            try manualCredentials.save(password)
        }, cancel: { manualCredentials.lock() }))
        setupObservation = setup.$isComplete.filter { $0 }.sink { [weak self] _ in
            self?.preferences.recordCompletedSetup()
        }
        lockIndicator.observe(lockScreen)
        refresh()
        sessionMonitor.start()
    }

    func refresh() {
        report = provider.inspect()
        vault.refreshPresence()
        enrollment.refresh()
        sessionMonitor.refresh()
    }
}
