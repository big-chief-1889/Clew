import Foundation
import TariFFI

/// An error reported by the Tari library through its `int *error_out` parameter.
struct TariError: LocalizedError, Equatable {
    let code: Int32

    /// Not from the library: the wallet was already closed (locked or switched) when it was used.
    static let closed = TariError(code: -2)
    /// Not from the library: the password didn't open the wallet.
    static let wrongPassword = TariError(code: -3)

    /// Only the library's "invalid passphrase" (428) means the password was wrong. Other decryption
    /// errors (420, 423, 429) can have other causes, so they're never taken as a wrong password.
    var isWrongPassword: Bool { code == -3 || code == 428 }

    var errorDescription: String? {
        switch code {
        case -2: "This wallet was closed (Clew locked or switched wallets). Nothing was sent."
        case -3: "That password isn't right."
        case 101: "Not enough funds for this amount plus the fee."
        case 115: "Funds are still pending. Wait for incoming transactions to confirm."
        case 428: "That password isn't right."
        case 420, 423, 429: "The wallet couldn't be decrypted (error \(code))."
        default: "Wallet error \(code)."
        }
    }
}

/// Calls a library function that reports failure through `error_out`, throwing if it does.
func ffi<T>(_ call: (UnsafeMutablePointer<Int32>) -> T) throws -> T {
    var code: Int32 = 0
    let result = call(&code)
    if code != 0 { throw TariError(code: code) }
    return result
}

/// Copies a string the library allocated, then frees it.
func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
    guard let pointer else { return "" }
    defer { string_destroy(pointer) }
    return String(cString: pointer)
}

/// Copies a library-allocated ByteVector into Swift, then frees it.
func takeBytes(_ vector: OpaquePointer?) throws -> [UInt8] {
    guard let vector else { return [] }
    defer { byte_vector_destroy(vector) }
    let count = try ffi { byte_vector_get_length(vector, $0) }
    return try (0..<count).map { index in try ffi { byte_vector_get_at(vector, index, $0) } }
}
