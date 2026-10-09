import AppKit
import Foundation
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

    /// Show the TARI side of each wallet, on Ootle's testnet (all wallets). Off: Ootle isn't opened
    /// and nothing of it connects.
    private(set) var showOotle: Bool {
        didSet { UserDefaults.standard.set(showOotle, forKey: "showOotleTestnet") }
    }
    enum OotleState: Equatable { case off, opening, ready, failed(String) }
    private(set) var ootleState: OotleState = .off
    private(set) var tariBalance: MicroTari = 0
    private(set) var tariHistory: [OotleEntry] = []
    private(set) var ootleAddress = ""
    /// Whether the last check with the network worked (nil before the first one finishes).
    private(set) var ootleOnline: Bool?
    /// A TARI action (claim, send) is in progress.
    private(set) var ootleBusy = false
    /// XTM moved to TARI that hasn't been claimed yet, newest first.
    private(set) var tariMoves: [OotleMove] = []
    /// Why the last attempt to claim a move didn't work, if it didn't.
    private(set) var tariMoveProblem: String?
    /// Moving XTM to TARI needs both on the same network. Until Ootle launches, Clew's mainnet
    /// wallets and Ootle's testnet don't match, so it's off (moving real XTM there would lose it).
    var canMoveToTari: Bool { Config.network == Config.ootleNetwork }

    var activeWallet: WalletProfile? { wallets.first { $0.id == activeID } }

    /// Every wallet still uses a Keychain key (made before passwords): the lock screen offers the
    /// one-time switch instead of a password field. Stragglers are switched after unlocking.
    var needsPasswordSwitch: Bool { !wallets.isEmpty && wallets.allSatisfy(\.needsPasswordSwitch) }
    /// Unlock and confirm with Touch ID instead of typing the password.
    private(set) var touchIDEnabled = TouchIDShortcut.isEnabled

    /// Thrown when an action needs the password typed in (no Touch ID shortcut, or it failed).
    struct PasswordNeeded: Error {}

    private var store: WalletStore
    private var wallet: WalletCore?
    /// The password, kept while Clew is unlocked so every wallet can open without asking again.
    private var sessionPassword: String?
    private var generation = 0        // ignores late events from a wallet that was just closed
    /// Bumped by every lock. An operation that started before a lock stops at its next step.
    private var lockEpoch = 0
    /// Wallets still shutting down, so the same files are never opened twice.
    private var closing: [UUID: Task<Void, Never>] = [:]
    /// The wallet whose Tor circuits are in use: each wallet gets its own, so a node can't link
    /// wallets by a shared exit address.
    private var proxyWalletID: UUID?

    private var ootle: OotleCore?
    /// The wallet the Ootle wallet belongs to.
    private var ootleWalletID: UUID?
    /// Bumped whenever the Ootle wallet closes, so results from an older one are dropped.
    private var ootleGeneration = 0
    /// The proxy route the open Ootle wallet was opened with (it keeps it until reopened).
    private var ootleRoute: String?
    /// The route currently set for new Ootle connections.
    private var currentOotleRoute: String?
    private var ootlePoller: Task<Void, Never>?

    /// Thrown when a lock interrupts an operation. Not an error worth showing.
    private struct Interrupted: Error {}

    init() {
        hideBalance = UserDefaults.standard.bool(forKey: "hideBalance")
        useTor = UserDefaults.standard.object(forKey: "useTor") as? Bool ?? true  // Tor unless switched off
        nodeURL = UserDefaults.standard.string(forKey: "nodeURL.\(Config.network)") ?? Config.defaultNodeURL
        showOotle = UserDefaults.standard.bool(forKey: "showOotleTestnet")
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
        // Ootle gets circuits of its own, so the indexer and the node don't share an exit address.
        var ootleRoute = useTor ? tor.proxyURL(isolation: proxyWalletID.map { "\($0.uuidString)-ootle" }) : nil
        if (try? OotleCore.setProxy(ootleRoute)) == nil, useTor {
            try? OotleCore.setProxy(TorService.deadProxy)
            ootleRoute = TorService.deadProxy
        }
        currentOotleRoute = ootleRoute
        // An open Ootle wallet keeps the route it opened with: reopen it on the new one.
        if ootle != nil, ootleWalletID == proxyWalletID, self.ootleRoute != ootleRoute {
            stopOotle()
            startOotle()
        }
    }

    var suggestedWalletName: String { store.suggestedName() }

    // MARK: - Adding wallets

    /// True when no password has been chosen yet (no wallets, or Clew is on the welcome screen).
    var needsNewPassword: Bool { wallets.isEmpty || sessionPassword == nil }

    /// `password` is only needed for the first wallet; later ones use the current password.
    func createWallet(name: String, password: String? = nil) async {
        await run { epoch in
            try await self.choosingFirstPassword(password) {
                try await self.add(name: name, seedWords: nil, epoch: epoch)
                self.phase = .backup(try self.wallet!.seedWords)
            }
        }
    }

    /// Returns true on success, so the sheet that asked can close.
    func restoreWallet(name: String, from text: String, password: String? = nil) async -> Bool {
        var restored = false
        await run { epoch in
            try await self.choosingFirstPassword(password) {
                let words = SeedWords.parse(text)
                try SeedWords.validate(words)
                var profile = try await self.add(name: name, seedWords: words, epoch: epoch)
                profile.backedUp = true
                try self.update(profile)
                self.phase = .unlocked
                restored = true
            }
        }
        return restored
    }

    /// For the first wallet: uses `password` for it, and forgets it again if making the wallet fails.
    private func choosingFirstPassword(_ password: String?, _ work: () async throws -> Void) async throws {
        let first = needsNewPassword
        if let password, first { sessionPassword = password }
        do {
            try await work()
        } catch {
            if first && wallets.isEmpty { sessionPassword = nil }
            throw error
        }
    }

    func finishBackup() {
        markBackedUp()
        phase = .unlocked
    }

    // MARK: - Lock and switch

    /// Unlocks with `password`, or with the Touch ID shortcut when `password` is nil. Any wallet the
    /// password opens counts. If that wallet is on an older password than others (a password change
    /// was cut short), Clew asks for the newest one to finish the change. Wallets still on the
    /// Keychain are then switched to the password (once per launch) unless `switchingLegacy` is false.
    func unlock(password typed: String?, switchingLegacy: Bool = true) async {
        var leftOver: [String] = []
        await run { epoch in
            let password: String
            if let typed { password = typed } else {
                password = try await TouchIDShortcut.password(reason: "unlock Clew")
            }
            guard self.lockEpoch == epoch else { throw Interrupted() }
            self.sessionPassword = password
            let found: WalletProfile?
            do {
                found = try await self.openFirstAvailable(password: password, epoch: epoch)
            } catch {
                self.endSession()
                throw error
            }
            guard let opened = found else {
                self.endSession()
                throw TariError.wrongPassword
            }
            self.sessionGeneration = opened.generation
            self.sessionEstablished = true
            self.phase = .unlocked
            if opened.generation < self.newestGeneration { self.needsNewestPassword = true }
            if switchingLegacy && !self.triedLegacySwitch {
                self.triedLegacySwitch = true
                do {
                    leftOver = try await self.switchLegacyWallets(to: password, epoch: epoch)
                } catch Vault.Failure.cancelled {
                    leftOver = ["Some wallets still use the Keychain. Clew will offer to switch them next time it starts."]
                }
            }
        }
        if !leftOver.isEmpty {
            errorMessage = "Not every wallet could be switched to your password yet:\n" + leftOver.joined(separator: "\n")
        }
    }

    /// Opens the first wallet `password` opens: the last-used one if it can, then newest password
    /// generation first. Returns nil if it opens none (so it's the wrong password).
    private func openFirstAvailable(password: String, epoch: Int) async throws -> WalletProfile? {
        let lastUsed = store.lastUsed
        let ready = wallets.filter { !$0.needsPasswordSwitch }.sorted { $0.generation > $1.generation }
        let ordered = ready.filter { $0.id == lastUsed } + ready.filter { $0.id != lastUsed }
        var failure: (name: String, error: Error)?
        for profile in ordered {
            do {
                try await open(profile, passphrase: password, seedWords: nil, epoch: epoch)
                if let failure {
                    errorMessage = "Couldn't open “\(failure.name)”: \(failure.error.localizedDescription)"
                }
                return profile
            } catch let error as Interrupted {
                throw error
            } catch let error as TariError where error.isWrongPassword {
                continue  // on a different password; another wallet may open
            } catch {
                guard lockEpoch == epoch else { throw Interrupted() }  // locked: don't try others
                failure = failure ?? (profile.name, error)
            }
        }
        if let failure { throw failure.error }
        return nil
    }

    /// Closes the open wallet and forgets the unlock. Always wins over an operation in progress:
    /// that operation stops at its next step, and a wallet that finishes opening is closed again.
    func lock() {
        if case .backup = phase { return }  // don't hide the seed words mid-backup
        lockEpoch += 1
        if let old = wallet, let id = activeID { retire(old, id: id) }
        detach()
        endSession()
        walletNeedingPreviousPassword = nil
        needsNewestPassword = false
        if phase == .unlocked { phase = .locked }
    }

    /// A wallet on an older password than the one Clew is unlocked with (it rejected the current
    /// one). The UI asks for that password and calls `switchTo(_:previousPassword:)`.
    var walletNeedingPreviousPassword: WalletProfile?
    /// Clew was unlocked with an older password than some wallets have: a password change was cut
    /// short. The UI asks for the newest password and calls `finishPasswordChange(newest:)`.
    var needsNewestPassword = false
    /// The password generation of the password Clew is unlocked with.
    private var sessionGeneration = 0
    /// True once unlock has worked out `sessionGeneration`.
    private var sessionEstablished = false
    private var triedLegacySwitch = false
    private var newestGeneration: Int { wallets.filter { !$0.needsPasswordSwitch }.map(\.generation).max() ?? 0 }

    /// Opens another wallet. With `previousPassword`, first brings a wallet that's on an older
    /// password up to the current one.
    func switchTo(_ id: UUID, previousPassword: String? = nil) async {
        if previousPassword != nil { await waitUntilIdle() }  // answered a prompt: don't drop it
        guard id != activeID, let profile = wallets.first(where: { $0.id == id }) else { return }
        await run { epoch in
            let current = try self.currentPassword()
            if let previousPassword {
                let directory = try self.store.directory(for: profile, isNew: false)
                if let pending = self.closing[profile.id] { await pending.value }
                try await self.rekeying {
                    try await Task.detached {
                        try WalletCore.changePassword(directory: directory, from: previousPassword, to: current)
                    }.value
                    var updated = profile
                    updated.passwordGeneration = self.sessionGeneration
                    try self.update(updated)
                }
            }
            guard let fresh = self.wallets.first(where: { $0.id == id }) else { return }
            do {
                // Different files, so the new wallet can open before the old one closes.
                try await self.open(fresh, passphrase: current, seedWords: nil, epoch: epoch)
            } catch let error as TariError where error.isWrongPassword && fresh.usesPassword == true {
                if fresh.generation > self.sessionGeneration {
                    self.needsNewestPassword = true        // it has a newer password than this session
                } else {
                    self.walletNeedingPreviousPassword = fresh
                }
            }
        }
    }

    /// Reopens the active wallet, e.g. so a changed node address takes effect.
    func reconnect() async {
        await run { epoch in try await self.reopenActive(epoch: epoch) }
    }

    private func reopenActive(epoch: Int) async throws {
        guard let profile = activeWallet, wallet != nil else { return }
        let passphrase = try currentPassword()
        guard lockEpoch == epoch else { throw Interrupted() }
        await closeWallet()
        try await open(profile, passphrase: passphrase, seedWords: nil, epoch: epoch)
    }

    // MARK: - Password

    /// True while wallet files are being re-encrypted. Quitting is refused meanwhile (see AppDelegate).
    static private(set) var isRekeying = false

    private func rekeying<T>(_ work: () async throws -> T) async rethrows -> T {
        Self.isRekeying = true
        defer { Self.isRekeying = false }
        return try await work()
    }

    /// Checks the person in front of the Mac before a sensitive action: `password` if one was typed,
    /// otherwise the Touch ID shortcut. Throws `PasswordNeeded` when the password must be typed.
    private func authorize(password: String?, reason: String) async throws {
        guard let sessionPassword else { throw TariError.closed }
        if let password {
            guard password == sessionPassword else { throw TariError.wrongPassword }
            return
        }
        guard touchIDEnabled else { throw PasswordNeeded() }
        do {
            guard try await TouchIDShortcut.password(reason: reason) == sessionPassword else {
                throw TouchIDShortcut.Failure.stale
            }
        } catch {
            throw PasswordNeeded()  // cancelled or failed: offer the password instead
        }
    }

    /// First-time switch, when every wallet still uses a Keychain key: re-encrypts them with
    /// `password` and unlocks. Wallets that can't be switched are skipped and reported, so one
    /// broken wallet doesn't lock you out of the rest.
    func switchToPassword(_ password: String) async {
        let startEpoch = lockEpoch
        var leftOver: [String] = []
        await run { epoch in leftOver = try await self.switchLegacyWallets(to: password, epoch: epoch) }
        guard lockEpoch == startEpoch else { return }  // locked meanwhile: stay locked
        triedLegacySwitch = true
        if wallets.contains(where: { !$0.needsPasswordSwitch }) {
            await unlock(password: password, switchingLegacy: false)
        }
        if !leftOver.isEmpty {
            errorMessage = "Not every wallet could be switched to your password yet:\n" + leftOver.joined(separator: "\n")
        }
    }

    /// Re-encrypts every wallet that still uses a Keychain key with `password`, one Touch ID or Mac
    /// password prompt for all of them. Returns a line for each wallet it couldn't switch.
    /// Safe if interrupted at any point: each wallet is recorded as switched before its old key is
    /// deleted, and a wallet the old key definitely no longer opens was already switched.
    private func switchLegacyWallets(to password: String, epoch: Int) async throws -> [String] {
        let legacy = wallets.filter(\.needsPasswordSwitch)
        guard !legacy.isEmpty else { return [] }
        let generation = sessionPassword == password ? sessionGeneration : newestGeneration
        let session = try await Vault.startSession(reason: "switch your wallets to your Clew password")
        defer { session.invalidate() }
        var problems: [String] = []
        for var profile in legacy {
            guard lockEpoch == epoch else { throw Interrupted() }
            do {
                let old = try await Vault.readPassphrase(account: profile.keychainAccount, session: session,
                                                         reason: "switch “\(profile.name)” to your password")
                let directory = try store.directory(for: profile, isNew: false)
                if let pending = closing[profile.id] { await pending.value }
                var keyStillValid = true
                try await rekeying {
                    do {
                        try await Task.detached {
                            try WalletCore.changePassword(directory: directory, from: old, to: password)
                        }.value
                    } catch let error as TariError where error.isWrongPassword {
                        // The library says the old key definitely doesn't open it any more: it was
                        // switched before Clew could record that, to a password Clew can't identify.
                        keyStillValid = false
                    }
                }
                // Record the switch before deleting the old key.
                profile.usesPassword = true
                profile.passwordGeneration = keyStillValid ? generation : -1
                try update(profile)
                if keyStillValid { try? Vault.deletePassphrase(account: profile.keychainAccount) }
            } catch let error as Interrupted {
                throw error
            } catch {
                problems.append("“\(profile.name)”: \(error.localizedDescription)")
            }
        }
        return problems
    }

    /// Finishes a password change that was cut short: checks `newest` against a wallet that has it,
    /// then re-encrypts the wallets still on the password Clew was unlocked with. Returns true on success.
    func finishPasswordChange(newest: String) async -> Bool {
        await waitUntilIdle()  // answered a prompt: don't drop it
        var finished = false
        await run { epoch in
            let older = try self.currentPassword()
            let target = self.newestGeneration
            guard let witness = self.wallets.first(where: { !$0.needsPasswordSwitch && $0.generation == target }) else {
                return
            }
            // Check it's really the newest password before touching anything. The witness has a
            // newer password than the session, so it's never the open wallet.
            let witnessDirectory = try self.store.directory(for: witness, isNew: false)
            if let pending = self.closing[witness.id] { await pending.value }
            do {
                try await Task.detached {
                    try WalletCore.changePassword(directory: witnessDirectory, from: newest, to: newest)
                }.value
            } catch {
                self.needsNewestPassword = true  // ask again
                throw error
            }
            let reopen = self.activeWallet
            await self.closeWallet()
            do {
                try await self.rekeying {
                    for var profile in self.wallets
                    where !profile.needsPasswordSwitch && profile.generation == self.sessionGeneration {
                        let directory = try self.store.directory(for: profile, isNew: false)
                        if let pending = self.closing[profile.id] { await pending.value }
                        do {
                            try await Task.detached {
                                try WalletCore.changePassword(directory: directory, from: older, to: newest)
                            }.value
                        } catch let error as TariError where error.isWrongPassword {
                            // Already on the newest password (its label was out of date); just confirm it.
                            try await Task.detached {
                                try WalletCore.changePassword(directory: directory, from: newest, to: newest)
                            }.value
                        }
                        profile.passwordGeneration = target
                        try self.update(profile)
                    }
                }
            } catch {
                await self.reopenAfterFailure(reopen, passwords: [older, newest], epoch: epoch)
                throw error
            }
            if self.lockEpoch == epoch {
                self.sessionPassword = newest
                self.sessionGeneration = target
                self.needsNewestPassword = false
            }
            if self.touchIDEnabled { try? TouchIDShortcut.update(password: newest) }
            finished = true
            await self.reopenAfterFailure(reopen, passwords: [newest, older], epoch: epoch)
        }
        return finished
    }

    /// Reopens `profile` with the first of `passwords` that works, so Clew isn't left unlocked with
    /// no wallet open.
    private func reopenAfterFailure(_ profile: WalletProfile?, passwords: [String], epoch: Int) async {
        guard let profile, let fresh = wallets.first(where: { $0.id == profile.id }) else { return }
        for password in passwords {
            if (try? await open(fresh, passphrase: password, seedWords: nil, epoch: epoch)) != nil { return }
        }
    }

    /// Waits for the current operation to finish, so an action started from a prompt isn't ignored
    /// for arriving while Clew was busy.
    private func waitUntilIdle() async {
        while busy { try? await Task.sleep(for: .milliseconds(100)) }
    }

    enum PasswordChangeProblem: LocalizedError {
        case notInLine([String]), wallet(String, Error), rollbackIncomplete([String])
        var errorDescription: String? {
            switch self {
            case .notInLine(let names):
                "The password wasn't changed: \(names.joined(separator: ", ")) still use a different password. Open them once first."
            case .wallet(let name, let error):
                "The password wasn't changed: “\(name)” couldn't be updated (\(error.localizedDescription)). Open it once, or delete it, then try again."
            case .rollbackIncomplete(let names):
                "The password change stopped part-way, so \(names.joined(separator: ", ")) kept the new password. Clew will ask for it to finish the change when you unlock."
            }
        }
    }

    /// Changes the password of every wallet that uses the current one. Wallets still on the Keychain
    /// are left alone (they switch to the current password at the next unlock). Each wallet records
    /// the new generation as soon as it's re-encrypted, so an interrupted change can be finished
    /// later. If any wallet fails, the ones already changed are put back. Quitting is refused until
    /// it's done. Returns true on success.
    func changePassword(current: String, new: String) async -> Bool {
        guard current == sessionPassword else {
            errorMessage = TariError.wrongPassword.localizedDescription
            return false
        }
        let behind = wallets.filter { !$0.needsPasswordSwitch && $0.generation != sessionGeneration }
        guard behind.isEmpty else {
            errorMessage = PasswordChangeProblem.notInLine(behind.map { "“\($0.name)”" }).localizedDescription
            return false
        }
        var changed = false
        await run { epoch in
            let reopen = self.activeWallet
            let oldGeneration = self.sessionGeneration
            let newGeneration = self.newestGeneration + 1
            await self.closeWallet()
            try await self.rekeying {
                var done: [WalletProfile] = []
                do {
                    for var profile in self.wallets where !profile.needsPasswordSwitch {
                        do {
                            let directory = try self.store.directory(for: profile, isNew: false)
                            if let pending = self.closing[profile.id] { await pending.value }
                            try await Task.detached {
                                try WalletCore.changePassword(directory: directory, from: current, to: new)
                            }.value
                            profile.passwordGeneration = newGeneration
                            done.append(profile)
                            try self.update(profile)
                        } catch {
                            throw PasswordChangeProblem.wallet(profile.name, error)
                        }
                    }
                } catch {
                    var stuck: [String] = []
                    for var profile in done {
                        do {
                            let directory = try self.store.directory(for: profile, isNew: false)
                            try await Task.detached {
                                try WalletCore.changePassword(directory: directory, from: new, to: current)
                            }.value
                            profile.passwordGeneration = oldGeneration
                            try self.update(profile)
                        } catch {
                            stuck.append("“\(profile.name)”")
                        }
                    }
                    await self.reopenAfterFailure(reopen, passwords: [current, new], epoch: epoch)
                    throw stuck.isEmpty ? error : PasswordChangeProblem.rollbackIncomplete(stuck)
                }
            }
            if self.lockEpoch == epoch {  // not kept if Clew locked meanwhile
                self.sessionPassword = new
                self.sessionGeneration = newGeneration
            }
            if self.touchIDEnabled { try? TouchIDShortcut.update(password: new) }
            changed = true
            await self.reopenAfterFailure(reopen, passwords: [new, current], epoch: epoch)
        }
        return changed
    }

    /// Turns the Touch ID shortcut on (for the current password) or off.
    func setTouchID(_ on: Bool) {
        if on {
            guard let sessionPassword else { return }
            do {
                try TouchIDShortcut.enable(password: sessionPassword)
            } catch {
                errorMessage = "Couldn't turn on Touch ID: \(error.localizedDescription)"
            }
        } else {
            TouchIDShortcut.disable()
        }
        touchIDEnabled = TouchIDShortcut.isEnabled
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

    /// Deletes a wallet (open or not) after checking the password (or Touch ID). Returns true if it
    /// was deleted. Throws `PasswordNeeded` when the password has to be typed.
    func deleteWallet(_ id: UUID, password: String?) async throws -> Bool {
        guard let profile = wallets.first(where: { $0.id == id }) else { return false }
        let startEpoch = lockEpoch
        try await authorize(password: password, reason: "delete “\(profile.name)” from your Mac")
        var deleted = false
        await run { epoch in
            guard self.lockEpoch == startEpoch, self.lockEpoch == epoch else { throw Interrupted() }
            let wasActive = self.activeID == profile.id
            if wasActive { await self.closeWallet() }
            if let pending = self.closing[profile.id] { await pending.value }  // never delete files in use
            if self.walletNeedingPreviousPassword?.id == profile.id { self.walletNeedingPreviousPassword = nil }
            do {
                try self.remove(profile)
            } catch {
                if wasActive { self.lock() }  // leave Clew in a safe, simple state
                throw error
            }
            deleted = true
            if self.wallets.isEmpty {
                self.endSession()
                TouchIDShortcut.disable()  // it holds the old password, which no wallet uses now
                self.touchIDEnabled = false
                self.phase = .welcome
            } else if wasActive {
                let opened = try? await self.openFirstAvailable(password: self.currentPassword(), epoch: epoch)
                if opened == nil { self.lock() }
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

    /// Sends from the wallet with id `walletID` (the one the Send screen was opened for), after
    /// checking the password (or Touch ID). Refuses if Clew switched or locked in the meantime.
    /// Throws `PasswordNeeded` when the password has to be typed.
    func send(amount: MicroTari, to recipient: String, note: String, feePerGram: MicroTari,
              from walletID: UUID?, password: String?) async throws {
        guard let core = wallet, walletID == activeID else { throw TariError.closed }
        try await authorize(password: password, reason: "send \(XTM.format(amount)) XTM")
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

    /// Throws `PasswordNeeded` when the password has to be typed.
    func revealSeedWords(password: String?) async throws -> [String] {
        guard let core = wallet else { throw TariError.closed }
        try await authorize(password: password, reason: "show your recovery words")
        guard core === wallet else { throw TariError.closed }
        return try core.seedWords
    }

    // MARK: - Ootle (TARI)

    func setShowOotle(_ on: Bool) {
        showOotle = on
        if on { startOotle() } else { stopOotle() }
    }

    /// Opens the open wallet's Ootle wallet in the background, if the TARI side is on.
    private func startOotle() {
        guard showOotle, ootle == nil, ootleState != .opening, let core = wallet, let id = activeID,
              let profile = activeWallet, let password = sessionPassword else { return }
        let directory: URL
        do {
            directory = try store.directory(for: profile, isNew: false)
                .appendingPathComponent("ootle-\(Config.ootleNetwork)", isDirectory: true)
        } catch {
            ootleState = .failed(error.localizedDescription)
            return
        }
        ootleState = .opening
        let generation = ootleGeneration, epoch = lockEpoch, route = currentOotleRoute
        Task {
            let result = await Task.detached { () -> Result<(OotleCore, String), Error> in
                Result {
                    let opened = try OotleCore(l1: core, directory: directory, network: Config.ootleNetwork,
                                               indexerURL: Config.ootleIndexerURL, password: password)
                    return (opened, try opened.address)
                }
            }.value
            // Clew locked, switched wallets or turned Ootle off meanwhile: this one isn't wanted.
            guard ootleGeneration == generation, lockEpoch == epoch, activeID == id, wallet === core else {
                if case .success(let (opened, _)) = result { retireOotle(opened, id: id) }
                return
            }
            switch result {
            case .success(let (opened, address)):
                ootle = opened
                ootleWalletID = id
                ootleRoute = route
                ootleAddress = address
                ootleState = .ready
                if route != currentOotleRoute {  // the route changed while it was opening
                    stopOotle()
                    startOotle()
                    return
                }
                startOotlePolling()
            case .failure(let error):
                ootleState = .failed(error.localizedDescription)
            }
        }
    }

    /// Closes the Ootle wallet in the background and forgets what it showed.
    private func stopOotle() {
        ootleGeneration += 1
        ootlePoller?.cancel()
        ootlePoller = nil
        if let old = ootle, let id = ootleWalletID { retireOotle(old, id: id) }
        ootle = nil
        ootleWalletID = nil
        ootleRoute = nil
        ootleState = .off
        tariBalance = 0
        tariHistory = []
        tariMoves = []
        tariMoveProblem = nil
        ootleAddress = ""
        ootleOnline = nil
    }

    /// Shuts an Ootle wallet down in the wallet's queue of closings, so its files aren't reopened
    /// or deleted until it's done.
    private func retireOotle(_ core: OotleCore, id: UUID) {
        let previous = closing[id]
        closing[id] = Task.detached {
            await previous?.value
            core.shutdown()
        }
    }

    func retryOotle() {
        stopOotle()
        startOotle()
    }

    /// Checks with the network every two minutes while the Ootle wallet is open.
    private func startOotlePolling() {
        ootlePoller?.cancel()
        ootlePoller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshOotle()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    /// Scans for payments and claims moves from XTM that are ready, then reads the balance,
    /// history and moves. Offline, it still shows what's known.
    func refreshOotle() async {
        guard let core = ootle else { return }
        let l1 = wallet
        let generation = ootleGeneration
        let update = await Task.detached { () -> OotleUpdate in
            var update = OotleUpdate()
            update.online = (try? core.refresh()) != nil
            if let l1, update.online, let moves = try? core.moves(from: l1), moves.contains(where: { $0.status == .waiting }) {
                do {
                    update.claimProblem = try core.claimMoves(from: l1).problem
                } catch {
                    update.claimProblem = error.localizedDescription
                }
            }
            update.balance = try? core.balance
            update.history = try? core.history()
            update.moves = l1.flatMap { try? core.moves(from: $0) }
            return update
        }.value
        guard generation == ootleGeneration else { return }
        ootleOnline = update.online
        if let balance = update.balance { tariBalance = balance }
        if let history = update.history { tariHistory = history }
        if let moves = update.moves { tariMoves = moves.filter { $0.status != .claimed } }
        tariMoveProblem = update.claimProblem
    }

    private struct OotleUpdate {
        var online = false
        var balance: MicroTari?
        var history: [OotleEntry]?
        var moves: [OotleMove]?
        var claimProblem: String?
    }

    /// Runs a TARI action on the open Ootle wallet off the main thread, one at a time.
    private func withOotle<T: Sendable>(_ work: @escaping @Sendable (OotleCore) throws -> T) async throws -> T {
        guard let core = ootle, !ootleBusy else { throw OotleError.closed }
        ootleBusy = true
        defer { ootleBusy = false }
        let result = try await Task.detached { try work(core) }.value
        await refreshOotle()
        return result
    }

    /// Claims the testnet's free 1,000 tTARI into the open wallet.
    func claimTestTari() async throws {
        _ = try await withOotle { try $0.claimFaucet() }
    }

    /// The exact fee for sending, from trial runs on the network (a few seconds over Tor).
    func estimateTariFee(to address: String, amount: MicroTari) async throws -> MicroTari {
        guard let core = ootle else { throw OotleError.closed }
        return try await Task.detached { try core.estimateSendFee(to: address, amount: amount) }.value
    }

    /// Sends TARI from the wallet with id `walletID` after checking the password (or Touch ID).
    /// Returns once the network has confirmed it. Throws `PasswordNeeded` when the password has to
    /// be typed.
    func sendTari(amount: MicroTari, to address: String, maxFee: MicroTari, from walletID: UUID?,
                  password: String?) async throws {
        guard ootle != nil, walletID == ootleWalletID else { throw OotleError.closed }
        try await authorize(password: password, reason: "send \(XTM.format(amount)) tTARI")
        guard walletID == ootleWalletID else { throw OotleError.closed }
        _ = try await withOotle { try $0.send(to: address, amount: amount, maxFee: maxFee) }
    }

    /// Moves `amount` of XTM from the open wallet to its TARI side (burnt on the main chain, claimed
    /// on Ootle automatically about a day later), after checking the password (or Touch ID). Throws
    /// `PasswordNeeded` when the password has to be typed.
    func moveToTari(amount: MicroTari, feePerGram: MicroTari, from walletID: UUID?, password: String?) async throws {
        guard canMoveToTari else { throw OotleError(message: "Moving XTM to TARI opens when Ootle launches.") }
        guard let l1 = wallet, ootle != nil, walletID == activeID, walletID == ootleWalletID else {
            throw OotleError.closed
        }
        try await authorize(password: password, reason: "move \(XTM.format(amount)) XTM to TARI")
        guard l1 === wallet, walletID == ootleWalletID else { throw OotleError.closed }
        _ = try await withOotle { try $0.moveFromMainWallet(l1, amount: amount, feePerGram: feePerGram) }
        refresh()
    }

    /// The Ootle wallet's id, for screens that act on the wallet they were opened for.
    var ootleWallet: UUID? { ootleWalletID }

    // MARK: - Internals

    /// Creates a profile and folder, then opens the wallet with the current password. Undoes both on failure.
    @discardableResult
    private func add(name: String, seedWords: [String]?, epoch: Int) async throws -> WalletProfile {
        let id = UUID()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = WalletProfile(
            id: id, name: trimmed.isEmpty ? store.suggestedName() : trimmed, folder: id.uuidString,
            keychainAccount: "", backedUp: false, created: Date(), usesPassword: true,
            passwordGeneration: needsNewPassword ? 0 : sessionGeneration)
        let passphrase = try currentPassword()
        do {
            try commit { $0.wallets.append(profile) }
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

    /// Forgets a wallet, then deletes its files (and an old-style Keychain key), in that order: if a
    /// later step fails, the leftovers are never mistaken for a wallet to open.
    private func remove(_ profile: WalletProfile) throws {
        try commit { store in
            store.wallets.removeAll { $0.id == profile.id }
            if store.lastUsed == profile.id { store.lastUsed = store.wallets.first?.id }
        }
        if profile.needsPasswordSwitch { try? Vault.deletePassphrase(account: profile.keychainAccount) }
        try store.removeFiles(of: profile)
    }

    private func update(_ profile: WalletProfile) throws {
        try commit { store in
            if let index = store.wallets.firstIndex(where: { $0.id == profile.id }) { store.wallets[index] = profile }
        }
    }

    /// Changes the wallet list on disk first, and only then in memory, so the two never disagree.
    private func commit(_ change: (inout WalletStore) -> Void) throws {
        var next = store
        change(&next)
        try next.save()
        store = next
        wallets = next.wallets
    }

    private func currentPassword() throws -> String {
        guard let sessionPassword else { throw Interrupted() }  // locked in the meantime
        return sessionPassword
    }

    private func endSession() {
        sessionPassword = nil
        sessionGeneration = 0
        sessionEstablished = false
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
        stopOotle()
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
        try? commit { store in
            store.lastUsed = profile.id
            // It opened with the password Clew is unlocked with, so that's its generation.
            if sessionEstablished, passphrase == sessionPassword, profile.usesPassword == true,
               let index = store.wallets.firstIndex(where: { $0.id == profile.id }),
               store.wallets[index].generation != sessionGeneration {
                store.wallets[index].passwordGeneration = sessionGeneration
            }
        }
        refresh()
        startOotle()
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
        stopOotle()
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
        } catch TouchIDShortcut.Failure.cancelled {
            // Same.
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
