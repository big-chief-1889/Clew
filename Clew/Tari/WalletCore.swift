import Foundation
import TariFFI

/// 1 XTM = 1,000,000 µT (micro-Tari). The library works in µT throughout.
typealias MicroTari = UInt64

enum WalletEvent {
    case changed                       // balance or transactions may have changed
    case connectivity(Connectivity)
    case scannedHeight(UInt64)
}

enum Connectivity: UInt64 {
    case connecting = 0, online = 1, offline = 2, degraded = 3
}

struct Balance: Equatable {
    var available: MicroTari = 0
    var pendingIncoming: MicroTari = 0
    var pendingOutgoing: MicroTari = 0
    var timeLocked: MicroTari = 0
}

struct WalletTransaction: Identifiable, Equatable {
    enum Status { case pending, broadcast, confirming, confirmed, locked, rejected, cancelled }

    let id: UInt64
    let amount: MicroTari
    let fee: MicroTari
    let isOutbound: Bool
    let date: Date
    let status: Status
    let counterparty: String?   // base58 address, nil when the library doesn't know it
    let note: String
    let minedHeight: UInt64?    // block the transaction is in, nil until mined
    let lockHeight: UInt64      // block from which its funds can be spent (0 = no lock)
}

/// Proof that a payment happened: a reference the other party can look up in their own wallet.
struct PaymentRecord: Equatable {
    let reference: String       // 64 hex characters
    let amount: MicroTari
    let blockHeight: UInt64
    let isOutbound: Bool
}

/// Fee rates in µT per gram (a gram is Tari's unit of transaction size).
struct FeeTiers: Equatable {
    var economy: MicroTari
    var normal: MicroTari
    var fast: MicroTari
    var networkBusy: Bool       // false when everything waiting fits in the next block

    /// Used when the node can't be asked. Same default as the official Aurora wallet.
    static let fallback = FeeTiers(economy: 5, normal: 10, fast: 10, networkBusy: false)

    /// Highest rate Clew will pay, whatever the node reports: 10× the standard rate, about
    /// 0.015 XTM for a typical send. Stops a dishonest or broken node from inflating fees.
    static let maximumRate: MicroTari = 100
}

/// Owns one running Tari wallet. All library memory is freed here, nowhere else.
final class WalletCore {
    private let handle: OpaquePointer
    private let dbConfig: OpaquePointer
    private let events: EventSink

    /// Opens the wallet in `directory`, creating it if it doesn't exist.
    /// Pass `seedWords` only when restoring an existing wallet.
    init(directory: URL, passphrase: String, seedWords: [String]?, network: String, nodeURL: String,
         onEvent: @escaping (WalletEvent) -> Void) throws {
        events = EventSink(onEvent)
        guard let config = try ffi({ wallet_db_config_create("clew", directory.path, $0) }) else {
            throw TariError(code: -1)
        }
        dbConfig = config
        var opened = false
        defer { if !opened { wallet_db_config_destroy(config) } }

        var seeds: OpaquePointer?
        if let seedWords { seeds = try SeedWords.make(seedWords) }
        defer { if let seeds { seed_words_destroy(seeds) } }

        var recovering = false
        let context = Unmanaged.passUnretained(events).toOpaque()

        // The library calls these from its own threads. Pointers it hands us are ours to free.
        let created: OpaquePointer?
        do {
            created = try ffi { error in
                wallet_create(
                    // No log path: the library sets up no logger, so it writes no log file at all.
                    context, config, nil, 0, 0, 0,
                    passphrase, nil, seeds, network, nodeURL, 0,
                    { ctx, tx in pending_inbound_transaction_destroy(tx); EventSink.from(ctx)?.send(.changed) },
                    { ctx, tx in completed_transaction_destroy(tx); EventSink.from(ctx)?.send(.changed) },
                    { ctx, tx in completed_transaction_destroy(tx); EventSink.from(ctx)?.send(.changed) },
                    { ctx, tx in completed_transaction_destroy(tx); EventSink.from(ctx)?.send(.changed) },
                    { ctx, tx in completed_transaction_destroy(tx); EventSink.from(ctx)?.send(.changed) },
                    { ctx, tx, _ in completed_transaction_destroy(tx); EventSink.from(ctx)?.send(.changed) },
                    { ctx, tx in completed_transaction_destroy(tx); EventSink.from(ctx)?.send(.changed) },
                    { ctx, tx, _ in completed_transaction_destroy(tx); EventSink.from(ctx)?.send(.changed) },
                    { ctx, _, status in transaction_send_status_destroy(status); EventSink.from(ctx)?.send(.changed) },
                    { ctx, tx, _ in completed_transaction_destroy(tx); EventSink.from(ctx)?.send(.changed) },
                    { ctx, _, _ in EventSink.from(ctx)?.send(.changed) },
                    { ctx, balance in balance_destroy(balance); EventSink.from(ctx)?.send(.changed) },
                    { ctx, _, _ in EventSink.from(ctx)?.send(.changed) },
                    { ctx, status, _ in
                        EventSink.from(ctx)?.send(.connectivity(Connectivity(rawValue: status) ?? .offline))
                    },
                    { ctx, height in EventSink.from(ctx)?.send(.scannedHeight(height)) },
                    { _, _ in },  // base node state: the library offers no destructor for it
                    &recovering, error)
            }
        } catch {
            throw seedWords == nil ? error : Self.restoreError(error)
        }
        guard let created else { throw TariError(code: -1) }
        handle = created
        opened = true
    }

