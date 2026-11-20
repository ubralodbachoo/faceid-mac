import Combine
import CryptoKit
import Darwin
import Foundation
import FaceUnlockCore

/// Independent biometric vault: never reads the password key, ciphertext, or credential lease.
@MainActor
public final class EnrollmentVault: ObservableObject {
    public static let didChangeNotification = Notification.Name("org.faceunlock.enrollmentChanged")
    @Published public private(set) var hasEnrollment = false
    private let keys: any CredentialKeyStoring
    private let blobs: any CredentialBlobStoring
    private let authenticator: any SystemAuthenticating
    private let now: () -> Double
    private let userID: UInt32
    private let modelIdentifier: String
    private let associatedData: Data
    private var key: SymmetricKey?
    private var deadline: Double?
    private var enrollmentSession = false
    private var addingFace = false
    private var replacingFace: Int?
    private var authorizedBlobDigest: Data?
    @Published public private(set) var faceCount: Int?
    public private(set) var registeredNames: [String] = []
    public private(set) var registeredEnabled: [Bool] = []
    public private(set) var metadataRevision: Data?
    private var generation = UUID()
    private var busy = false
    private var expiryTask: Task<Void, Never>?

    public convenience init(modelIdentifier: String) {
        self.init(keys: DevelopmentKeyStore(service: "org.faceunlock.development.enrollment-key.v1",
                                           label: "Face Unlock development face-template key"),
                  blobs: FileCredentialStore(filename: "enrollment-v1.enc"),
                  authenticator: SystemAuthenticator(), modelIdentifier: modelIdentifier)
    }

    init(keys: any CredentialKeyStoring, blobs: any CredentialBlobStoring,
         authenticator: any SystemAuthenticating, modelIdentifier: String,
         userID: UInt32 = getuid(), now: @escaping () -> Double = { ContinuousTime.now }) {
        self.keys = keys; self.blobs = blobs; self.authenticator = authenticator
        self.modelIdentifier = modelIdentifier; self.userID = userID; self.now = now
        associatedData = Data("org.faceunlock.development:enrollment-v1:uid=\(userID)".utf8)
        refreshPresence()
    }

    public var sessionIsValid: Bool {
        guard key != nil, let deadline, deadline.isFinite else { return false }
        let time = now()
        return time.isFinite && time >= 0 && time >= deadline - (enrollmentSession ? 180 : 90) && time < deadline
    }

    public var secondsRemaining: Int {
        guard sessionIsValid, let deadline else { return 0 }
        return max(0, Int(ceil(deadline - now())))
    }

    public func refreshPresence() { hasEnrollment = (try? blobs.read()) != nil }

    /// Fresh OS authentication for each enrollment/replacement; expires including sleep.
    public func beginEnrollment(addingFace: Bool = false, replacingFace: Int? = nil, expectedRevision: Data? = nil) async throws {
        try await authorize(enrolling: true)
        do {
            guard !(addingFace && replacingFace != nil) else { throw EnrollmentError.incompatible }
            if let expectedRevision, authorizedBlobDigest != expectedRevision { throw EnrollmentError.expired }
            if addingFace || replacingFace != nil {
                guard let key, let blob = try blobs.read() else { throw EnrollmentError.incomplete }
                let existing = try decode(blob, key: key, requireCurrentModel: true)
                if addingFace && existing.faces.count >= EnrollmentTemplate.maximumFaces { throw EnrollmentError.faceLimit }
                if let replacingFace, !existing.faces.indices.contains(replacingFace) { throw EnrollmentError.incompatible }
            }
            self.addingFace = addingFace; self.replacingFace = replacingFace
        } catch { lock(); throw error }
    }

    /// Explicit read lease for a later verifier. This cannot authorize password access or input.
    public func authorizeReading() async throws {
        try await authorize(enrolling: false)
        do { _ = try templateForVerification() }
        catch { lock(); throw error }
    }

