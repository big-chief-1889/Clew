// Checks a freshly built wallet library end to end: creates a throwaway wallet in a temp folder,
// connects through the given proxy, and waits until it's online and has scanned blocks.
// Used by scripts/update.sh before anything is installed.
//
// Usage: wallet-check <empty temp dir> <network> <node url> <proxy url>
import Foundation
import TariFFI

let args = CommandLine.arguments
guard args.count == 5 else {
    print("usage: wallet-check <dir> <network> <node url> <proxy url>")
    exit(2)
}
let (dir, network, node, proxy) = (args[1], args[2], args[3], args[4])

final class Status { var online = false; var height: UInt64 = 0 }
let status = Status()
let context = Unmanaged.passUnretained(status).toOpaque()
func status(_ ctx: UnsafeMutableRawPointer?) -> Status { Unmanaged<Status>.fromOpaque(ctx!).takeUnretainedValue() }

var err: Int32 = 0
guard wallet_set_http_proxy(proxy, &err), err == 0 else { print("FAIL: proxy not accepted (\(err))"); exit(1) }
let config = wallet_db_config_create("check", dir, &err)
var recovering = false
let wallet = wallet_create(
    context, config, dir + "/wallet.log", 2, 1, 1_000_000,
    "throwaway-check-passphrase", nil, nil, network, node, 0,
    { _, tx in pending_inbound_transaction_destroy(tx) },
    { _, tx in completed_transaction_destroy(tx) }, { _, tx in completed_transaction_destroy(tx) },
    { _, tx in completed_transaction_destroy(tx) }, { _, tx in completed_transaction_destroy(tx) },
    { _, tx, _ in completed_transaction_destroy(tx) }, { _, tx in completed_transaction_destroy(tx) },
    { _, tx, _ in completed_transaction_destroy(tx) }, { _, _, s in transaction_send_status_destroy(s) },
    { _, tx, _ in completed_transaction_destroy(tx) }, { _, _, _ in },
    { _, b in balance_destroy(b) }, { _, _, _ in },
    { ctx, state, _ in status(ctx).online = state == 1 },
    { ctx, height in status(ctx).height = height },
    { _, _ in },
    &recovering, &err)
guard let wallet, err == 0 else { print("FAIL: couldn't create a wallet (error \(err))"); exit(1) }

let address = wallet_get_tari_one_sided_address(wallet, &err)
print("Created a throwaway \(network) wallet")

// Wait up to 3 minutes for it to connect and scan.
let deadline = Date().addingTimeInterval(180)
while Date() < deadline && !(status.online && status.height > 0) {
    Thread.sleep(forTimeInterval: 1)
}
let ok = status.online && status.height > 0
print(ok ? "OK: online through Tor, scanned to block \(status.height)"
         : "FAIL: online=\(status.online), scanned height=\(status.height)")

tari_address_destroy(address)
wallet_destroy(wallet)
wallet_db_config_destroy(config)
exit(ok ? 0 : 1)