    /// `wallet_create` reports a bad recovery phrase (e.g. a wrong last word, which fails the
    /// checksum) as a cipher error.
    private static func restoreError(_ error: Error) -> Error {
        if let error = error as? TariError, (429...432).contains(error.code) { return SeedWords.Problem.invalidPhrase }
        return error
    }

    /// Changes the password of a wallet that isn't open, without starting it (so nothing goes
    /// online). A wrong `old` password changes nothing and throws `TariError.wrongPassword`.
    /// Changing to the same password is a cheap way to check a password. Slow (deliberately), so
    /// call it off the main thread.
    static func changePassword(directory: URL, from old: String, to new: String) throws {
        guard let config = try ffi({ wallet_db_config_create("clew", directory.path, $0) }) else {
            throw TariError(code: -1)
        }
        defer { wallet_db_config_destroy(config) }
        do {
            _ = try ffi { wallet_change_passphrase(config, old, new, $0) }
        } catch let error as TariError where error.isWrongPassword {
            throw TariError.wrongPassword
        }
    }

    /// Routes all wallet network traffic through a SOCKS proxy (nil = direct). The library makes a
    /// new connection client for each request, so this applies to running wallets from their next
    /// request. If the proxy is unreachable, the wallet goes offline instead of bypassing it.
    static func setProxy(_ url: String?) throws {
        _ = try ffi { wallet_set_http_proxy(url, $0) }
    }

    // Calls into the wallet can come from several threads (the main thread, plus background tasks
    // for slow network questions like fees). `shutdown` frees the wallet, so it must wait until no
    // call is using it, and nothing may start afterwards.
    private let gate = NSCondition()
    private var callsInFlight = 0
    private var isShutDown = false

    /// Runs `body` with the wallet guaranteed to stay alive. Throws `.closed` after shutdown.
    private func using<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        gate.lock()
        guard !isShutDown else { gate.unlock(); throw TariError.closed }
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

    /// Stops the wallet's services and frees it, after any calls in progress finish. Can take a
    /// while (a call may be waiting on the network), so never run it on the main thread.
    func shutdown() {
        gate.lock()
        guard !isShutDown else { gate.unlock(); return }
        isShutDown = true
        while callsInFlight > 0 { gate.wait() }
        gate.unlock()
        wallet_destroy(handle)
        wallet_db_config_destroy(dbConfig)
    }

    deinit { shutdown() }

    var seedWords: [String] {
        get throws {
            try using { handle in
                let seeds = try ffi { wallet_get_seed_words(handle, $0) }
                defer { seed_words_destroy(seeds) }
                let count = try ffi { seed_words_get_length(seeds, $0) }
                return try (0..<count).map { i in takeString(try ffi { seed_words_get_at(seeds, i, $0) }) }
            }
        }
    }

    /// The one-sided (stealth) address others send to.
    var address: String {
        get throws {
            try using { handle in
                let address = try ffi { wallet_get_tari_one_sided_address(handle, $0) }
                defer { tari_address_destroy(address) }
                guard let address else { throw TariError(code: -1) }
                return try TariAddress.base58(fromAddressPointer: address)
            }
        }
    }

