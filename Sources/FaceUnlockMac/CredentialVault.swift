import Combine
import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security
import FaceUnlockCore

public enum VaultError: Error, LocalizedError {
    case locked, canceled, missingKey, invalidKey, invalidPassword, corrupt, storage, authentication, operationCanceled
    case keychain(OSStatus)
    case experimentalConsent, missingPassword

    public var errorDescription: String? {
        switch self {
        case .locked: "Authorize the credential session first. Sessions expire after 90 seconds."
        case .canceled: "System authentication was canceled."
        case .missingKey: "Encrypted data exists but its key is missing. Nothing was overwritten."
        case .invalidKey: "The stored encryption key is invalid."
        case .invalidPassword: "Enter a nonempty password of at most 1,024 UTF-8 bytes, without control characters."
        case .corrupt: "The encrypted credential is corrupt or belongs to a different format/account."
        case .storage: "The private credential file could not be read or updated."
        case .authentication: "System authentication failed or is unavailable."
        case .operationCanceled: "The operation was canceled or the active session changed."
        case .keychain(let status): "Keychain operation failed (status \(status)). No fallback key store was used."
        case .experimentalConsent: "Acknowledge that photos or videos may unlock this Mac before enabling experimental face unlock."
        case .missingPassword: "Enter and save your Mac login password in setup before enabling face unlock."
        }
    }
}

@MainActor
protocol CredentialKeyStoring {
    func read() throws -> Data?
    func create(_ data: Data) throws
    func delete() throws
}

@MainActor
protocol CredentialBlobStoring {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

@MainActor
protocol SystemAuthenticating {
    func authenticate(reason: String) async throws
    func cancel()
}

@MainActor
final class SystemAuthenticator: SystemAuthenticating {
    private var context: LAContext?

    func authenticate(reason: String) async throws {
        let context = LAContext()
        self.context = context
        defer { context.invalidate(); self.context = nil }
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { throw VaultError.authentication }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
                throw VaultError.authentication
            }
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel: throw VaultError.canceled
            default: throw VaultError.authentication
            }
        }
    }

    func cancel() { context?.invalidate() }
}

/// Development key store: file-based login Keychain with an app-specific ACL.
/// LocalAuthentication is an APP gate, not a Keychain userPresence/Secure Enclave ACL.
@MainActor
final class DevelopmentKeyStore: CredentialKeyStoring {
    private let service: String
    private let account: String
    private let label: String

    init(service: String = "org.faceunlock.development.credential-key.v1", account: String = String(getuid()),
         label: String = "Face Unlock development encryption key") {
        self.service = service
        self.account = account
        self.label = label
    }

    private var query: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrSynchronizable as String: false
    ] }

    func read() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Never raise a Keychain prompt while locked. Development signature changes may require
        // manually restoring trust through Keychain Access; fail rather than broaden the ACL.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
        guard let data = result as? Data else { throw VaultError.invalidKey }
        return data
    }

    func create(_ data: Data) throws {
        var access: SecAccess?
        let accessStatus = SecAccessCreate(label as CFString, nil, &access)
        guard accessStatus == errSecSuccess, let access else { throw VaultError.keychain(accessStatus) }
        var query = query
        query[kSecValueData as String] = data
        query[kSecAttrAccess as String] = access
        query[kSecAttrLabel as String] = label
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let status = SecItemAdd(query as CFDictionary, nil)
        // Never update an existing key: a duplicate is an error, not a reason to destroy ciphertext.
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    func delete() throws {
        var query = query
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.keychain(status) }
    }
}

