import SwiftUI
import FaceUnlockCore
import FaceUnlockMac

@main
@MainActor
struct FaceUnlockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel(provider: MacReadinessProvider())

    var body: some Scene {
        WindowGroup("Face Unlock — Development") {
            StatusView(model: model)
                .onAppear { delegate.onTermination = { model.manualTest.cancel() } }
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
    let manualTest: ManualUnlockController

    init(provider: any ReadinessProviding) {
        self.provider = provider
        manualTest = ManualUnlockController(monitor: sessionMonitor, vault: vault)
        refresh()
        sessionMonitor.start()
    }

    func refresh() {
        report = provider.inspect()
        vault.refreshPresence()
        sessionMonitor.refresh()
    }
}
