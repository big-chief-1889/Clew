import AppKit

/// Clew and Clew Testnet. Tari's library runs one network family per app, so testnet wallets live
/// in a second app packed inside Clew (Contents/Helpers), with its own wallets, settings and
/// password. Switching opens the other app and quits this one.
enum NetworkSwitch {
    static var appName: String { Config.isTestnet ? "Clew Testnet" : "Clew" }
    static var title: String { Config.isTestnet ? "Switch to mainnet wallets" : "Switch to testnet wallets" }

    private static var otherApp: URL {
        let bundle = Bundle.main.bundleURL
        return Config.isTestnet
            ? bundle.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            : bundle.appendingPathComponent("Contents/Helpers/Clew Testnet.app", isDirectory: true)
    }

    private static var otherBundleIdentifier: String {
        Config.isTestnet ? "app.clew.wallet" : "app.clew.wallet.testnet"
    }

    @MainActor static func switchApps() {
        // Clew can't quit while it's re-encrypting wallets, and both apps shouldn't run then.
        if AppModel.isRekeying {
            let alert = NSAlert()
            alert.messageText = "Clew is changing your password"
            alert.informativeText = "Switch once it's finished."
            alert.runModal()
            return
        }
        // Only ever open the app that belongs here.
        if let identifier = Bundle(url: otherApp)?.bundleIdentifier, identifier != otherBundleIdentifier {
            let alert = NSAlert()
            alert.messageText = "This copy of Clew looks incomplete"
            alert.informativeText = "Reinstall Clew to switch between mainnet and testnet wallets."
            alert.runModal()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: otherApp, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    NSAlert(error: error).runModal()
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
