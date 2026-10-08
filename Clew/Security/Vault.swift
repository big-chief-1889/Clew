import Foundation
import LocalAuthentication
import Security

/// Reads the Keychain keys that wallets made before passwords (Clew 0.6 and earlier) were
/// encrypted with, so they can be switched to the password once, and then deletes them.
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
}
