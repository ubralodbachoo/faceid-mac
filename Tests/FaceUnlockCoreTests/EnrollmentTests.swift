import CryptoKit
import CoreImage
import CoreVideo
import Foundation
import XCTest
@testable import FaceUnlockCore
@testable import FaceUnlockMac
@testable import FaceUnlockRecognition

private let enrollmentModelID = "synthetic-enrollment-model-v1"

private func descriptor(_ seed: Float = 1, model: String = enrollmentModelID) throws -> FaceEmbedding {
    try FaceEmbedding(raw: (0..<512).map { Float($0 % 13) + seed }, modelIdentifier: model)
}

private func template(_ seed: Float = 1, model: String = enrollmentModelID) throws -> EnrollmentTemplate {
    try EnrollmentTemplate(embeddings: (0..<VideoEnrollmentCollector.requiredSamples).map { try descriptor(seed + Float($0), model: model) }, modelIdentifier: model)
}

private func metrics(yaw: Double = 0, pitch: Double = 0, light: Double = 120, quality: Double = 0.8,
                     roll: Double = 0, width: Double = 180, centered: Bool = true) -> EnrollmentMetrics {
    EnrollmentMetrics(quality: quality, yaw: yaw, pitch: pitch, roll: roll,
                      faceWidthPixels: width, faceHeightPixels: 200, centered: centered, luminance: light)
}

@MainActor
private final class EnrollmentKeys: CredentialKeyStoring {
    var value: Data?
    var creates = 0
    var unavailable = false
    var failDelete = false
    func read() throws -> Data? { if unavailable { throw VaultError.keychain(-1) }; return value }
    func create(_ data: Data) throws { guard value == nil else { throw VaultError.invalidKey }; value = data; creates += 1 }
    func delete() throws { if failDelete { throw VaultError.storage }; value = nil }
}

@MainActor
private final class EnrollmentBlobs: CredentialBlobStoring {
    var value: Data?
    var failWrite = false
    var failDelete = false
    func read() throws -> Data? { value }
    func write(_ data: Data) throws { if failWrite { throw VaultError.storage }; value = data }
    func delete() throws { if failDelete { throw VaultError.storage }; value = nil }
}

@MainActor
private final class EnrollmentAuth: SystemAuthenticating {
    var fail = false
    var action: (() -> Void)?
    var calls = 0
    func authenticate(reason: String) async throws { calls += 1; action?(); if fail { throw VaultError.canceled } }
    func cancel() {}
}

final class EnrollmentTests: XCTestCase {
    func testFrontalPoseFeedbackExplainsChinDirectionInsteadOfRepeatingHoldStill() {
        let draft = EnrollmentDraft(modelIdentifier: enrollmentModelID)
        XCTAssertTrue(draft.poseAdjustment(for: metrics(pitch: 0.2)).contains("Lift your chin"))
        XCTAssertTrue(draft.poseAdjustment(for: metrics(pitch: -0.2)).contains("Lower your chin"))
        XCTAssertTrue(draft.poseAdjustment(for: metrics(yaw: 0.2)).contains("Turn your nose toward"))
    }

    func testCaptureQualityFeedbackExplainsTheAdjustmentWithoutRelaxingValidation() {
        let cases: [(EnrollmentMetrics, String)] = [
            (metrics(width: 80), "closer"), (metrics(centered: false), "middle"),
            (metrics(light: 20), "Add some light"), (metrics(light: 240), "Reduce"),
            (metrics(roll: 0.3), "head level"), (metrics(yaw: 0.7), "Turn back"),
            (metrics(quality: 0.1), "Hold still"), (metrics(quality: .nan), "position")
        ]
        for (metrics, phrase) in cases {
            XCTAssertTrue(metrics.adjustment?.contains(phrase) == true)
            XCTAssertThrowsError(try metrics.validate())
        }
        XCTAssertNil(metrics().adjustment)
        XCTAssertNoThrow(try metrics().validate())
    }

