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

    @MainActor static func switchApps() {
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
