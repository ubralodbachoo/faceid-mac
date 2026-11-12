import Foundation
import XCTest
@testable import FaceUnlockApp
import FaceUnlockCore
import FaceUnlockMac

final class LockScreenDiagnosticTests: XCTestCase {
    private func report(_ failure: LockScreenFailure) -> LockScreenDiagnosticReport {
        LockScreenDiagnosticReport(schema: 1, recordedAt: Date(), appVersion: "test",
            mode: "experimental-unlock", stage: .submitting, outcome: .fallback, failure: failure,
            inputConsumed: false, passwordSubmitted: false, evidenceAgeMilliseconds: 825,
            capture: LockScreenCaptureDiagnostics(analyzedFrames: 18, rejectedFrames: 2, usableFrames: 12, lastIssue: .usable))
    }

    func testLastReportIsPrivateAtomicAndContainsOnlyOperationalFields() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LockScreenReportStore(directory: directory)
        store.save(report(.identity)); store.save(report(.staleEvidence))
        await store.waitForPendingWrites()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.file)) as? [String: Any])
        XCTAssertEqual(json["failure"] as? String, "staleEvidence", "Only the latest report is retained")
        XCTAssertEqual(json["mode"] as? String, "experimental-unlock")
        XCTAssertEqual(Set(json.keys), ["schema", "recordedAt", "appVersion", "mode", "stage", "outcome", "failure", "inputConsumed", "passwordSubmitted", "evidenceAgeMilliseconds", "capture"])
        let capture = try XCTUnwrap(json["capture"] as? [String: Any])
        XCTAssertEqual(Set(capture.keys), ["passwordFieldWaitFrames", "scheduledOutFrames", "comparisonCounts", "rejectionCounts", "peakUsableFrames", "analyzedFrames", "rejectedFrames", "usableFrames", "lastIssue"])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["last-failed-lock-attempt.json", "last-lock-attempt.json"])
    }

    func testLaterSuccessDoesNotEraseLatestFailedAttempt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LockScreenReportStore(directory: directory)
        store.save(report(.identity))
        store.save(LockScreenDiagnosticReport(schema: 1, recordedAt: Date(), appVersion: "test",
            mode: "experimental-unlock", stage: .awaitingDesktop, outcome: .unlocked, failure: nil,
            inputConsumed: true, passwordSubmitted: true, evidenceAgeMilliseconds: 30,
            capture: LockScreenCaptureDiagnostics()))
        await store.waitForPendingWrites()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let failed = try decoder.decode(LockScreenDiagnosticReport.self,
            from: Data(contentsOf: directory.appendingPathComponent("last-failed-lock-attempt.json")))
        XCTAssertEqual(failed.failure, .identity)
        let latest = try decoder.decode(LockScreenDiagnosticReport.self, from: Data(contentsOf: store.file))
        XCTAssertEqual(latest.outcome, .unlocked)
    }

    func testReportDoesNotFollowSymlinkOrOverwriteItsTarget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("untouched")
        try Data("must-not-change".utf8).write(to: target)
        let store = LockScreenReportStore(directory: directory)
        try FileManager.default.createSymbolicLink(at: store.file, withDestinationURL: target)
        store.save(report(.focus))
        await store.waitForPendingWrites()
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "must-not-change")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: store.file.path), target.path)
    }

    func testFailureCaptionsDistinguishRecognitionFromInputAndSetup() {
        XCTAssertEqual(LockScreenFailure.classify(FaceUnlockAttemptError.identity), .identity)
        XCTAssertEqual(LockScreenFailure.classify(FaceUnlockAttemptError.staleEvidence), .staleEvidence)
        XCTAssertEqual(LockScreenFailure.classify(InputError.field), .focus)
        XCTAssertEqual(LockScreenFailure.classify(InputError.accessibility), .accessibility)
        XCTAssertEqual(LockScreenFailure.classify(FaceUnlockAttemptError.credentials), .credentials)
        XCTAssertEqual(LockScreenFailure.classify(CancellationError()), .canceled)
        XCTAssertNotEqual(LockScreenFailure.identity.caption, LockScreenFailure.focus.caption)
        XCTAssertNotEqual(LockScreenFailure.scanOnly.caption, LockScreenFailure.identity.caption)
    }
}
