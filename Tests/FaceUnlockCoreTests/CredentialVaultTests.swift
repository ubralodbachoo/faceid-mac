import Foundation
import XCTest
@testable import FaceUnlockMac

@MainActor
private final class MemoryKeys: CredentialKeyStoring {
    var value: Data?
    var creates = 0
    var failDelete = false
    func read() throws -> Data? { value }
    func create(_ data: Data) throws {
        guard value == nil else { throw VaultError.invalidKey }
        value = data
        creates += 1
    }
    func delete() throws {
        if failDelete { throw VaultError.storage }
        value = nil
    }
}

@MainActor
private final class MemoryBlobs: CredentialBlobStoring {
    var value: Data?
    var failWrite = false
    func read() throws -> Data? { value }
    func write(_ data: Data) throws {
        if failWrite { throw VaultError.storage }
        value = data
    }
    func delete() throws { value = nil }
}

@MainActor
private final class TestAuthenticator: SystemAuthenticating {
    var fail = false
    var action: (() -> Void)?
    var calls = 0
    func authenticate(reason: String) async throws {
        calls += 1
        action?()
        if fail { throw VaultError.canceled }
    }
    func cancel() {}
}

final class CredentialVaultTests: XCTestCase {
    @MainActor
    func testEncryptedSaveReplacementRestartAndDeletion() async throws {
        let keys = MemoryKeys(), blobs = MemoryBlobs(), auth = TestAuthenticator()
        let vault = CredentialVault(keys: keys, blobs: blobs, authenticator: auth)
        XCTAssertThrowsError(try vault.save(Data("synthetic-password".utf8)))
        try await vault.authorize()
        try vault.save(Data("synthetic-password".utf8))
        XCTAssertTrue(blobs.value!.starts(with: Data("FUM1".utf8)))
        XCTAssertNil(blobs.value!.range(of: Data("synthetic-password".utf8)))
        XCTAssertEqual(try vault.withPassword { $0 }, Data("synthetic-password".utf8))
        try vault.save(Data("replacement".utf8))
        vault.lock()
        XCTAssertThrowsError(try vault.withPassword { $0 })
        let restarted = CredentialVault(keys: keys, blobs: blobs, authenticator: auth)
        XCTAssertFalse(restarted.sessionIsValid)
        XCTAssertTrue(restarted.hasCredential)
        try await restarted.authorize()
        XCTAssertEqual(try restarted.withPassword { $0 }, Data("replacement".utf8))
        try await restarted.delete()
        XCTAssertNil(keys.value)
        XCTAssertNil(blobs.value)
        XCTAssertFalse(restarted.hasCredential)
        XCTAssertFalse(restarted.sessionIsValid)
        XCTAssertEqual(keys.creates, 1)
    }

    @MainActor
    func testCancellationAndLateAuthenticationCannotCreateOrExposeKey() async throws {
        let keys = MemoryKeys(), blobs = MemoryBlobs(), auth = TestAuthenticator()
        let vault = CredentialVault(keys: keys, blobs: blobs, authenticator: auth)
        auth.fail = true
        do { try await vault.authorize(); XCTFail("Canceled auth must throw") } catch {}
        XCTAssertNil(keys.value)
        XCTAssertFalse(vault.sessionIsValid)
        auth.fail = false
        auth.action = { vault.lock() }
        do { try await vault.authorize(); XCTFail("Late auth must throw") } catch {}
        XCTAssertNil(keys.value)
        XCTAssertFalse(vault.sessionIsValid)
    }

    @MainActor
    func testMissingKeyWithExistingCiphertextNeverRegeneratesKey() async throws {
        let keys = MemoryKeys(), blobs = MemoryBlobs(), auth = TestAuthenticator()
        blobs.value = Data("old-encrypted-archive".utf8)
        let original = blobs.value
        let vault = CredentialVault(keys: keys, blobs: blobs, authenticator: auth)
        do { try await vault.authorize(); XCTFail("Missing key must throw") } catch {}
        XCTAssertEqual(keys.creates, 0)
        XCTAssertEqual(blobs.value, original)
        XCTAssertFalse(vault.sessionIsValid)
    }

