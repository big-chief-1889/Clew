import Foundation
import TariFFI

/// Tari addresses as text: base58 of the network byte, the features byte, then the rest,
/// concatenated. This mirrors `TariAddress::to_base58` in the Tari source.
enum TariAddress {
    static func base58(fromAddressPointer address: OpaquePointer) throws -> String {
        let bytes = try takeBytes(try ffi { tari_address_get_bytes(address, $0) })
        guard bytes.count > 2 else { throw TariError(code: -1) }
        return Base58.encode([bytes[0]]) + Base58.encode([bytes[1]]) + Base58.encode(Array(bytes[2...]))
    }

    /// The network byte of an address (mainnet, testnet…), or nil if the text isn't an address.
    static func network(of text: String) -> UInt8? {
        var code: Int32 = 0
        guard let address = tari_address_from_base58(text, &code), code == 0 else { return nil }
        defer { tari_address_destroy(address) }
        let network = tari_address_network_u8(address, &code)
        return code == 0 ? network : nil
    }
}

enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    static func encode(_ bytes: [UInt8]) -> String {
        var digits: [Int] = []  // base-58 digits, least significant first
        for byte in bytes {
            var carry = Int(byte)
            for i in digits.indices {
                carry += digits[i] << 8
                digits[i] = carry % 58
                carry /= 58
            }
            while carry > 0 {
                digits.append(carry % 58)
                carry /= 58
            }
        }
        let leadingZeros = bytes.prefix { $0 == 0 }.count
        return String(repeating: "1", count: leadingZeros) + String(digits.reversed().map { alphabet[$0] })
    }
}