    var balance: Balance {
        get throws {
            try using { handle in
                let pointer = try ffi { wallet_get_balance(handle, $0) }
                defer { balance_destroy(pointer) }
                return Balance(
                    available: try ffi { balance_get_available(pointer, $0) },
                    pendingIncoming: try ffi { balance_get_pending_incoming(pointer, $0) },
                    pendingOutgoing: try ffi { balance_get_pending_outgoing(pointer, $0) },
                    timeLocked: try ffi { balance_get_time_locked(pointer, $0) })
            }
        }
    }

    /// Everything to show in history, newest first: payments still on their way (the library keeps
    /// sent-but-unmined payments out of its "completed" list), completed ones, and cancelled ones.
    var transactions: [WalletTransaction] {
        get throws {
            try using { handle in
                let completed = try ffi { wallet_get_completed_transactions(handle, 500, $0) }
                defer { completed_transactions_destroy(completed) }
                let cancelled = try ffi { wallet_get_cancelled_transactions(handle, 100, $0) }
                defer { completed_transactions_destroy(cancelled) }
                let outgoing = try ffi { wallet_get_pending_outbound_transactions(handle, 200, $0) }
                defer { pending_outbound_transactions_destroy(outgoing) }
                let incoming = try ffi { wallet_get_pending_inbound_transactions(handle, 200, $0) }
                defer { pending_inbound_transactions_destroy(incoming) }
                let all = try Self.read(completed, cancelled: false) + Self.read(cancelled, cancelled: true)
                    + Self.readPendingOutbound(outgoing) + Self.readPendingInbound(incoming)
                // A transaction can briefly appear in two lists while its state changes; keep one.
                var seen = Set<UInt64>()
                return all.filter { seen.insert($0.id).inserted }.sorted { $0.date > $1.date }
            }
        }
    }

    func estimateFee(amount: MicroTari, feePerGram: MicroTari) throws -> MicroTari {
        try using { handle in
            try ffi { wallet_get_fee_estimate(handle, amount, nil, feePerGram, 1, 2, $0) }
        }
    }

    /// Sends a one-sided payment. Returns the transaction id.
    @discardableResult
    func send(amount: MicroTari, to recipient: String, note: String, feePerGram: MicroTari) throws -> UInt64 {
        guard feePerGram <= FeeTiers.maximumRate else { throw TariError(code: -1) }
        return try using { handle in
            let destination = try ffi { tari_address_from_base58(recipient, $0) }
            defer { tari_address_destroy(destination) }
            let id = try ffi { wallet_send_transaction(handle, destination, amount, nil, feePerGram, note, $0) }
            if id == 0 { throw TariError(code: -1) }
            return id
        }
    }

    /// Prices Economy / Normal / Fast from the node's queue of waiting transactions. Asks the node,
    /// so call it off the main thread.
    ///
    /// The node reports the lowest, average and highest fee rate of the transactions it would put
    /// in the next block (the library passes on only that block, even if more are requested).
    /// If even the cheapest of those pays less than our standard rate, the standard rate is already
    /// ahead of the queue and the network counts as quiet. Rates are capped at `maximumRate`.
    func feeTiers() throws -> FeeTiers {
        try using { handle in
            let stats = try ffi { wallet_get_fee_per_gram_stats(handle, 1, $0) }
            defer { fee_per_gram_stats_destroy(stats) }
            guard try ffi({ fee_per_gram_stats_get_length(stats, $0) }) > 0 else { return .fallback }
            let stat = try ffi { fee_per_gram_stats_get_at(stats, 0, $0) }
            defer { fee_per_gram_stat_destroy(stat) }
            let lowest = try ffi { fee_per_gram_stat_get_min_fee_per_gram(stat, $0) }
            let highest = try ffi { fee_per_gram_stat_get_max_fee_per_gram(stat, $0) }

            let base = FeeTiers.fallback
            guard lowest >= base.normal else { return base }
            let cap = { (rate: MicroTari) in min(rate, FeeTiers.maximumRate) }
            return FeeTiers(
                economy: cap(lowest),                       // matches the cheapest transaction getting in now
                normal: cap(lowest + 1),                    // just ahead of it
                fast: cap(max(highest + 1, lowest + 1)),    // ahead of everyone waiting
                networkBusy: true)
        }
    }

