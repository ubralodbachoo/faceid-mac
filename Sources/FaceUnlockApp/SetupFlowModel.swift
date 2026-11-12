import Combine
import Foundation
import FaceUnlockMac

enum SetupStep: Int, CaseIterable {
    case permissions, face, password, finish

    var title: String {
        switch self {
        case .permissions: "Permissions"
        case .face: "Register face"
        case .password: "Enter password"
        case .finish: "Finish setup"
        }
    }
}

@MainActor
struct SetupFlowServices {
    var permissionsGranted: () -> Bool
    var hasFace: () -> Bool
    var hasPassword: () -> Bool
    var savePassword: @MainActor (Data) async throws -> Void
    var enableUnlock: @MainActor (Bool) async throws -> Void
    var disableUnlock: () -> Void
}

/// Setup completes only after the automatic unlock controller is actually enabled.
@MainActor
final class SetupFlowModel: ObservableObject {
    @Published private(set) var step = SetupStep.permissions
    @Published private(set) var isBusy = false
    @Published private(set) var status = ""
    @Published private(set) var isComplete = false
    @Published var acknowledgesPhotoRisk = false
    private let services: SetupFlowServices
    private var operation: Task<Void, Never>?

    init(services: SetupFlowServices) { self.services = services }

    func continuePermissions() {
        guard !isBusy else { return }
        guard services.permissionsGranted() else {
            status = "Allow Camera and Accessibility to continue."; return
        }
        status = ""; step = .face
    }

    func continueFace() {
        guard !isBusy else { return }
        guard services.hasFace() else { status = "Register and save your face to continue."; return }
        status = ""; step = .password
    }

    func useSavedPassword() {
        guard !isBusy, services.hasPassword() else { return }
        status = ""; step = .finish
    }

    func savePassword(_ password: Data) {
        guard !isBusy else { return }
        guard !password.isEmpty else { status = "Enter your Mac login password."; return }
        isBusy = true; status = "Confirm with macOS to save your password."
        operation = Task {
            var bytes = password
            defer {
                bytes.resetBytes(in: 0..<bytes.count)
                isBusy = false; operation = nil
            }
            do {
                try await services.savePassword(bytes)
                try Task.checkCancellation()
                guard services.hasPassword() else { throw VaultError.missingPassword }
                status = ""; step = .finish
            } catch { status = error.localizedDescription }
        }
    }

    func finish() {
        guard !isBusy else { return }
        guard services.permissionsGranted() else { step = .permissions; status = "Allow both permissions to continue."; return }
        guard services.hasFace() else { step = .face; status = "Register your face to continue."; return }
        guard services.hasPassword() else { step = .password; status = "Enter your Mac login password."; return }
        guard acknowledgesPhotoRisk else { status = VaultError.experimentalConsent.localizedDescription; return }
        isBusy = true; isComplete = false
        status = "Confirm with macOS to enable face unlock."
        operation = Task {
            defer { isBusy = false; operation = nil }
            do {
                try await services.enableUnlock(acknowledgesPhotoRisk)
                try Task.checkCancellation()
                isComplete = true; status = ""
            } catch { status = error.localizedDescription }
        }
    }

    func back() {
        guard !isBusy, !isComplete, let previous = SetupStep(rawValue: step.rawValue - 1) else { return }
        step = previous; status = ""
    }

    func unlockStopped() {
        isComplete = false
    }

    func turnOff() {
        guard !isBusy else { return }
        services.disableUnlock()
        isComplete = false; status = "Face unlock is off."
    }

    func cancel() {
        operation?.cancel()
        services.disableUnlock()
    }

    deinit { operation?.cancel() }
}