    private func authorize(enrolling: Bool, reason: String? = nil) async throws {
        guard !busy else { throw EnrollmentError.busy }
        lock()
        let token = generation
        busy = true
        defer { busy = false }
        try await authenticator.authenticate(reason: reason ?? (enrolling
            ? "Enroll or replace your local Face Unlock face template (three-minute capture session)"
            : "Read your encrypted Face Unlock faces"))
        try Task.checkCancellation()
        guard generation == token else { throw EnrollmentError.expired }
        let blob = try blobs.read()
        var material = try keys.read() ?? Data()
        defer { material.resetBytes(in: 0..<material.count) }
        if material.isEmpty {
            guard blob == nil else { throw VaultError.missingKey }
            guard enrolling else { throw EnrollmentError.incomplete }
            material = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try keys.create(material)
            guard var stored = try keys.read() else { throw VaultError.missingKey }
            defer { stored.resetBytes(in: 0..<stored.count) }
            guard stored == material else { throw VaultError.invalidKey }
        }
        guard material.count == 32 else { throw VaultError.invalidKey }
        let loadedKey = SymmetricKey(data: material)
        // Authenticate existing data before replacement, but permit deliberate model upgrades.
        if let blob {
            faceCount = try decode(blob, key: loadedKey, requireCurrentModel: !enrolling).faces.count
            authorizedBlobDigest = Data(SHA256.hash(data: blob))
        } else { faceCount = 0; authorizedBlobDigest = nil }
        let time = now()
        guard time.isFinite, time >= 0 else { throw EnrollmentError.expired }
        key = loadedKey
        enrollmentSession = enrolling
        deadline = time + (enrolling ? 180 : 90)
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                if !self.sessionIsValid { self.lock(); return }
            }
        }
    }

    /// Atomic ciphertext commit. Cancellation, expiry and incomplete drafts preserve the old file.
    public func save(_ template: EnrollmentTemplate, named name: String? = nil) throws {
        try Task.checkCancellation()
        guard let key, sessionIsValid, enrollmentSession else { lock(); throw EnrollmentError.expired }
        guard template.modelIdentifier == modelIdentifier, template.format == .continuousVideo else { throw EnrollmentError.incompatible }
        let captured = try name.map { try template.editingFace(at: 0, name: $0) } ?? template
        var saved = captured
        if addingFace || replacingFace != nil {
            guard let blob = try blobs.read(), Data(SHA256.hash(data: blob)) == authorizedBlobDigest else {
                lock(); throw EnrollmentError.expired
            }
            let existing = try decode(blob, key: key, requireCurrentModel: true)
            if let replacingFace { saved = try existing.replacingFace(at: replacingFace, with: captured) }
            else { saved = try existing.adding(captured) }
        }
        try commit(saved, key: key)
    }

    /// Metadata edits are freshly authenticated and bound to the collection shown in the UI.
    public func updateFace(at index: Int, name: String? = nil, enabled: Bool? = nil,
                           remove: Bool = false, expectedRevision: Data) async throws {
        if let name { _ = try EnrollmentTemplate.validateName(name) }
        try await authorize(enrolling: false, reason: "Change your saved Face Unlock face settings")
        defer { lock() }
        try Task.checkCancellation()
        guard let key, sessionIsValid, let blob = try blobs.read(),
              Data(SHA256.hash(data: blob)) == expectedRevision else { throw EnrollmentError.expired }
        let existing = try decode(blob, key: key, requireCurrentModel: true)
        guard existing.faces.indices.contains(index) else { throw EnrollmentError.incompatible }
        if remove && existing.faces.count == 1 {
            try keys.delete(); try blobs.delete()
            hasEnrollment = false; faceCount = 0; registeredNames = []; registeredEnabled = []; metadataRevision = nil
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        } else {
            let updated = try remove ? existing.removingFace(at: index) : existing.editingFace(at: index, name: name, enabled: enabled)
            try commit(updated, key: key)
        }
    }

    private func commit(_ template: EnrollmentTemplate, key: SymmetricKey) throws {
        let payload = Payload(schema: template.format.rawValue, userID: userID, modelIdentifier: modelIdentifier,
                              pipelineIdentifier: VideoEnrollmentCollector.pipelineIdentifier,
                              policyIdentifier: VideoEnrollmentCollector.policyIdentifier,
                              vectors: template.embeddings.map(\.values),
                              additionalVectors: template.additionalFaces.isEmpty ? nil : template.additionalFaces.map { $0.map(\.values) },
                              faceNames: template.format == .managedFaces ? template.faceNames : nil,
                              faceEnabled: template.format == .managedFaces ? template.faceEnabled : nil)
        var plaintext = try JSONEncoder().encode(payload)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData)
        guard let data = sealed.combined else { throw EnrollmentError.corrupt }
        let blob = Data("FUE1".utf8) + data
        try blobs.write(blob)
        publishMetadata(template, blob: blob)
        hasEnrollment = true
        lock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func publishMetadata(_ template: EnrollmentTemplate, blob: Data) {
        faceCount = template.faces.count; registeredNames = template.faceNames; registeredEnabled = template.faceEnabled
        metadataRevision = Data(SHA256.hash(data: blob))
    }

    public func templateForVerification() throws -> EnrollmentTemplate {
        guard let key, sessionIsValid, !enrollmentSession else { lock(); throw EnrollmentError.expired }
        do {
            guard let blob = try blobs.read() else { throw EnrollmentError.incomplete }
            let template = try decode(blob, key: key, requireCurrentModel: true)
            publishMetadata(template, blob: blob)
            return template
        }
        catch { lock(); throw error }
    }

    private func decode(_ blob: Data, key: SymmetricKey, requireCurrentModel: Bool) throws -> EnrollmentTemplate {
        guard blob.count <= 750_000, blob.starts(with: Data("FUE1".utf8)) else { throw EnrollmentError.corrupt }
        var plaintext: Data
        do {
            plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: blob.dropFirst(4)),
                                         using: key, authenticating: associatedData)
        } catch { throw EnrollmentError.corrupt }
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: plaintext)
            guard let format = EnrollmentTemplate.Format(rawValue: payload.schema), payload.userID == userID else { throw EnrollmentError.corrupt }
            guard !requireCurrentModel || payload.modelIdentifier == modelIdentifier else { throw EnrollmentError.incompatible }
            if format != .legacySevenViews {
                guard payload.pipelineIdentifier == VideoEnrollmentCollector.pipelineIdentifier,
                      payload.policyIdentifier == VideoEnrollmentCollector.policyIdentifier else { throw EnrollmentError.incompatible }
            } else if requireCurrentModel { throw EnrollmentError.incompatible }
            if format == .managedFaces && (payload.faceNames == nil || payload.faceEnabled == nil) { throw EnrollmentError.corrupt }
            return try EnrollmentTemplate(embeddings: payload.vectors.map {
                try FaceEmbedding(raw: $0, modelIdentifier: payload.modelIdentifier)
            }, modelIdentifier: payload.modelIdentifier, format: format,
               additionalFaces: try (payload.additionalVectors ?? []).map { vectors in
                   try vectors.map { try FaceEmbedding(raw: $0, modelIdentifier: payload.modelIdentifier) }
               }, faceNames: payload.faceNames, faceEnabled: payload.faceEnabled)
        } catch let error as EnrollmentError { throw error }
        catch { throw EnrollmentError.corrupt }
    }

    public func delete() async throws {
        guard !busy else { throw EnrollmentError.busy }
        lock()
        let token = generation
        busy = true
        defer { busy = false; refreshPresence() }
        try await authenticator.authenticate(reason: "Delete your Face Unlock face template and its separate encryption key")
        try Task.checkCancellation()
        guard token == generation else { throw EnrollmentError.expired }
        try keys.delete()
        try blobs.delete()
        faceCount = 0; registeredNames = []; registeredEnabled = []; metadataRevision = nil
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    public func clearVisibleMetadata() {
        registeredNames = []; registeredEnabled = []; metadataRevision = nil; faceCount = nil
    }

    public func lock() {
        generation = UUID()
        authenticator.cancel()
        expiryTask?.cancel(); expiryTask = nil
        key = nil; deadline = nil; enrollmentSession = false; addingFace = false; replacingFace = nil; authorizedBlobDigest = nil
    }

    deinit { expiryTask?.cancel() }
}

private struct Payload: Codable {
    let schema: Int
    let userID: UInt32
    let modelIdentifier: String
    let pipelineIdentifier: String?
    let policyIdentifier: String?
    let vectors: [[Float]]
    let additionalVectors: [[[Float]]]?
    let faceNames: [String]?
    let faceEnabled: [Bool]?
}
