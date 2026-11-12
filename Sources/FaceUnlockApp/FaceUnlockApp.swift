import SwiftUI
import ApplicationServices
import FaceUnlockCore
import FaceUnlockMac
import FaceUnlockRecognition

@main
@MainActor
struct FaceUnlockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel(provider: MacReadinessProvider())

    var body: some Scene {
        WindowGroup("Face Unlock") {
            StatusView(model: model)
                .onAppear { delegate.onTermination = { model.setup.cancel(); model.manualTest.cancel(); model.recognition.cancel(); model.enrollment.cancel(); model.faceTest.cancel(); model.lockScreen.disableAutomaticScanning(); model.lockScreen.cancel(); model.lockIndicator.hide() } }
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTermination: (() -> Void)?
    func applicationWillTerminate(_ notification: Notification) { onTermination?() }
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
    let lockIndicator = LockScreenIndicator()

    init(provider: any ReadinessProviding) {
        self.provider = provider
        manualTest = ManualUnlockController(monitor: sessionMonitor, vault: vault)
        let scanner = LockScreenFaceScanner()
        let reports = LockScreenReportStore()
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
                prepare: { try await scanner.prepare() },
                scan: { try await scanner.scan(template: $0, attemptID: $1, check: $2) },
                stopCamera: { scanner.stop() }, credentialsReady: { credentials.sessionIsValid && credentials.hasCredential },
                revokeCredentials: { credentials.lock() },
                submit: { attempt, verification in
                    try submitter.submit(attempt: &attempt, verification: verification, isSuspended: { monitor.isSuspended })
                }, supportsExperimentalUnlock: true,
                authorizeCredentials: { try await credentials.authorizeExperimentalFaceUnlock(acknowledgingPhotoRisk: true) },
                inputPermissionGranted: { AXIsProcessTrusted() },
                finishCamera: { await scanner.finish() }, captureDiagnostics: { scanner.diagnostics },
                saveDiagnostic: { reports.save($0) }))
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
