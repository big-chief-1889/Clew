# Clew

Small, private wallet for [Tari](https://tari.com) (XTM) on the Mac. It runs Tari's own wallet library and sends everything over Tor.

Make a wallet or restore one from your 24 words, then send and receive XTM. Your keys stay on your Mac, locked with your password.

- create or restore wallets from 24 recovery words, and keep as many as you want side by side
- send and receive one-sided (stealth) payments, with a QR code for your address
- wallet files are encrypted with your password, and Touch ID can be turned on as a shortcut
- all wallet traffic goes over Tor by default (Arti is built in). If Tor is down it stays offline instead of connecting directly
- only talks to the node you pick (`rpc.tari.com` by default), no silent fallback to another server
- fees come from the node's mempool when the network is busy, capped at 100 µT per gram
- payment references, so you can prove you paid someone
- a TARI side for Ootle, Tari's layer 2: a preview until Ootle launches, working on Ootle's testnet in Clew Testnet
- no accounts, no analytics, no log files

Runs on:

- Mac: Apple Silicon, macOS 14 or later (SwiftUI)
- Tari mainnet, plus Clew Testnet for Tari's testnet (inside Clew, see below)

> **Heads up:** Clew hasn't been audited. Start with small amounts and keep your 24 words on paper.

## Download

Get the latest build from Releases. Unzip it and drag Clew to Applications.

The app isn't notarized by Apple, so the first time you open it macOS will block it. Go to System Settings > Privacy & Security, scroll down and click Open Anyway.

Check the download against `SHA256SUMS.txt` from the same release:

```sh
shasum -a 256 Clew-*-mac.zip
```

## Building

You need Xcode, Rust (`rustup`), and `protobuf` and `xcodegen` from Homebrew.

```sh
brew install protobuf xcodegen
git clone --depth 1 --branch v6.1.0 https://github.com/tari-project/tari.git vendor/tari
git clone --depth 1 --branch v0.45.0 https://github.com/tari-project/tari-ootle.git vendor/tari-ootle
scripts/build-ffi.sh
scripts/build-arti.sh
scripts/release.sh
```

Builds `build/release/Clew-<version>-mac.zip`, the same thing that goes in a release. No Apple developer account needed.

- `build-ffi.sh` applies Clew's patches to Tari and Ootle and builds `rust/clew-core`, Tari's wallet library (`minotari_wallet_ffi`) plus a wallet for Ootle, Tari's layer 2. Tari builds its library for one network family, so it builds two: mainnet into `Frameworks/TariFFI` and testnet into `Frameworks/TariFFI-testnet`, each with its settings in `Config/`
- `build-arti.sh` builds Arti 2.6.0 from crates.io with `--locked`
- `release.sh` rebuilds both with your home folder remapped out of the file paths, builds Clew, signs it ad-hoc, and scans every file in the app for your username and home folder before zipping it. Add more things to look for with `CLEW_RELEASE_FORBIDDEN="Your Name|you@example.com" scripts/release.sh`

If you have an Apple Development certificate, `scripts/install.sh` builds a copy signed with it and puts it straight in /Applications. Your team ID isn't stored in the repo, `scripts/generate-project.sh` reads it from your certificate. Wallets made with Clew 0.6 or earlier need this signed copy once, to switch from the Keychain to a password.

Clew Testnet is the same app built for Tari's testnet (Esmeralda) and Ootle's testnet, with an orange icon. It ships inside Clew (`Contents/Helpers`), and "Switch to testnet wallets" in the wallet list, on the lock screen or on the welcome screen opens it and quits Clew ("Switch to mainnet wallets" goes back). It's a separate app to macOS, so it has its own wallets, settings and password, and testnet coins never mix with real ones.

If you change Tari's or Ootle's source, regenerate the patch:

```sh
git -C vendor/tari diff -- . ':(exclude)Cargo.lock' ':(exclude)base_layer/wallet_ffi/wallet.h' > patches/tari-v6.1.0-clew.patch
git -C vendor/tari-ootle diff > patches/tari-ootle-v0.45.0-clew.patch
```

## Updating

```sh
scripts/update.sh
```

Checks for a newer stable Tari release and an Arti release that's at least two weeks old. If there is one it rebuilds it, has a throwaway mainnet wallet sync through the new Tor (`scripts/check-wallet.sh`), and only then installs. If anything fails it puts every file back and leaves the installed app alone. If the patch no longer applies to a new Tari release it stops and tells you. Ootle isn't updated this way while it's pre-release; it moves by hand.

## Notes

- The patch adds `wallet_set_http_proxy` and `wallet_change_passphrase` to Tari's FFI, and stops the wallet falling back to Tari's own server when your node doesn't answer.
- Tari's wallet makes a new HTTP client for every request, so the proxy setting applies right away. Each wallet uses its own SOCKS username, so Tor gives it separate circuits.
- The node still sees the transactions you send, just not your IP. Running your own node fixes that. Set its address in wallet settings (https, or http for localhost and .onion).
- Wallets live in `~/Library/Containers/app.clew.wallet/Data/Library/Application Support/Clew/<network>/` (Clew Testnet's in `app.clew.wallet.testnet`), one folder per wallet, listed in `wallets.json`.
- Your password encrypts the keys and seed inside each wallet database (Tari uses Argon2id for this). The transaction history isn't encrypted, so the app sandbox and FileVault are what protect it. There's no minimum length, so how strong it is is up to you.
- One unlock opens all your wallets until Clew locks (sleep, screen lock, or the lock button). Sending, showing recovery words and deleting a wallet ask for the password again.
- The Touch ID shortcut encrypts your password to a key in the Mac's Secure Enclave, so it only works on that Mac, and only with a fingerprint (not the Mac's login password). It doesn't need the Keychain or a developer certificate.
- Changing the password re-encrypts the wallet's key, not the whole file, so an older backup of a wallet (Time Machine etc.) still opens with the password it had back then.
- Forget the password and the only way back in is your recovery words.
- `scripts/make-icon.swift` draws the icon.

## License

BSD 3-Clause, see [LICENSE](LICENSE). Tari and Ootle are BSD 3-Clause too, and `patches/` holds changes to their code under that license. Arti is MIT or Apache 2.0.
