import CryptoKit
import Foundation
import LocalAuthentication

/// Optional shortcut: unlock (and confirm actions) with Touch ID instead of typing the password.
///
/// The password is encrypted to a key that lives in this Mac's Secure Enclave and is only usable
/// after a Touch ID fingerprint (not the Mac's login password). Only the encrypted password and an opaque reference
/// to that key are saved, so the file is useless on any other Mac. Needs no Keychain and no
/// developer certificate. The password itself still protects the wallet files.
enum TouchIDShortcut {
    enum Failure: LocalizedError {
        case unavailable, cancelled, stale
        var errorDescription: String? {
            switch self {
            case .unavailable: "Touch ID isn't available on this Mac."
            case .cancelled: "Touch ID was cancelled."
            case .stale: "The Touch ID shortcut is out of date. Turn it off and on again in settings."
            }
        }
    }

    private struct Stored: Codable {
        let key: Data              // Secure Enclave key reference (only works on this Mac)
        let ephemeralPublic: Data  // the other half of the key agreement
        let sealed: Data           // the password, AES-GCM encrypted with the agreed key
    }

    static var isAvailable: Bool { SecureEnclave.isAvailable }

    static var isEnabled: Bool {
        (try? file()).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// Turns the shortcut on for `password`.
    static func enable(password: String) throws {
        guard isAvailable else { throw Failure.unavailable }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryAny], &error)
        else { throw error!.takeRetainedValue() as Error }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        try store(password: password, key: key.dataRepresentation, publicKey: key.publicKey)
    }

    /// Re-encrypts a new password to the same key, e.g. after a password change. Encrypting only
    /// needs the public half, so this doesn't prompt.
    static func update(password: String) throws {
        let stored = try load()
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: stored.key)
        try store(password: password, key: stored.key, publicKey: key.publicKey)
    }

    static func disable() {
        if let file = try? file() { try? FileManager.default.removeItem(at: file) }
    }

    /// Asks for Touch ID and returns the Clew password.
    static func password(reason: String) async throws -> String {
        let stored = try load()
        let context = LAContext()
        context.localizedReason = reason
        // The Secure Enclave call blocks while macOS shows its prompt; keep it off the main thread.
        return try await Task.detached {
            do {
                let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                    dataRepresentation: stored.key, authenticationContext: context)
                let peer = try P256.KeyAgreement.PublicKey(rawRepresentation: stored.ephemeralPublic)
                let symmetric = try key.sharedSecretFromKeyAgreement(with: peer)
                    .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("clew-touch-id".utf8),
                                             sharedInfo: stored.ephemeralPublic, outputByteCount: 32)
                let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: stored.sealed), using: symmetric)
                guard let password = String(data: plain, encoding: .utf8) else { throw Failure.stale }
                return password
            } catch {
                let ns = error as NSError
                let cancelCodes = [LAError.userCancel, .appCancel, .systemCancel].map(\.rawValue)
                if ns.domain == LAErrorDomain && cancelCodes.contains(ns.code) { throw Failure.cancelled }
                throw error
            }
        }.value
    }

    private static func store(password: String, key: Data, publicKey: P256.KeyAgreement.PublicKey) throws {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let symmetric = try ephemeral.sharedSecretFromKeyAgreement(with: publicKey)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("clew-touch-id".utf8),
                                     sharedInfo: ephemeral.publicKey.rawRepresentation, outputByteCount: 32)
        guard let sealed = try AES.GCM.seal(Data(password.utf8), using: symmetric).combined else {
            throw Failure.unavailable
        }
        let data = try JSONEncoder().encode(Stored(key: key, ephemeralPublic: ephemeral.publicKey.rawRepresentation,
                                                   sealed: sealed))
        try data.write(to: try file(), options: [.atomic, .completeFileProtection])
    }

    private static func load() throws -> Stored {
        guard let data = try? Data(contentsOf: try file()) else { throw Failure.unavailable }
        return try JSONDecoder().decode(Stored.self, from: data)
    }

    /// One per network, next to that network's wallets.
    private static func file() throws -> URL {
        try WalletStore.networkDirectory().appendingPathComponent("touch-id.json")
    }
}