@MainActor
final class FileCredentialStore: CredentialBlobStoring {
    let directory: URL
    private let filename: String
    private var file: URL { directory.appendingPathComponent(filename) }

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("FaceUnlockDevelopment", isDirectory: true),
         filename: String = "credential-v1.enc") {
        precondition(["credential-v1.enc", "enrollment-v1.enc"].contains(filename))
        self.directory = directory
        self.filename = filename
    }

    private func validatePath(create: Bool) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            guard create else { return }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let attrs = try manager.attributesOfItem(atPath: directory.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw VaultError.storage }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if manager.fileExists(atPath: file.path) {
            let attrs = try manager.attributesOfItem(atPath: file.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw VaultError.storage }
        }
    }

    func read() throws -> Data? {
        do {
            try validatePath(create: false)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try Data(contentsOf: file)
        } catch { throw VaultError.storage }
    }

    func write(_ data: Data) throws {
        do {
            try validatePath(create: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var directory = directory
            try directory.setResourceValues(values)
            let temporary = directory.appendingPathComponent(".credential-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw VaultError.storage
            }
            // Commit only after all preparation succeeds. A failed rename preserves the old blob.
            guard rename(temporary.path, file.path) == 0 else { throw VaultError.storage }
        } catch { throw VaultError.storage }
    }

    func delete() throws {
        do {
            try validatePath(create: false)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        } catch { throw VaultError.storage }
    }
}

@MainActor
public final class CredentialVault: ObservableObject {
    public static let didChangeNotification = Notification.Name("org.faceunlock.credentialChanged")
    @Published public private(set) var isAuthorized = false
    @Published public private(set) var hasCredential = false
    @Published public private(set) var isBusy = false
    @Published public private(set) var status = "Credential session locked"
    private let keys: any CredentialKeyStoring
    private let blobs: any CredentialBlobStoring
    private let authenticator: any SystemAuthenticating
    private let now: () -> Double
    private let associatedData: Data
    private var key: SymmetricKey?
    private var lease: CredentialLease?
    private var experimentalIssuedAt: Double?
    private var authorizedBlobDigest: Data?
    private var generation = UUID()
    private var expiryTask: Task<Void, Never>?

    public convenience init() {
        self.init(keys: DevelopmentKeyStore(), blobs: FileCredentialStore(), authenticator: SystemAuthenticator())
    }

    init(keys: any CredentialKeyStoring, blobs: any CredentialBlobStoring, authenticator: any SystemAuthenticating,
         userID: UInt32 = getuid(), now: @escaping () -> Double = { ContinuousTime.now }) {
        self.keys = keys
        self.blobs = blobs
        self.authenticator = authenticator
        self.now = now
        associatedData = Data("org.faceunlock.development:credential-v1:uid=\(userID)".utf8)
        refreshPresence()
    }

    public var sessionIsValid: Bool {
        guard key != nil else { return false }
        if let issued = experimentalIssuedAt {
            let time = now()
            return issued.isFinite && issued >= 0 && time.isFinite && time >= issued
        }
        return lease?.isValid(at: now()) == true
    }

    public func refreshPresence() {
        do { hasCredential = try blobs.read() != nil }
        catch { hasCredential = false; status = VaultError.storage.localizedDescription }
        if isAuthorized && !sessionIsValid { lock() }
    }

    public func authorize() async throws {
        try await authorize(experimental: false)
    }

    public func authorizeForPasswordSetup() async throws {
        try await authorize(experimental: false, reason: "Save your Mac login password securely on this Mac for Face Unlock.")
    }

    /// Separate opt-in read session, owned by the automatic controller and revoked on disable/quit/account change.
    /// The existing manual 90-second session is unchanged. No plaintext password is cached.
    public func authorizeExperimentalFaceUnlock(acknowledgingPhotoRisk: Bool) async throws {
        guard acknowledgingPhotoRisk else { throw VaultError.experimentalConsent }
        try await authorize(experimental: true)
    }

