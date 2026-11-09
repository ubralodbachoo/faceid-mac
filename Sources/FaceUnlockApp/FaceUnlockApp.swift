import SwiftUI
import FaceUnlockCore
import FaceUnlockMac

@main
@MainActor
struct FaceUnlockApp: App {
    @StateObject private var model = AppModel(provider: MacReadinessProvider())

    var body: some Scene {
        WindowGroup("Face Unlock — Development") {
            StatusView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var report = ReadinessReport(statuses: [:])
    private let provider: any ReadinessProviding

    init(provider: any ReadinessProviding) {
        self.provider = provider
        refresh()
    }

    func refresh() {
        report = provider.inspect()
    }
}
