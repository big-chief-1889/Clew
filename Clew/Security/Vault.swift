import Foundation
import LocalAuthentication
import Security

/// Holds each wallet's database passphrase in the Keychain.
///
/// Items are bound to this Mac (never synced to iCloud) and macOS itself refuses to
/// release them without Touch ID or the login password, so an attacker who copies the
/// wallet files can't decrypt them.
enum Vault {
    enum Failure: LocalizedError {
        case keychain(OSStatus), cancelled, missing
        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
            case .cancelled: "Authentication was cancelled."
            case .missing: "This wallet's key isn't in the Keychain."
            }
        }
    }

    private static let service = "app.clew.wallet"

    /// Creates a new random passphrase and stores it under `account`, replacing any existing one.
    static func createPassphrase(account: String) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw Failure.keychain(errSecAllocate)
        }
        let passphrase = Data(bytes).base64EncodedString()

        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &accessError)
        else { throw accessError!.takeRetainedValue() as Error }

        try? deletePassphrase(account: account)
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessControl: access,
            kSecUseDataProtectionKeychain: true,
            kSecValueData: Data(passphrase.utf8),
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return passphrase
    }

    /// Asks for Touch ID (or the Mac password) once and returns a session that can read
    /// wallet passphrases without asking again, until it's dropped.
    static func startSession(reason: String) async throws -> LAContext {
        let context = LAContext()
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            throw Failure.cancelled
        }
        return context
    }

    /// Reads a passphrase. With an authenticated session this doesn't prompt; without one it asks.
    static func readPassphrase(account: String, session: LAContext?, reason: String) async throws -> String {
        let context = session ?? LAContext()
        if session == nil { context.localizedReason = reason }
        return try await Task.detached {
            var result: CFTypeRef?
            let status = SecItemCopyMatching([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecUseDataProtectionKeychain: true,
                kSecUseAuthenticationContext: context,
                kSecReturnData: true,
            ] as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
                    throw Failure.missing
                }
                return text
            case errSecUserCanceled, errSecAuthFailed: throw Failure.cancelled
            case errSecItemNotFound: throw Failure.missing
            default: throw Failure.keychain(status)
            }
        }.value
    }

    static func deletePassphrase(account: String) throws {
        let status = SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }

    /// A fresh Touch ID / password check, used before sending or revealing the seed words.
    static func confirmOwner(reason: String) async throws {
        do {
            try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            throw Failure.cancelled
        }
    }
}