    private func authorize(experimental: Bool, reason: String? = nil) async throws {
        guard !isBusy else { throw VaultError.operationCanceled }
        lock()
        let token = generation
        isBusy = true
        defer { isBusy = false }
        if experimental, try blobs.read() == nil { throw VaultError.missingPassword }
        try await authenticator.authenticate(reason: reason ?? (experimental
            ? "Allow experimental camera matches to enter your saved Mac password while Face Unlock is enabled. Photos or videos may also unlock this Mac."
            : "Authorize a 90-second Face Unlock development test session"))
        try Task.checkCancellation()
        guard token == generation else { throw VaultError.operationCanceled }
        var keyData = Data()
        defer { keyData.resetBytes(in: 0..<keyData.count) }
        if let existing = try keys.read() { keyData = existing }
        else {
            guard !experimental else { throw VaultError.missingKey }
            guard try blobs.read() == nil else { throw VaultError.missingKey }
            keyData = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try keys.create(keyData)
            guard var stored = try keys.read() else { throw VaultError.missingKey }
            defer { stored.resetBytes(in: 0..<stored.count) }
            guard stored == keyData else { throw VaultError.invalidKey }
        }
        guard keyData.count == 32 else { throw VaultError.invalidKey }
        key = SymmetricKey(data: keyData)
        if experimental {
            let issued = now()
            guard issued.isFinite, issued >= 0, let blob = try blobs.read() else { lock(); throw VaultError.locked }
            experimentalIssuedAt = issued
            authorizedBlobDigest = Data(SHA256.hash(data: blob))
            // Validate the authorized ciphertext once, then wipe its plaintext immediately.
            do { try withPassword { _ in } }
            catch { lock(); throw error }
            hasCredential = true
        } else { lease = CredentialLease(now: now()) }
        isAuthorized = true
        status = experimental
            ? "Experimental face unlock authorized until disabled, quit or account change. Photos/video may unlock."
            : "Authorized for 90 seconds; explicit one-shot arming is still required"
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                if !self.sessionIsValid { self.lock(); return }
            }
        }
    }

    public func lock() {
        generation = UUID()
        authenticator.cancel()
        expiryTask?.cancel()
        expiryTask = nil
        key = nil
        lease = nil
        experimentalIssuedAt = nil; authorizedBlobDigest = nil
        isAuthorized = false
        status = "Credential session locked"
    }

    public func save(_ password: Data) throws {
        guard experimentalIssuedAt == nil else { throw VaultError.locked }
        guard let key, sessionIsValid else { lock(); throw VaultError.locked }
        guard !password.isEmpty, password.count <= 1024, let string = String(data: password, encoding: .utf8),
              !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw VaultError.invalidPassword
        }
        let sealed = try AES.GCM.seal(password, using: key, authenticating: associatedData)
        guard let data = sealed.combined else { throw VaultError.corrupt }
        try blobs.write(Data("FUM1".utf8) + data)
        hasCredential = true
        status = "Password saved encrypted. Its correctness has not been verified."
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    func withPassword<T>(_ action: (Data) throws -> T) throws -> T {
        guard let key, sessionIsValid else { lock(); throw VaultError.locked }
        guard let blob = try blobs.read(), blob.starts(with: Data("FUM1".utf8)) else { throw VaultError.corrupt }
        if let authorizedBlobDigest, Data(SHA256.hash(data: blob)) != authorizedBlobDigest {
            lock(); throw VaultError.operationCanceled
        }
        var plaintext: Data
        do {
            plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: blob.dropFirst(4)), using: key, authenticating: associatedData)
        } catch { throw VaultError.corrupt }
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        return try action(plaintext)
    }

    public func delete() async throws {
        guard !isBusy else { throw VaultError.operationCanceled }
        lock()
        let token = generation
        isBusy = true
        defer { isBusy = false; refreshPresence() }
        try await authenticator.authenticate(reason: "Delete the Face Unlock stored password and encryption key")
        guard token == generation else { throw VaultError.operationCanceled }
        // If key deletion fails, leave the ciphertext untouched and report the error.
        try keys.delete()
        try blobs.delete()
        status = "Stored password and encryption key removed"
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    deinit { expiryTask?.cancel() }
}