    /// Payment references for a mined transaction (empty until it's in a block). Reads local data.
    func paymentRecords(for transactionID: UInt64) throws -> [PaymentRecord] {
        try using { handle in
            let records = try ffi { wallet_get_transaction_payrefs(handle, transactionID, $0) }
            defer { payment_records_destroy(records) }
            let count = try ffi { payment_records_get_length(records, $0) }
            return try (0..<count).compactMap { i in
                guard let record = try ffi({ payment_records_get_at(records, i, $0) }) else { return nil }
                defer { payment_record_destroy(record) }
                let bytes = withUnsafeBytes(of: record.pointee.payment_reference) { Array($0) }
                return PaymentRecord(
                    reference: bytes.map { String(format: "%02x", $0) }.joined(),
                    amount: record.pointee.amount,
                    blockHeight: record.pointee.block_height,
                    isOutbound: record.pointee.direction == 1)
            }
        }
    }

    var confirmationsRequired: UInt64 {
        (try? using { handle in try ffi { wallet_get_num_confirmations_required(handle, $0) } }) ?? 3
    }

    /// Re-checks every coin and transaction with the node, then re-reads the blockchain from the
    /// wallet's birthday. Nothing is deleted: only the record of which blocks were already read.
    func repair() throws {
        try using { handle in
            _ = try ffi { wallet_start_txo_validation(handle, $0) }
            _ = try ffi { wallet_start_transaction_validation(handle, $0) }
            _ = try ffi { wallet_rescan(handle, 0, $0) }
        }
    }

    private static func readPendingOutbound(_ list: OpaquePointer?) throws -> [WalletTransaction] {
        guard let list else { return [] }
        let count = try ffi { pending_outbound_transactions_get_length(list, $0) }
        return try (0..<count).map { i in
            let tx = try ffi { pending_outbound_transactions_get_at(list, i, $0) }
            defer { pending_outbound_transaction_destroy(tx) }
            let destination = try ffi { pending_outbound_transaction_get_destination_tari_address(tx, $0) }
            defer { tari_address_destroy(destination) }
            return WalletTransaction(
                id: try ffi { pending_outbound_transaction_get_transaction_id(tx, $0) },
                amount: try ffi { pending_outbound_transaction_get_amount(tx, $0) },
                fee: try ffi { pending_outbound_transaction_get_fee(tx, $0) },
                isOutbound: true,
                date: Date(timeIntervalSince1970: TimeInterval(try ffi { pending_outbound_transaction_get_timestamp(tx, $0) })),
                status: status(try ffi { pending_outbound_transaction_get_status(tx, $0) }),
                counterparty: destination.flatMap(knownAddress),
                note: text(try? ffi { pending_outbound_transaction_get_user_payment_id_as_bytes(tx, $0) }),
                minedHeight: nil,
                lockHeight: 0)
        }
    }

    private static func readPendingInbound(_ list: OpaquePointer?) throws -> [WalletTransaction] {
        guard let list else { return [] }
        let count = try ffi { pending_inbound_transactions_get_length(list, $0) }
        return try (0..<count).map { i in
            let tx = try ffi { pending_inbound_transactions_get_at(list, i, $0) }
            defer { pending_inbound_transaction_destroy(tx) }
            let source = try ffi { pending_inbound_transaction_get_source_tari_address(tx, $0) }
            defer { tari_address_destroy(source) }
            return WalletTransaction(
                id: try ffi { pending_inbound_transaction_get_transaction_id(tx, $0) },
                amount: try ffi { pending_inbound_transaction_get_amount(tx, $0) },
                fee: 0,
                isOutbound: false,
                date: Date(timeIntervalSince1970: TimeInterval(try ffi { pending_inbound_transaction_get_timestamp(tx, $0) })),
                status: status(try ffi { pending_inbound_transaction_get_status(tx, $0) }),
                counterparty: source.flatMap(knownAddress),
                note: text(try? ffi { pending_inbound_transaction_get_user_payment_id_as_bytes(tx, $0) }),
                minedHeight: nil,
                lockHeight: 0)
        }
    }

    /// A note stored as bytes, as text.
    private static func text(_ vector: OpaquePointer?) -> String {
        String(decoding: (try? takeBytes(vector)) ?? [], as: UTF8.self)
    }

