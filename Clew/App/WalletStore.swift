import Foundation

/// A wallet's local, non-secret details. Secrets live in the wallet's own encrypted
/// database and in its Keychain item.
struct WalletProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var folder: String            // subfolder of the network directory
    var keychainAccount: String     // only for wallets made before passwords (0.6 and earlier)
    var backedUp: Bool
    var created: Date
    /// True once the wallet is encrypted with the user's password. Older wallets used a random
    /// passphrase kept in the Keychain until they're switched over.
    var usesPassword: Bool? = nil
    /// Which password the wallet is on. Every password change gives the wallets it re-encrypts the
    /// next number, so after an interrupted change Clew knows which password is the newest.
    /// -1 means an earlier password Clew can't identify.
    var passwordGeneration: Int? = nil

    var needsPasswordSwitch: Bool { usesPassword != true }
    var generation: Int { passwordGeneration ?? 0 }
}

/// The list of wallets on this Mac for the current network, saved as wallets.json.
///
/// Layout: Application Support/Clew/<network>/
///             wallets.json
///             <wallet-id>/clew.sqlite3, wallet.log …
struct WalletStore: Codable {
    var wallets: [WalletProfile] = []
    var lastUsed: UUID?

    static func load() throws -> WalletStore {
        try migrateSingleWalletLayout()
        let file = try networkDirectory().appendingPathComponent("wallets.json")
        // No file yet means no wallets. A file that exists but can't be read is an error, never an
        // empty list that a new wallet would then overwrite.
        guard FileManager.default.fileExists(atPath: file.path) else { return WalletStore() }
        return try JSONDecoder().decode(WalletStore.self, from: Data(contentsOf: file))
    }

    func save() throws {
        let file = try Self.networkDirectory().appendingPathComponent("wallets.json")
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }

    enum Problem: LocalizedError {
        case filesMissing(String), migrationConflict
        var errorDescription: String? {
            switch self {
            case .filesMissing(let name):
                "“\(name)” can't be opened because its files are missing from this Mac. Restore it from its recovery words."
            case .migrationConflict:
                "Clew found an old-style wallet file next to an already-moved one and stopped so nothing is overwritten. Your wallets haven't been changed."
            }
        }
    }

    /// The wallet's folder. For a new wallet it's created; an existing wallet's folder must already
    /// hold its database, so a lost folder is never silently replaced by a brand-new empty wallet.
    func directory(for wallet: WalletProfile, isNew: Bool) throws -> URL {
        let directory = try Self.networkDirectory().appendingPathComponent(wallet.folder, isDirectory: true)
        if isNew {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } else if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("clew.sqlite3").path) {
            throw Problem.filesMissing(wallet.name)
        }
        return directory
    }

    /// Deletes log files written before Clew turned the wallet library's logging off (0.5.3),
    /// in every network's wallet folders and backups.
    static func deleteOldLogs() {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: false).appendingPathComponent("Clew"),
              let files = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in files where file.lastPathComponent.hasPrefix("wallet.log") {
            try? fm.removeItem(at: file)
        }
    }

    /// Clew 0.7 kept a TARI side on Ootle's testnet inside mainnet wallets (in "ootle-<testnet>"
    /// folders). Testnet now lives only in Clew Testnet, so the mainnet app removes those folders.
    /// Only folders inside this app's wallet folders are touched, and never the wallet files.
    static func deleteTestnetOotleData() {
        guard !Config.isTestnet else { return }
        let fm = FileManager.default
        guard let wallets = try? fm.contentsOfDirectory(at: networkDirectory(), includingPropertiesForKeys: [.isDirectoryKey])
        else { return }
        for wallet in wallets {
            for network in ["esmeralda", "igor", "localnet"] {
                let leftover = wallet.appendingPathComponent("ootle-\(network)", isDirectory: true)
                if fm.fileExists(atPath: leftover.path) { try? fm.removeItem(at: leftover) }
            }
        }
        UserDefaults.standard.removeObject(forKey: "showOotleTestnet")
    }

    func removeFiles(of wallet: WalletProfile) throws {
        guard !wallet.folder.isEmpty else { return }  // never delete the network directory itself
        let directory = try Self.networkDirectory().appendingPathComponent(wallet.folder, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// A name like "Wallet 2" that isn't taken yet.
    func suggestedName() -> String {
        if wallets.isEmpty { return "Main wallet" }
        var n = wallets.count + 1
        while wallets.contains(where: { $0.name == "Wallet \(n)" }) { n += 1 }
        return "Wallet \(n)"
    }

    static func networkDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("Clew/\(Config.network)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Version 0.1 kept a single wallet's files directly in the network directory, with the
    /// Keychain item "wallet-db-passphrase.<network>". Move it into its own folder as "Main wallet",
    /// keeping its Keychain item, after first copying the files to a backup folder.
    private static func migrateSingleWalletLayout() throws {
        let fm = FileManager.default
        let root = try networkDirectory()
        let legacyFiles = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
            .filter { $0.lastPathComponent.hasPrefix("clew.sqlite3") || $0.lastPathComponent.hasPrefix("wallet.log") }
        guard legacyFiles.contains(where: { $0.lastPathComponent == "clew.sqlite3" }) else { return }

        // Record the wallet first, so an interrupted migration resumes into the same folder.
        let legacyAccount = "wallet-db-passphrase.\(Config.network)"
        var store = (try? JSONDecoder().decode(WalletStore.self,
                                               from: Data(contentsOf: root.appendingPathComponent("wallets.json"))))
            ?? WalletStore()
        let profile = store.wallets.first { $0.keychainAccount == legacyAccount } ?? {
            let id = UUID()
            let profile = WalletProfile(
                id: id, name: "Main wallet", folder: id.uuidString, keychainAccount: legacyAccount,
                backedUp: UserDefaults.standard.bool(forKey: "backedUp.\(Config.network)"), created: Date())
            store.wallets.insert(profile, at: 0)
            return profile
        }()
        store.lastUsed = profile.id
        try store.save()

        let backup = root.appendingPathComponent("backup-before-multi-wallet", isDirectory: true)
        let target = root.appendingPathComponent(profile.folder, isDirectory: true)
        // A database already in the target means the move finished earlier; never overwrite it.
        guard !fm.fileExists(atPath: target.appendingPathComponent("clew.sqlite3").path) else {
            throw Problem.migrationConflict
        }
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for file in legacyFiles {
            // Copy under a temporary name first, so a copy cut short by a crash is redone next time.
            let copy = backup.appendingPathComponent(file.lastPathComponent)
            let partial = backup.appendingPathComponent(file.lastPathComponent + ".partial")
            guard !fm.fileExists(atPath: copy.path) else { continue }
            try? fm.removeItem(at: partial)
            try fm.copyItem(at: file, to: partial)
            try fm.moveItem(at: partial, to: copy)
        }
        // The database goes last: while it's still in the root, the migration isn't finished.
        let isDatabase = { (file: URL) in file.lastPathComponent == "clew.sqlite3" }
        for file in legacyFiles.filter({ !isDatabase($0) }) + legacyFiles.filter(isDatabase) {
            let destination = target.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: file, to: destination)
        }
    }
}