    func testCameraImageIsMaterializedBeforeCaptureBufferCanBeReused() throws {
        let buffer = try ArcFaceRecognizer.syntheticPixels(seed: 7)
        let image = try XCTUnwrap(EnrollmentCamera.makeImage(from: buffer, context: CIContext(options: [.cacheIntermediates: false])))
        XCTAssertEqual(image.width, 112)
        XCTAssertEqual(image.height, 112)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        memset(base, 0, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let pixels = try XCTUnwrap(image.dataProvider?.data) as Data
        XCTAssertTrue(pixels.contains { $0 != 0 && $0 != 255 })
    }

    func testCameraCanBeStoppedBeforeStartWithoutOpeningHardware() async throws {
        let camera = EnrollmentCamera()
        await camera.stopAndWait()
        camera.start()
        var iterator = camera.frames.makeAsyncIterator()
        let frame = try await iterator.next()
        XCTAssertNil(frame)
        await camera.stopAndWait() // Shutdown is idempotent.
    }

    @MainActor
    func testOptInDisposableKeychainAndEncryptedTemplateRoundTrip() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FACEUNLOCK_RUN_KEYCHAIN_TEST"] == "1", "Real Keychain test is opt-in")
        let keys = DevelopmentKeyStore(service: "org.faceunlock.test.enrollment.\(UUID().uuidString)",
                                       account: "synthetic-template", label: "Disposable synthetic enrollment test")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? keys.delete(); try? FileManager.default.removeItem(at: directory) }
        let vault = EnrollmentVault(keys: keys, blobs: FileCredentialStore(directory: directory, filename: "enrollment-v1.enc"),
                                    authenticator: EnrollmentAuth(), modelIdentifier: enrollmentModelID)
        try await vault.beginEnrollment(); try vault.save(template())
        try await vault.authorizeReading()
        XCTAssertEqual(try vault.templateForVerification().embeddings.count, VideoEnrollmentCollector.requiredSamples)
        try await vault.delete()
        XCTAssertNil(try keys.read())
        XCTAssertFalse(vault.hasEnrollment)
    }

    func testGuidedDraftRequiresOppositePosesAndLightingVariation() throws {
        var draft = EnrollmentDraft(modelIdentifier: enrollmentModelID)
        let embedding = try descriptor()
        XCTAssertThrowsError(try draft.finish())
        try draft.accept(embedding, metrics: metrics())
        XCTAssertThrowsError(try draft.accept(embedding, metrics: metrics()))
        XCTAssertEqual(draft.count, 1)
        try draft.accept(embedding, metrics: metrics(yaw: 0.20))
        XCTAssertThrowsError(try draft.accept(embedding, metrics: metrics(yaw: 0.22)))
        try draft.accept(embedding, metrics: metrics(yaw: -0.20))
        try draft.accept(embedding, metrics: metrics(pitch: 0.16))
        XCTAssertThrowsError(try draft.accept(embedding, metrics: metrics(pitch: 0.18)))
        try draft.accept(embedding, metrics: metrics(pitch: -0.16))
        XCTAssertThrowsError(try draft.accept(embedding, metrics: metrics(light: 125)))
        try draft.accept(embedding, metrics: metrics(light: 135))
        XCTAssertThrowsError(try draft.accept(embedding, metrics: metrics(light: 135)))
        try draft.accept(embedding, metrics: metrics(light: 105))
        XCTAssertNil(draft.nextStep)
        XCTAssertEqual(try draft.finish().embeddings.count, 7)
        XCTAssertThrowsError(try draft.accept(embedding, metrics: metrics()))
        XCTAssertFalse(String(reflecting: draft).contains(String(embedding.values[0])))
        XCTAssertTrue(String(reflecting: try draft.finish()).contains("redacted"))
    }

    func testPoorMissingOrNonfiniteCaptureMetricsCannotAdvance() throws {
        let invalid = [metrics(quality: 0.1), metrics(quality: .nan), metrics(yaw: .infinity),
                       metrics(pitch: .nan), metrics(roll: .nan), metrics(light: .nan),
                       metrics(light: 20), metrics(light: 240), metrics(roll: 0.3),
                       metrics(width: 119), metrics(width: .nan), metrics(centered: false), metrics(yaw: 0.7)]
        for item in invalid {
            var draft = EnrollmentDraft(modelIdentifier: enrollmentModelID)
            XCTAssertThrowsError(try draft.accept(descriptor(), metrics: item))
            XCTAssertEqual(draft.count, 0)
        }
        var draft = EnrollmentDraft(modelIdentifier: enrollmentModelID)
        XCTAssertThrowsError(try draft.accept(descriptor(model: "other-model"), metrics: metrics()))
        XCTAssertEqual(draft.count, 0)
    }

    @MainActor
    func testEncryptedFilePersistsAcrossRealStoreRecreationAndDeletes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = EnrollmentKeys(), auth = EnrollmentAuth()
        let first = EnrollmentVault(keys: keys, blobs: FileCredentialStore(directory: directory, filename: "enrollment-v1.enc"),
                                    authenticator: auth, modelIdentifier: enrollmentModelID)
        let enrolled = try template()
        try await first.beginEnrollment()
        try first.save(enrolled)
        XCTAssertFalse(first.sessionIsValid)
        let ciphertext = try Data(contentsOf: directory.appendingPathComponent("enrollment-v1.enc"))
        XCTAssertTrue(ciphertext.starts(with: Data("FUE1".utf8)))
        XCTAssertNil(ciphertext.range(of: Data(enrollmentModelID.utf8)))
        XCTAssertNil(ciphertext.range(of: Data("vectors".utf8)))
        let restarted = EnrollmentVault(keys: keys, blobs: FileCredentialStore(directory: directory, filename: "enrollment-v1.enc"),
                                        authenticator: auth, modelIdentifier: enrollmentModelID)
        XCTAssertTrue(restarted.hasEnrollment)
        XCTAssertThrowsError(try restarted.templateForVerification())
        try await restarted.authorizeReading()
        XCTAssertGreaterThan(try restarted.templateForVerification().embeddings[0].cosineSimilarity(to: enrolled.embeddings[0]), 0.999999)
        try await restarted.delete()
        XCTAssertNil(keys.value)
        XCTAssertFalse(restarted.hasEnrollment)
        XCTAssertFalse(restarted.sessionIsValid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("enrollment-v1.enc").path))
        XCTAssertEqual(keys.creates, 1)
        XCTAssertEqual(auth.calls, 3)
    }

    @MainActor
    func testCanceledAndFailedReplacementKeepOriginalThenSuccessfulReplacementCommits() async throws {
        let keys = EnrollmentKeys(), blobs = EnrollmentBlobs(), auth = EnrollmentAuth()
        let vault = EnrollmentVault(keys: keys, blobs: blobs, authenticator: auth, modelIdentifier: enrollmentModelID)
        try await vault.beginEnrollment(); try vault.save(template())
        let original = blobs.value
        try await vault.beginEnrollment()
        vault.lock()
        XCTAssertThrowsError(try vault.save(template(30)))
        XCTAssertEqual(blobs.value, original)
        auth.fail = true
        do { try await vault.beginEnrollment(); XCTFail("Canceled authentication") } catch {}
        XCTAssertEqual(blobs.value, original)
        auth.fail = false
        try await vault.beginEnrollment()
        blobs.failWrite = true
        XCTAssertThrowsError(try vault.save(template(30)))
        XCTAssertEqual(blobs.value, original)
        blobs.failWrite = false
        try vault.save(template(30))
        XCTAssertNotEqual(blobs.value, original)
        try await vault.authorizeReading()
        XCTAssertGreaterThan(try vault.templateForVerification().embeddings[0].cosineSimilarity(to: descriptor(30)), 0.999999)
        XCTAssertThrowsError(try vault.save(template())) // Read leases cannot mutate.
    }

    @MainActor
    func testCorruptWrongAccountWrongModelAndUnavailableKeysFailClosed() async throws {
        let keys = EnrollmentKeys(), blobs = EnrollmentBlobs(), auth = EnrollmentAuth()
        func make(_ uid: UInt32 = 501, _ model: String = enrollmentModelID) -> EnrollmentVault {
            EnrollmentVault(keys: keys, blobs: blobs, authenticator: auth, modelIdentifier: model, userID: uid)
        }
        let vault = make()
        try await vault.beginEnrollment(); try vault.save(template())
        let original = blobs.value!
        for bad in [Data("invalid".utf8), Data(original.dropLast()), Data(repeating: 0, count: 250_001)] {
            blobs.value = bad
            do { try await vault.authorizeReading(); XCTFail("Corrupt ciphertext") } catch {}
            XCTAssertFalse(vault.sessionIsValid)
        }
        blobs.value = original
        let otherAccount = make(502), otherModel = make(501, "new-model")
        for candidate in [otherAccount, otherModel] {
            do { try await candidate.authorizeReading(); XCTFail("Account/model mismatch") } catch {}
            XCTAssertFalse(candidate.sessionIsValid)
        }
        keys.unavailable = true
        do { try await vault.authorizeReading(); XCTFail("Key unavailable") } catch {}
        XCTAssertEqual(blobs.value, original)
        keys.unavailable = false
        keys.value = nil
        do { try await vault.beginEnrollment(); XCTFail("Missing key") } catch {}
        XCTAssertEqual(blobs.value, original)
        XCTAssertEqual(keys.creates, 1)
    }

    @MainActor
    func testModelUpgradeRequiresFreshEnrollmentAndNeverReadsOldTemplateAsCurrent() async throws {
        let keys = EnrollmentKeys(), blobs = EnrollmentBlobs(), auth = EnrollmentAuth()
        let old = EnrollmentVault(keys: keys, blobs: blobs, authenticator: auth, modelIdentifier: enrollmentModelID)
        try await old.beginEnrollment(); try old.save(template())
        let upgraded = EnrollmentVault(keys: keys, blobs: blobs, authenticator: auth, modelIdentifier: "model-v2")
        do { try await upgraded.authorizeReading(); XCTFail("Model mismatch") } catch {}
        try await upgraded.beginEnrollment()
        XCTAssertThrowsError(try upgraded.templateForVerification())
        try await upgraded.beginEnrollment()
        try upgraded.save(template(model: "model-v2"))
        try await upgraded.authorizeReading()
        XCTAssertEqual(try upgraded.templateForVerification().modelIdentifier, "model-v2")
    }

    @MainActor
    func testSleepInclusiveExpiryRevocationAndLateAuthentication() async throws {
        var time = 100.0
        let keys = EnrollmentKeys(), blobs = EnrollmentBlobs(), auth = EnrollmentAuth()
        let vault = EnrollmentVault(keys: keys, blobs: blobs, authenticator: auth, modelIdentifier: enrollmentModelID, now: { time })
        auth.action = { vault.lock() }
        do { try await vault.beginEnrollment(); XCTFail("Late authentication") } catch {}
        XCTAssertNil(keys.value)
        auth.action = nil
        try await vault.beginEnrollment()
        time = 280
        XCTAssertThrowsError(try vault.save(template()))
        XCTAssertNil(blobs.value)
        time = 300
        try await vault.beginEnrollment(); try vault.save(template())
        try await vault.authorizeReading()
        time = 390
        XCTAssertThrowsError(try vault.templateForVerification())
        XCTAssertFalse(vault.sessionIsValid)
        time = 400
        try await vault.authorizeReading()
        time = 399 // Invalid backward time fails closed too.
        XCTAssertThrowsError(try vault.templateForVerification())
    }

    @MainActor
    func testCanceledOrFailedDeletionPreservesDataAndRetryCleansKeylessCiphertext() async throws {
        let keys = EnrollmentKeys(), blobs = EnrollmentBlobs(), auth = EnrollmentAuth()
        let vault = EnrollmentVault(keys: keys, blobs: blobs, authenticator: auth, modelIdentifier: enrollmentModelID)
        try await vault.beginEnrollment(); try vault.save(template())
        let original = blobs.value
        auth.fail = true
        do { try await vault.delete(); XCTFail("Canceled delete") } catch {}
        XCTAssertEqual(blobs.value, original); XCTAssertNotNil(keys.value)
        auth.fail = false; keys.failDelete = true
        do { try await vault.delete(); XCTFail("Key deletion failed") } catch {}
        XCTAssertEqual(blobs.value, original); XCTAssertNotNil(keys.value)
        keys.failDelete = false; blobs.failDelete = true
        do { try await vault.delete(); XCTFail("File deletion failed") } catch {}
        XCTAssertNil(keys.value)
        XCTAssertEqual(blobs.value, original)
        XCTAssertThrowsError(try vault.templateForVerification())
        blobs.failDelete = false
        try await vault.delete()
        XCTAssertNil(blobs.value)
    }

    @MainActor
    func testLegacyEnrollmentRequiresReenrollmentAndCanceledUpgradePreservesCiphertext() async throws {
        let keys = EnrollmentKeys(), blobs = EnrollmentBlobs(), auth = EnrollmentAuth()
        let key = SymmetricKey(size: .bits256)
        keys.value = key.withUnsafeBytes { Data($0) }
        let vectors = try (0..<7).map { try descriptor(Float($0) + 1).values }
        let payload: [String: Any] = ["schema": 1, "userID": 501, "modelIdentifier": enrollmentModelID, "vectors": vectors]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let sealed = try AES.GCM.seal(data, using: key, authenticating: Data("org.faceunlock.development:enrollment-v1:uid=501".utf8))
        blobs.value = Data("FUE1".utf8) + sealed.combined!
        let original = blobs.value
        let vault = EnrollmentVault(keys: keys, blobs: blobs, authenticator: auth, modelIdentifier: enrollmentModelID, userID: 501)
        do { try await vault.authorizeReading(); XCTFail("Legacy samples must not become continuous-video enrollment") } catch {}
        try await vault.beginEnrollment()
        vault.lock()
        XCTAssertEqual(blobs.value, original)
        try await vault.beginEnrollment()
        try vault.save(template())
        try await vault.authorizeReading()
        XCTAssertEqual(try vault.templateForVerification().format, .continuousVideo)
        XCTAssertEqual(try vault.templateForVerification().embeddings.count, 18)
    }

    @MainActor
    func testIncompatibleContinuousPipelineOrPolicyCannotBeRead() async throws {
        let keys = EnrollmentKeys(), blobs = EnrollmentBlobs(), auth = EnrollmentAuth()
        let key = SymmetricKey(size: .bits256)
        keys.value = key.withUnsafeBytes { Data($0) }
        let vectors = try template().embeddings.map(\.values)
        let vault = EnrollmentVault(keys: keys, blobs: blobs, authenticator: auth, modelIdentifier: enrollmentModelID, userID: 501)
        for wrongPipeline in [false, true] {
            let payload: [String: Any] = ["schema": 2, "userID": 501, "modelIdentifier": enrollmentModelID,
                "pipelineIdentifier": wrongPipeline ? "different-pipeline" : VideoEnrollmentCollector.pipelineIdentifier,
                "policyIdentifier": wrongPipeline ? VideoEnrollmentCollector.policyIdentifier : "different-policy",
                "vectors": vectors]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let sealed = try AES.GCM.seal(data, using: key, authenticating: Data("org.faceunlock.development:enrollment-v1:uid=501".utf8))
            blobs.value = Data("FUE1".utf8) + sealed.combined!
            do { try await vault.authorizeReading(); XCTFail("Different preprocessing/collection policy") } catch {}
            XCTAssertFalse(vault.sessionIsValid)
        }
    }

    @MainActor
    func testAuthenticatedButMalformedPayloadsCannotProduceTemplate() async throws {
        let keys = EnrollmentKeys(), blobs = EnrollmentBlobs(), auth = EnrollmentAuth()
        let key = SymmetricKey(size: .bits256)
        keys.value = key.withUnsafeBytes { Data($0) }
        let vault = EnrollmentVault(keys: keys, blobs: blobs, authenticator: auth, modelIdentifier: enrollmentModelID, userID: 501)
        let validVectors = try template().embeddings.map(\.values)
        let invalidPayloads: [[String: Any]] = [
            ["schema": 2, "userID": 501, "modelIdentifier": enrollmentModelID, "vectors": validVectors],
            ["schema": 1, "userID": 502, "modelIdentifier": enrollmentModelID, "vectors": validVectors],
            ["schema": 1, "userID": 501, "modelIdentifier": enrollmentModelID, "vectors": Array(validVectors.prefix(6))],
            ["schema": 1, "userID": 501, "modelIdentifier": enrollmentModelID, "vectors": Array(repeating: [0.0], count: 7)]
        ]
        for payload in invalidPayloads {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let sealed = try AES.GCM.seal(data, using: key, authenticating: Data("org.faceunlock.development:enrollment-v1:uid=501".utf8))
            blobs.value = Data("FUE1".utf8) + sealed.combined!
            do { try await vault.authorizeReading(); XCTFail("Malformed template") } catch {}
            XCTAssertFalse(vault.sessionIsValid)
        }
    }
}
