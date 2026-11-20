import Foundation
import XCTest
@testable import FaceUnlockApp

final class PasswordSettingsTests: XCTestCase {
    @MainActor
    func testIndependentSaveCanRetryFailureAndRejectsDuplicateSubmissions() async throws {
        var calls = 0
        var fails = true
        let model = PasswordSettingsModel(services: PasswordSettingsServices(save: { bytes in
            calls += 1
            XCTAssertFalse(bytes.isEmpty)
            if fails { throw TestError.failed }
        }, cancel: {}))
        model.save(Data())
        XCTAssertEqual(calls, 0)
        model.save(Data("synthetic-only".utf8))
        model.save(Data("duplicate".utf8))
        try await idle(model)
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(model.status.contains("Password saved."))
        fails = false
        model.save(Data("synthetic-only".utf8))
        try await idle(model)
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(model.status.contains("Password saved."))
    }

    @MainActor
    func testCancelRejectsLateAuthenticationAndNeverReportsSaved() async throws {
        var pending: CheckedContinuation<Void, Never>?
        var canceled = false
        var saved = false
        let model = PasswordSettingsModel(services: PasswordSettingsServices(save: { _ in
            await withCheckedContinuation { pending = $0 }
            try Task.checkCancellation()
            saved = true
        }, cancel: { canceled = true }))
        model.save(Data("synthetic-only".utf8))
        for _ in 0..<1000 {
            if pending != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNotNil(pending)
        model.cancel()
        pending?.resume()
        try await idle(model)
        XCTAssertTrue(canceled)
        XCTAssertFalse(saved)
        XCTAssertFalse(model.status.contains("Password saved."))
    }

    @MainActor
    private func idle(_ model: PasswordSettingsModel) async throws {
        for _ in 0..<1000 {
            if !model.isBusy { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Password update did not complete")
    }
}

private enum TestError: Error { case failed }
