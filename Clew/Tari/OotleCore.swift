import Foundation
import TariFFI

/// An error from the Ootle side of the wallet library, with the library's own description.
struct OotleError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static let closed = OotleError(message: "The Ootle wallet was closed (Clew locked or switched wallets).")
}

/// Calls an Ootle library function that reports failure through `error_out`, throwing the
/// library's description if it does. The description is per thread, so it's read right away.
private func ootle<T>(_ call: (UnsafeMutablePointer<Int32>) -> T) throws -> T {
    var code: Int32 = 0
    let result = call(&code)
    if code != 0 {
        let pointer = clew_last_error()
        defer { clew_string_destroy(pointer) }
        throw OotleError(message: pointer.map { String(cString: $0) } ?? "Ootle error \(code)")
    }
    return result
}

/// One entry in the TARI history.
struct OotleEntry: Identifiable, Equatable, Decodable {
    let id: Int32
    /// µT; negative when funds left the account (fee included).
    let change: Int64
    /// µT, on outgoing entries.
    let fee: UInt64?
    let time: Int64

    var date: Date { Date(timeIntervalSince1970: TimeInterval(time)) }
    var isOutbound: Bool { change < 0 }
    var amount: MicroTari { change.magnitude }
}

/// XTM moved (burnt) from the main wallet to this TARI account, and how far it has got.
struct OotleMove: Equatable, Decodable {
    enum Status: String, Decodable {
        /// Being confirmed on Tari's main chain.
        case confirming
        /// Confirmed; waiting until Ootle accepts the claim (about a day after the move).
        case waiting
        case claimed
    }
    /// µT of XTM.
    let amount: MicroTari
    let time: Int64
    let status: Status

    var date: Date { Date(timeIntervalSince1970: TimeInterval(time)) }
}

/// Owns one running Ootle (Tari layer 2) wallet. Its keys come from the main wallet's seed: the
/// real ones on Ootle's mainnet, separate test keys on its testnet (see clew-core). Every call
/// blocks, most of them on the network, so call it off the main thread.
final class OotleCore {
    private let handle: OpaquePointer

    /// Opens (or creates) the Ootle wallet in `directory` for the open main wallet `l1`.
    init(l1: WalletCore, directory: URL, network: String, indexerURL: String, password: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let opened = try l1.using { l1Handle in
            try ootle { clew_ootle_open(l1Handle, directory.path, network, indexerURL, password, $0) }
        }
        guard let opened else { throw OotleError(message: "Couldn't open the Ootle wallet.") }
        handle = opened
    }

    /// Routes Ootle traffic through a SOCKS proxy (nil = direct). Unlike the main wallet, an open
    /// Ootle wallet keeps the route it opened with, so reopen it after changing this.
    static func setProxy(_ url: String?) throws {
        _ = try ootle { clew_ootle_set_proxy(url, $0) }
    }

    // The same guard as WalletCore: shutdown waits for calls in progress, and nothing starts after.
    private let gate = NSCondition()
    private var callsInFlight = 0
    private var isShutDown = false

