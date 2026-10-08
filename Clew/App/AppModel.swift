import AppKit
import Foundation
import LocalAuthentication
import Observation

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case welcome, backup([String]), locked, unlocked
        /// The wallet list couldn't be read. Nothing may be created or saved, so nothing is overwritten.
        case problem(String)
    }

    private(set) var phase: Phase
    private(set) var wallets: [WalletProfile]
    private(set) var activeID: UUID?
    private(set) var balance = Balance()
    private(set) var transactions: [WalletTransaction] = []
    private(set) var address = ""
    private(set) var connectivity: Connectivity = .connecting
    private(set) var scannedHeight: UInt64 = 0
    private(set) var busy = false
    /// Incoming payments that just arrived, highlighted for a few seconds.
    private(set) var arrivals: Set<UInt64> = []
    /// Bumped whenever a payment arrives, to trigger the balance animation.
    private(set) var arrivalCount = 0
    private var knownTransactionIDs: Set<UInt64>?   // nil until the first load of a wallet
    var errorMessage: String?

    var hideBalance: Bool {
        didSet { UserDefaults.standard.set(hideBalance, forKey: "hideBalance") }
    }
    private(set) var nodeURL: String {
        didSet { UserDefaults.standard.set(nodeURL, forKey: "nodeURL.\(Config.network)") }
    }

    /// Route wallet traffic through Tor (all wallets).
    private(set) var useTor: Bool {
        didSet { UserDefaults.standard.set(useTor, forKey: "useTor") }
    }
    let tor = TorService()

    var activeWallet: WalletProfile? { wallets.first { $0.id == activeID } }

    private var store: WalletStore
    private var wallet: WalletCore?
    private var session: LAContext?   // one Touch ID unlocks every wallet until the app locks
    private var generation = 0        // ignores late events from a wallet that was just closed
    /// Bumped by every lock. An operation that started before a lock stops at its next step.
    private var lockEpoch = 0
    /// Wallets still shutting down, so the same files are never opened twice.
    private var closing: [UUID: Task<Void, Never>] = [:]
    /// The wallet whose Tor circuits are in use: each wallet gets its own, so a node can't link
    /// wallets by a shared exit address.
    private var proxyWalletID: UUID?

    /// Thrown when a lock interrupts an operation. Not an error worth showing.
    private struct Interrupted: Error {}

    init() {
        hideBalance = UserDefaults.standard.bool(forKey: "hideBalance")
        useTor = UserDefaults.standard.object(forKey: "useTor") as? Bool ?? true  // Tor unless switched off
        nodeURL = UserDefaults.standard.string(forKey: "nodeURL.\(Config.network)") ?? Config.defaultNodeURL
        do {
            let loaded = try WalletStore.load()
            store = loaded
            wallets = loaded.wallets
            phase = loaded.wallets.isEmpty ? .welcome : .locked
        } catch {
            store = WalletStore()
            wallets = []
            phase = .problem(error.localizedDescription)
        }
        WalletStore.deleteOldLogs()

        // Lock whenever the Mac sleeps, the screen locks or turns off, or the user switches away.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.willSleepNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }

        // Pick the route before anything can connect, and follow Tor as it starts, stops or restarts.
        tor.onChange = { [weak self] in self?.applyProxy() }
        applyProxy()
        if useTor { Task { await tor.start() } }  // connect while the user is still on the lock screen
    }

    // MARK: - Network

    func setUseTor(_ on: Bool) {
        useTor = on
        // Takes effect immediately, for running wallets too. Turning Tor on blocks traffic until
        // Tor is ready, so nothing goes out directly in between.
        applyProxy()
        if on {
            Task {
                await tor.start()
                // The blockchain scanner keeps one connection for a whole scan; reopening the wallet
                // makes it start over through Tor instead of finishing on its direct connection.
                await reconnect()
            }
        } else {
            tor.stop()
        }
    }

    /// Restarts Tor after a failure. Wallets stay offline until it's back.
    func retryTor() async {
        tor.stop()
        await tor.start()
    }

    /// Only https (or http to this Mac or an onion address, which are encrypted end to end anyway),
    /// so a Tor exit can't read or change the wallet's traffic.
    static func isAcceptableNodeURL(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), let host = url.host else { return false }
        switch url.scheme {
        case "https": return true
        case "http": return host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".onion")
        default: return false
        }
    }

    func setNodeURL(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard Self.isAcceptableNodeURL(trimmed), trimmed != nodeURL else { return }
        nodeURL = trimmed
        await reconnect()  // the node address is fixed when a wallet opens
    }

    /// Sets the wallet library's route from the current Tor state. Fails closed: with Tor on,
    /// anything other than a working Tor port becomes a dead port, never a direct connection.
    private func applyProxy() {
        let route = useTor ? tor.proxyURL(isolation: proxyWalletID?.uuidString) : nil
        if (try? WalletCore.setProxy(route)) == nil, useTor {
            try? WalletCore.setProxy(TorService.deadProxy)
        }
    }

    var suggestedWalletName: String { store.suggestedName() }

    // MARK: - Adding wallets

    func createWallet(name: String) async {
        await run { epoch in
            try await self.add(name: name, seedWords: nil, epoch: epoch)
            self.phase = .backup(try self.wallet!.seedWords)
        }
    }

    /// Returns true on success, so the sheet that asked can close.
    func restoreWallet(name: String, from text: String) async -> Bool {
        var restored = false
        await run { epoch in
            let words = SeedWords.parse(text)
            try SeedWords.validate(words)
            var profile = try await self.add(name: name, seedWords: words, epoch: epoch)
            profile.backedUp = true
            try self.update(profile)
            self.phase = .unlocked
            restored = true
        }
        return restored
    }

    func finishBackup() {
        markBackedUp()
        phase = .unlocked
    }

    // MARK: - Lock and switch

    func unlock() async {
        await run { epoch in
            let session = try await Vault.startSession(reason: "unlock your Tari wallets")
            guard self.lockEpoch == epoch else { session.invalidate(); throw Interrupted() }
            self.session = session
            // Last-used wallet first. If one can't be opened, try the others, so a single broken
            // wallet doesn't lock you out of all of them.
            let lastUsed = self.store.lastUsed
            let ordered = self.wallets.filter { $0.id == lastUsed } + self.wallets.filter { $0.id != lastUsed }
            var failure: (name: String, error: Error)?
            for profile in ordered {
                do {
                    try await self.open(profile, passphrase: self.passphrase(for: profile), seedWords: nil,
                                        epoch: epoch)
                    self.phase = .unlocked
                    if let failure {
                        self.errorMessage = "Couldn't open “\(failure.name)”: \(failure.error.localizedDescription)"
                    }
                    return
                } catch let error as Interrupted {
                    throw error
                } catch Vault.Failure.cancelled {
                    throw Vault.Failure.cancelled
                } catch {
                    guard self.lockEpoch == epoch else { throw Interrupted() }  // locked: don't try others
                    failure = failure ?? (profile.name, error)
                }
            }
            self.endSession()
            if let failure { throw failure.error }
            self.phase = .welcome
        }
    }

    /// Closes the open wallet and forgets the unlock. Always wins over an operation in progress:
    /// that operation stops at its next step, and a wallet that finishes opening is closed again.
    func lock() {
        if case .backup = phase { return }  // don't hide the seed words mid-backup
        lockEpoch += 1
        if let old = wallet, let id = activeID { retire(old, id: id) }
        detach()
        endSession()
        if phase == .unlocked { phase = .locked }
    }

    func switchTo(_ id: UUID) async {
        guard id != activeID, let profile = wallets.first(where: { $0.id == id }) else { return }
        await run { epoch in
            // Different files, so the new wallet can open before the old one closes.
            try await self.open(profile, passphrase: self.passphrase(for: profile), seedWords: nil, epoch: epoch)
        }
    }

    /// Reopens the active wallet, e.g. so a changed node address takes effect.
    func reconnect() async {
        await run { epoch in try await self.reopenActive(epoch: epoch) }
    }

    private func reopenActive(epoch: Int) async throws {
        guard let profile = activeWallet, wallet != nil else { return }
        let passphrase = try await passphrase(for: profile)
        guard lockEpoch == epoch else { throw Interrupted() }
        await closeWallet()
        try await open(profile, passphrase: passphrase, seedWords: nil, epoch: epoch)
    }

    // MARK: - Managing wallets

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var profile = wallets.first(where: { $0.id == id }) else { return }
        profile.name = trimmed
        try? update(profile)
    }

    func markBackedUp() {
        guard var profile = activeWallet else { return }
        profile.backedUp = true
        try? update(profile)
    }

    /// Deletes the active wallet after a Touch ID check. Returns true if it was deleted.
    func deleteActiveWallet() async -> Bool {
        guard let profile = activeWallet else { return false }
        var deleted = false
        await run { epoch in
            try await Vault.confirmOwner(reason: "delete “\(profile.name)” from your Mac")
            guard self.lockEpoch == epoch, self.activeID == profile.id else { throw Interrupted() }
            await self.closeWallet()
            do {
                try self.remove(profile)
            } catch {
                self.lock()  // leave Clew in a safe, simple state
                throw error
            }
            deleted = true
            if let next = self.wallets.first {
                do {
                    try await self.open(next, passphrase: self.passphrase(for: next), seedWords: nil, epoch: epoch)
                } catch {
                    self.lock()
                }
            } else {
                self.endSession()
                self.phase = .welcome
            }
        }
        return deleted
    }

    // MARK: - Wallet actions

    func estimateFee(amount: MicroTari, feePerGram: MicroTari) -> MicroTari? {
        try? wallet?.estimateFee(amount: amount, feePerGram: feePerGram)
    }

    /// Current Economy / Normal / Fast rates. Falls back to safe defaults if the node can't be asked.
    func feeTiers() async -> FeeTiers {
        guard let wallet else { return .fallback }
        return await Task.detached { (try? wallet.feeTiers()) ?? .fallback }.value
    }

    /// Sends from the wallet with id `walletID` (the one the Send screen was opened for). Refuses if
    /// Clew switched or locked while Touch ID was showing.
    func send(amount: MicroTari, to recipient: String, note: String, feePerGram: MicroTari,
              from walletID: UUID?) async throws {
        guard let core = wallet, walletID == activeID else { throw TariError.closed }
        try await Vault.confirmOwner(reason: "send \(XTM.format(amount)) XTM")
        guard core === wallet, walletID == activeID else { throw TariError.closed }
        try core.send(amount: amount, to: recipient, note: note, feePerGram: feePerGram)
        refresh()
    }

    func paymentRecords(for transaction: WalletTransaction) -> [PaymentRecord] {
        (try? wallet?.paymentRecords(for: transaction.id)) ?? []
    }

    var confirmationsRequired: UInt64 { wallet?.confirmationsRequired ?? 3 }

    /// Re-checks the open wallet against the blockchain and reopens it so the scan starts right away.
    func repairWallet() async {
        guard let core = wallet else { return }
        await run { epoch in
            try core.repair()
            try await self.reopenActive(epoch: epoch)
        }
    }

    func revealSeedWords() async throws -> [String] {
        guard let core = wallet else { throw Vault.Failure.missing }
        try await Vault.confirmOwner(reason: "show your recovery words")
        guard core === wallet else { throw TariError.closed }
        return try core.seedWords
    }

    // MARK: - Internals

    /// Creates a profile, Keychain item and folder, then opens the wallet. Undoes all of it on failure.
    @discardableResult
    private func add(name: String, seedWords: [String]?, epoch: Int) async throws -> WalletProfile {
        let id = UUID()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = WalletProfile(
            id: id, name: trimmed.isEmpty ? store.suggestedName() : trimmed, folder: id.uuidString,
            keychainAccount: "wallet-db-passphrase.\(Config.network).\(id.uuidString)",
            backedUp: false, created: Date())
        let passphrase = try Vault.createPassphrase(account: profile.keychainAccount)
        do {
            store.wallets.append(profile)
            try store.save()
            wallets = store.wallets
            // Only swaps to the new wallet once it's fully open, so a failure leaves the
            // current wallet running and this cleanup can't touch it.
            try await open(profile, passphrase: passphrase, seedWords: seedWords, isNew: true, epoch: epoch)
            return profile
        } catch {
            if let pending = closing[profile.id] { await pending.value }  // never delete files in use
            try? remove(profile)
            throw error
        }
    }

    /// Forgets a wallet, then deletes its Keychain item and files, in that order: if a later step
    /// fails, the leftovers are never mistaken for a wallet to open.
    private func remove(_ profile: WalletProfile) throws {
        store.wallets.removeAll { $0.id == profile.id }
        if store.lastUsed == profile.id { store.lastUsed = store.wallets.first?.id }
        try store.save()
        wallets = store.wallets
        try Vault.deletePassphrase(account: profile.keychainAccount)
        try store.removeFiles(of: profile)
    }

    private func update(_ profile: WalletProfile) throws {
        guard let index = store.wallets.firstIndex(where: { $0.id == profile.id }) else { return }
        store.wallets[index] = profile
        try store.save()
        wallets = store.wallets
    }

    private func passphrase(for profile: WalletProfile) async throws -> String {
        try await Vault.readPassphrase(account: profile.keychainAccount, session: session,
                                       reason: "open “\(profile.name)”")
    }

    private func endSession() {
        session?.invalidate()
        session = nil
    }

    /// Opens a wallet as part of an operation that started in lock epoch `epoch`: if Clew has
    /// locked since, it stops (or closes the wallet again) instead of opening behind the lock screen.
    private func open(_ profile: WalletProfile, passphrase: String, seedWords: [String]?,
                      isNew: Bool = false, epoch: Int) async throws {
        guard lockEpoch == epoch else { throw Interrupted() }
        guard !(wallet != nil && activeID == profile.id) else { return }  // already open: never twice
        let directory = try store.directory(for: profile, isNew: isNew)
        if let pending = closing[profile.id] {
            await pending.value
            if closing[profile.id] == pending { closing[profile.id] = nil }
        }
        // Decide the route before the wallet starts. With Tor on but not working, the proxy points
        // at a closed port, so the wallet stays offline rather than connecting directly.
        if useTor { await tor.start() }
        guard lockEpoch == epoch else { throw Interrupted() }
        proxyWalletID = profile.id
        applyProxy()

        // From here on, events from the wallet that's currently open are ignored.
        let previousGeneration = generation
        generation += 1
        let current = generation
        let onEvent: (WalletEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.handle(event)
            }
        }
        let network = Config.network, node = nodeURL
        // Opening runs database migrations and starts services; keep it off the main thread.
        let core: WalletCore
        do {
            core = try await Task.detached {
                try WalletCore(directory: directory, passphrase: passphrase, seedWords: seedWords,
                               network: network, nodeURL: node, onEvent: onEvent)
            }.value
        } catch {
            if lockEpoch == epoch { generation = previousGeneration }  // the open wallet stays in charge
            throw error
        }
        let newAddress: String
        do {
            // A lock while the wallet was opening wins: close it again.
            guard lockEpoch == epoch else { throw Interrupted() }
            newAddress = try core.address
        } catch {
            retire(core, id: profile.id)
            if lockEpoch == epoch { generation = previousGeneration }
            throw error
        }

        // Swap straight to the new wallet (no empty state in between), then shut the old one down.
        if let previous = wallet, let previousID = activeID { retire(previous, id: previousID) }
        wallet = core
        activeID = profile.id
        connectivity = .connecting
        scannedHeight = 0
        knownTransactionIDs = nil
        arrivals = []
        balance = Balance()
        transactions = []
        address = newAddress
        store.lastUsed = profile.id
        try? store.save()
        refresh()
    }

    /// Shuts a wallet down in the background. Opening the same wallet waits for this to finish.
    private func retire(_ core: WalletCore, id: UUID) {
        let previous = closing[id]
        closing[id] = Task.detached {
            await previous?.value
            core.shutdown()
        }
    }

    /// Shuts the open wallet down and waits until it's fully closed.
    private func closeWallet() async {
        guard let old = wallet, let id = activeID else { return }
        retire(old, id: id)
        detach()
        await closing[id]?.value
    }

    private func detach() {
        wallet = nil
        generation += 1
        activeID = nil
        balance = Balance()
        transactions = []
        address = ""
        scannedHeight = 0
        connectivity = .connecting
        knownTransactionIDs = nil
        arrivals = []
    }

    private func handle(_ event: WalletEvent) {
        switch event {
        case .changed: refresh()
        case .connectivity(let status): connectivity = status
        case .scannedHeight(let height): scannedHeight = height; refresh()
        }
    }

    private func refresh() {
        guard let wallet else { return }
        if let value = try? wallet.balance { balance = value }
        if let value = try? wallet.transactions {
            transactions = value
            noticeArrivals(in: value)
        }
    }

    /// Highlights incoming payments that weren't there on the previous refresh. The first load
    /// after opening a wallet only records what's there, so nothing flashes on unlock.
    private func noticeArrivals(in list: [WalletTransaction]) {
        let ids = Set(list.map(\.id))
        defer { knownTransactionIDs = ids }
        guard let known = knownTransactionIDs else { return }
        // Old payments found by a restore or repair aren't news; only recent ones get highlighted.
        let recent = Date().addingTimeInterval(-3600)
        let new = Set(list.filter { !$0.isOutbound && !known.contains($0.id) && $0.date > recent }.map(\.id))
        guard !new.isEmpty else { return }
        arrivals.formUnion(new)
        arrivalCount += 1
        Task {
            try? await Task.sleep(for: .seconds(4))
            arrivals.subtract(new)
        }
    }

    /// Runs one operation at a time: while one is in progress, others are ignored. `work` gets
    /// the lock epoch it started in, to check whether a lock has happened since.
    private func run(_ work: @escaping (Int) async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await work(lockEpoch)
        } catch is Interrupted {
            // Clew locked part-way through; the lock screen says all there is to say.
        } catch Vault.Failure.cancelled {
            // The user dismissed Touch ID; nothing to report.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Amounts: the library counts in µT; people read XTM.
enum XTM {
    /// "12.5", or "12,5" where a comma is the decimal separator.
    static var example: String { "12\(Locale.current.decimalSeparator == "," ? "," : ".")5" }

    static func format(_ micro: MicroTari) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 6
        return formatter.string(from: NSDecimalNumber(value: micro).dividing(by: 1_000_000)) ?? "0"
    }

    /// Parses an amount typed by the user, like "12.5" or ".25", into µT. Anything else is
    /// rejected rather than guessed at: no thousands separators, at most 6 decimal places, and a
    /// comma counts as the decimal point only where that's the local convention (e.g. "12,5" in
    /// Germany). Returns nil for anything that isn't a clear, positive amount.
    static func parse(_ text: String, locale: Locale = .current) -> MicroTari? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let commaIsDecimal = locale.decimalSeparator == ","
        let pattern = commaIsDecimal ? #"^[0-9]*([.,][0-9]{1,6})?$"# : #"^[0-9]*(\.[0-9]{1,6})?$"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil,
              trimmed.contains(where: \.isNumber) else { return nil }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        guard let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")), value > 0 else {
            return nil
        }
        let micro = NSDecimalNumber(decimal: value * 1_000_000)
        guard micro.compare(NSDecimalNumber(value: UInt64.max)) == .orderedAscending else { return nil }
        return micro.uint64Value
    }
}