    private static func read(_ list: OpaquePointer?, cancelled: Bool) throws -> [WalletTransaction] {
        guard let list else { return [] }
        let count = try ffi { completed_transactions_get_length(list, $0) }
        return try (0..<count).map { i in
            let tx = try ffi { completed_transactions_get_at(list, i, $0) }
            defer { completed_transaction_destroy(tx) }
            let outbound = try ffi { completed_transaction_is_outbound(tx, $0) }
            let other = outbound
                ? try ffi { completed_transaction_get_destination_tari_address(tx, $0) }
                : try ffi { completed_transaction_get_source_tari_address(tx, $0) }
            defer { tari_address_destroy(other) }
            return WalletTransaction(
                id: try ffi { completed_transaction_get_transaction_id(tx, $0) },
                amount: try ffi { completed_transaction_get_amount(tx, $0) },
                fee: try ffi { completed_transaction_get_fee(tx, $0) },
                isOutbound: outbound,
                date: Date(timeIntervalSince1970: TimeInterval(try ffi { completed_transaction_get_timestamp(tx, $0) })),
                status: cancelled ? .cancelled : status(try ffi { completed_transaction_get_status(tx, $0) }),
                counterparty: other.flatMap(knownAddress),
                note: userNote(tx),
                minedHeight: (try? ffi { completed_transaction_get_mined_height(tx, $0) }).flatMap { $0 > 0 ? $0 : nil },
                lockHeight: (try? ffi { completed_transaction_get_lock_height(tx, $0) }) ?? 0)
        }
    }

    /// The sender's note. The library may return a string even when it reports an error, so free
    /// it either way.
    private static func userNote(_ tx: OpaquePointer?) -> String {
        var code: Int32 = 0
        let note = takeString(completed_transaction_get_user_payment_id(tx, &code))
        return code == 0 ? note : ""
    }

    /// Maps `LegacyTransactionStatus` (common_types/src/transaction.rs), which is what
    /// `completed_transaction_get_status` returns. The table in wallet.h is out of date.
    private static func status(_ code: Int32) -> WalletTransaction.Status {
        switch code {
        case 0, 4, 10: .pending            // completed, pending, queued
        case 1: .broadcast
        case 2, 8, 11: .confirming         // mined / one-sided / coinbase, not yet confirmed
        case 3, 5, 6, 9, 12: .confirmed    // imported, coinbase, mined, one-sided, coinbase: confirmed
        case 14, 15, 16: .locked           // confirmed, but outputs not spendable yet
        case 7, 13: .rejected              // rejected by the mempool, coinbase not in chain
        default: .pending
        }
    }

    /// One-sided payments don't reveal the sender; the library returns an all-zero key then.
    private static func knownAddress(_ address: OpaquePointer) -> String? {
        guard let bytes = try? takeBytes(try ffi { tari_address_get_bytes(address, $0) }),
              bytes.dropFirst(2).contains(where: { $0 != 0 }) else { return nil }
        return try? TariAddress.base58(fromAddressPointer: address)
    }
}

/// Bridges C callbacks (which can't capture Swift state) back to a Swift closure on the main thread.
private final class EventSink {
    private let handler: (WalletEvent) -> Void
    init(_ handler: @escaping (WalletEvent) -> Void) { self.handler = handler }

    static func from(_ context: UnsafeMutableRawPointer?) -> EventSink? {
        context.map { Unmanaged<EventSink>.fromOpaque($0).takeUnretainedValue() }
    }

    func send(_ event: WalletEvent) {
        DispatchQueue.main.async { self.handler(event) }
    }
}

enum SeedWords {
    enum Problem: LocalizedError {
        case wrongCount(Int), unknownWord(String), invalidPhrase
        var errorDescription: String? {
            switch self {
            case .wrongCount(let n): "Enter all 24 words (you entered \(n))."
            case .unknownWord(let w): "“\(w)” isn't a valid seed word."
            case .invalidPhrase: "These words don't form a valid seed phrase. Check the spelling and order."
            }
        }
    }

    /// Splits user input into lowercase words on any whitespace, commas or numbering.
    static func parse(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }

    static func validate(_ words: [String]) throws {
        seed_words_destroy(try make(words))
    }

    /// Builds a library seed-words object, validating each word and the phrase as a whole.
    static func make(_ words: [String]) throws -> OpaquePointer {
        guard words.count == 24 else { throw Problem.wrongCount(words.count) }
        guard let seeds = seed_words_create() else { throw TariError(code: -1) }
        var complete = false
        defer { if !complete { seed_words_destroy(seeds) } }
        for word in words {
            switch try ffi({ seed_words_push_word(seeds, word, nil, $0) }) {
            case 1, 2: continue
            case 0: throw Problem.unknownWord(word)
            default: throw Problem.invalidPhrase
            }
        }
        complete = true
        return seeds
    }
}