    @MainActor
    func testTamperingAndDifferentAccountCannotDecrypt() async throws {
        let keys = MemoryKeys(), blobs = MemoryBlobs(), auth = TestAuthenticator()
        let vault = CredentialVault(keys: keys, blobs: blobs, authenticator: auth, userID: 501)
        try await vault.authorize()
        try vault.save(Data("synthetic".utf8))
        let original = blobs.value!
        blobs.value![blobs.value!.count - 1] ^= 1
        XCTAssertThrowsError(try vault.withPassword { $0 })
        blobs.value = original
        let other = CredentialVault(keys: keys, blobs: blobs, authenticator: auth, userID: 502)
        try await other.authorize()
        XCTAssertThrowsError(try other.withPassword { $0 })
        vault.lock(); other.lock()
    }

    @MainActor
    func testFailedReplacementOrDeletionPreservesExistingCredential() async throws {
        let keys = MemoryKeys(), blobs = MemoryBlobs(), auth = TestAuthenticator()
        let vault = CredentialVault(keys: keys, blobs: blobs, authenticator: auth)
        try await vault.authorize()
        try vault.save(Data("existing".utf8))
        blobs.failWrite = true
        XCTAssertThrowsError(try vault.save(Data("new".utf8)))
        XCTAssertEqual(try vault.withPassword { $0 }, Data("existing".utf8))
        keys.failDelete = true
        do { try await vault.delete(); XCTFail("Deletion failure must throw") } catch {}
        XCTAssertNotNil(keys.value)
        XCTAssertNotNil(blobs.value)
        auth.fail = true
        do { try await vault.delete(); XCTFail("Canceled deletion must throw") } catch {}
        XCTAssertNotNil(keys.value)
        XCTAssertNotNil(blobs.value)
    }

    @MainActor
    func testLeaseExpiryAndInvalidPasswordsCannotBeUsed() async throws {
        var time = 100.0
        let keys = MemoryKeys(), blobs = MemoryBlobs(), auth = TestAuthenticator()
        let vault = CredentialVault(keys: keys, blobs: blobs, authenticator: auth, now: { time })
        try await vault.authorize()
        for invalid in [Data(), Data("line\nbreak".utf8), Data([0xff]), Data(repeating: 65, count: 1025)] {
            XCTAssertThrowsError(try vault.save(invalid))
        }
        try vault.save(Data("valid".utf8))
        time = 190
        XCTAssertFalse(vault.sessionIsValid)
        XCTAssertThrowsError(try vault.withPassword { $0 })
        XCTAssertFalse(vault.isAuthorized)
    }

    @MainActor
    func testPrivateFileStorageAndSymlinkRejection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("vault")
        let store = FileCredentialStore(directory: directory)
        XCTAssertNil(try store.read())
        try store.write(Data("synthetic-ciphertext".utf8))
        XCTAssertEqual(try store.read(), Data("synthetic-ciphertext".utf8))
        let file = directory.appendingPathComponent("credential-v1.enc")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        try store.delete()
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: directory)
        XCTAssertThrowsError(try store.read())
        XCTAssertThrowsError(try store.write(Data("must-not-follow-link".utf8)))
    }

    @MainActor
    func testOptInRealKeychainRoundTripUsesDisposableSyntheticKeyOnly() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FACEUNLOCK_RUN_KEYCHAIN_TEST"] == "1", "Real Keychain test is opt-in")
        let store = DevelopmentKeyStore(service: "org.faceunlock.test.\(UUID().uuidString)", account: "synthetic-key")
        defer { try? store.delete() }
        XCTAssertNil(try store.read())
        let data = Data(repeating: 42, count: 32)
        try store.create(data)
        XCTAssertEqual(try store.read(), data)
        XCTAssertThrowsError(try store.create(Data(repeating: 43, count: 32)))
        XCTAssertEqual(try store.read(), data)
        try store.delete()
        XCTAssertNil(try store.read())
    }
}
