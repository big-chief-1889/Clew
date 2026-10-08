# Clew

Small, private wallet for [Tari](https://tari.com) (XTM) on the Mac. It runs Tari's own wallet library and sends everything over Tor.

Make a wallet or restore one from your 24 words, then send and receive XTM. Your keys stay on your Mac, locked behind Touch ID.

- create or restore wallets from 24 recovery words, and keep as many as you want side by side
- send and receive one-sided (stealth) payments, with a QR code for your address
- the wallet file is encrypted and its passphrase lives in the Keychain behind Touch ID
- all wallet traffic goes over Tor by default (Arti is built in). If Tor is down it stays offline instead of connecting directly
- only talks to the node you pick (`rpc.tari.com` by default), no silent fallback to another server
- fees come from the node's mempool when the network is busy, capped at 100 µT per gram
- payment references, so you can prove you paid someone
- no accounts, no analytics, no log files

Runs on:

- Mac: Apple Silicon, macOS 14 or later (SwiftUI)
- Tari mainnet. A testnet build is a couple of commands away, see below

> **Heads up:** Clew hasn't been audited. Start with small amounts and keep your 24 words on paper.

## Building

You need Xcode, Rust (`rustup`), `protobuf` and `xcodegen` from Homebrew, and an Apple Development signing certificate set up in Xcode.

```sh
brew install protobuf xcodegen
git clone --depth 1 --branch v6.1.0 https://github.com/tari-project/tari.git vendor/tari
scripts/build-ffi.sh mainnet
scripts/build-arti.sh
scripts/install.sh
```

- `build-ffi.sh` applies `patches/tari-v6.1.0-clew.patch` to Tari and builds its wallet library (`minotari_wallet_ffi`) into `Frameworks/TariFFI`. It also writes `Clew/App/Config.swift` for the network you picked
- `build-arti.sh` builds Arti 2.6.0 from crates.io with `--locked` and signs it as a sandboxed helper
- `install.sh` generates the Xcode project, builds a Release copy and puts it in /Applications. Your team ID isn't stored in the repo, `scripts/generate-project.sh` reads it from your signing certificate

For testnet (Esmeralda) run `scripts/build-ffi.sh esme` and then `scripts/install.sh`. Each network keeps its own wallets, Keychain items and settings, so they never mix.

If you change Tari's source, regenerate the patch:

```sh
git -C vendor/tari diff -- . ':(exclude)Cargo.lock' ':(exclude)base_layer/wallet_ffi/wallet.h' > patches/tari-v6.1.0-clew.patch
```

## Updating

```sh
scripts/update.sh
```

Checks for a newer stable Tari release and an Arti release that's at least two weeks old. If there is one it rebuilds it, has a throwaway mainnet wallet sync through the new Tor (`scripts/check-wallet.sh`), and only then installs. If anything fails it puts every file back and leaves the installed app alone. If the patch no longer applies to a new Tari release it stops and tells you.

## Notes

- The patch adds `wallet_set_http_proxy` to Tari's FFI and stops the wallet falling back to Tari's own server when your node doesn't answer.
- Tari's wallet makes a new HTTP client for every request, so the proxy setting applies right away. Each wallet uses its own SOCKS username, so Tor gives it separate circuits.
- The node still sees the transactions you send, just not your IP. Running your own node fixes that. Set its address in wallet settings (https, or http for localhost and .onion).
- Wallets live in `~/Library/Containers/app.clew.wallet/Data/Library/Application Support/Clew/<network>/`, one folder per wallet, listed in `wallets.json`. Each one has its own Keychain item.
- Keys and the seed are encrypted inside the wallet database, but the transaction history isn't. The app sandbox and FileVault are what protect it.
- One unlock opens all your wallets until Clew locks (sleep, screen lock, or the lock button). Sending, showing recovery words and deleting a wallet ask for Touch ID again.
- `scripts/make-icon.swift` draws the icon.

## License

BSD 3-Clause, see [LICENSE](LICENSE). Tari is BSD 3-Clause too, and `patches/` holds changes to Tari's code under its license. Arti is MIT or Apache 2.0.