    private func using<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        gate.lock()
        guard !isShutDown else { gate.unlock(); throw OotleError.closed }
        callsInFlight += 1
        gate.unlock()
        defer {
            gate.lock()
            callsInFlight -= 1
            gate.broadcast()
            gate.unlock()
        }
        return try body(handle)
    }

    /// Stops the wallet and frees it, after any call in progress finishes (which may be waiting on
    /// the network). Never run it on the main thread.
    func shutdown() {
        gate.lock()
        guard !isShutDown else { gate.unlock(); return }
        isShutDown = true
        while callsInFlight > 0 { gate.wait() }
        gate.unlock()
        clew_ootle_close(handle)
    }

    deinit { shutdown() }

    /// The address others pay TARI to (`otl_…`).
    var address: String {
        get throws {
            try using { handle in
                let pointer = try ootle { clew_ootle_address(handle, $0) }
                defer { clew_string_destroy(pointer) }
                return pointer.map { String(cString: $0) } ?? ""
            }
        }
    }

    var balance: MicroTari {
        get throws { try using { handle in try ootle { clew_ootle_balance(handle, $0) } } }
    }

    /// Checks the account with the network and scans for payments to it.
    func refresh() throws {
        _ = try using { handle in try ootle { clew_ootle_refresh(handle, $0) } }
    }

    /// Newest first.
    func history(limit: UInt32 = 200) throws -> [OotleEntry] {
        struct Page: Decodable { let entries: [OotleEntry] }
        return try using { handle in
            let pointer = try ootle { clew_ootle_history(handle, 0, limit, $0) }
            defer { clew_string_destroy(pointer) }
            guard let pointer else { return [] }
            return try JSONDecoder().decode(Page.self, from: Data(String(cString: pointer).utf8)).entries
        }
    }

    /// Claims the testnet's free 1,000 tTARI. Returns the fee paid.
    @discardableResult
    func claimFaucet() throws -> MicroTari {
        try using { handle in try ootle { clew_ootle_claim_faucet(handle, $0) } }
    }

    /// The exact fee for sending `amount` to `address`, from trial runs on the network.
    func estimateSendFee(to address: String, amount: MicroTari) throws -> MicroTari {
        try using { handle in try ootle { clew_ootle_estimate_send_fee(handle, address, amount, $0) } }
    }

    /// The smallest move from XTM, in µT: comfortably above what claiming it costs.
    static var minimumMove: MicroTari { clew_ootle_min_burn() }

    /// Burns `amount` of XTM from the main wallet `l1` to this account, at `feePerGram`. One way:
    /// the XTM can't come back. Refused when the two wallets are on different networks.
    func moveFromMainWallet(_ l1: WalletCore, amount: MicroTari, feePerGram: MicroTari) throws {
        guard feePerGram <= FeeTiers.maximumRate else { throw OotleError(message: "That fee rate is too high.") }
        _ = try using { handle in
            try l1.using { l1Handle in
                try ootle { clew_ootle_burn_from_l1(handle, l1Handle, amount, feePerGram, $0) }
            }
        }
    }

    /// The main wallet's moves, read in a quick local step, so what follows doesn't hold it while
    /// waiting on the network.
    private func snapshot(of l1: WalletCore) throws -> OpaquePointer {
        let snapshot = try l1.using { l1Handle in try ootle { clew_burn_snapshot(l1Handle, $0) } }
        guard let snapshot else { throw OotleError(message: "Couldn't read the moves.") }
        return snapshot
    }

    /// Moves from `l1` to this account, newest first. Reads local data only.
    func moves(from l1: WalletCore) throws -> [OotleMove] {
        let snapshot = try snapshot(of: l1)
        defer { clew_burn_snapshot_destroy(snapshot) }
        return try using { handle in
            let pointer = try ootle { clew_ootle_burns(handle, snapshot, $0) }
            defer { clew_string_destroy(pointer) }
            guard let pointer else { return [] }
            return try JSONDecoder().decode([OotleMove].self, from: Data(String(cString: pointer).utf8))
        }
    }

    /// Claims every move Ootle accepts now. Returns how many were claimed, and why one couldn't be
    /// (the others are still tried).
    func claimMoves(from l1: WalletCore) throws -> (claimed: Int, problem: String?) {
        let snapshot = try snapshot(of: l1)
        defer { clew_burn_snapshot_destroy(snapshot) }
        return try using { handle in
            var code: Int32 = 0
            let claimed = clew_ootle_claim_burns(handle, snapshot, nil, &code)
            var problem: String?
            if code != 0 {
                let pointer = clew_last_error()
                defer { clew_string_destroy(pointer) }
                problem = pointer.map { String(cString: $0) } ?? "Ootle error \(code)"
            }
            if claimed < 0 { throw OotleError(message: problem ?? "Couldn't claim.") }
            return (Int(claimed), problem)
        }
    }

    enum SendResult: Sendable {
        /// The network confirmed it, charging this fee.
        case confirmed(fee: MicroTari)
        /// Sent, but not confirmed yet. The wallet keeps trying and the funds stay locked: it must not
        /// be sent again.
        case pending
    }

    /// Sends privately, paying at most `maxFee`. Returns once the network has confirmed it, or once
    /// it's clear that will take longer.
    func send(to address: String, amount: MicroTari, maxFee: MicroTari) throws -> SendResult {
        try using { handle in
            var pending = false
            let fee = try ootle { clew_ootle_send(handle, address, amount, maxFee, &pending, $0) }
            return pending ? .pending : .confirmed(fee: fee)
        }
    }
}
