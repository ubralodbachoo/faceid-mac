import Combine
import Foundation

@MainActor
struct PasswordSettingsServices {
    var save: (Data) async throws -> Void
    var cancel: () -> Void
}

/// Independent password editing never advances or completes onboarding.
@MainActor
final class PasswordSettingsModel: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var status = ""
    private let services: PasswordSettingsServices
    private var operation: Task<Void, Never>?

    init(services: PasswordSettingsServices) { self.services = services }

    func save(_ password: Data) {
        guard !isBusy else { return }
        guard !password.isEmpty else { status = "Enter your Mac login password."; return }
        isBusy = true
        status = "Confirm with macOS to save your password."
        operation = Task {
            var bytes = password
            defer { bytes.resetBytes(in: 0..<bytes.count); isBusy = false; operation = nil }
            do {
                try await services.save(bytes)
                try Task.checkCancellation()
                status = "Password saved. Enable Face Unlock again when you’re ready."
            } catch {
                status = error is CancellationError ? "Password update canceled." : error.localizedDescription
            }
        }
    }

    func cancel() { operation?.cancel(); services.cancel() }
    deinit { operation?.cancel() }
}
