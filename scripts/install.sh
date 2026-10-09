#!/bin/bash
# Builds an optimized Clew and installs it as /Applications/Clew.app.
# Wallets and Keychain items are tied to the app's identity, not its location, so they carry over.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$ROOT"
[ -x Frameworks/Arti/arti ] || scripts/build-arti.sh
[ -f Frameworks/TariFFI/libclew_core.a ] && [ -f Frameworks/TariFFI-testnet/libclew_core.a ] || scripts/build-ffi.sh
scripts/generate-project.sh
mkdir -p build
if ! xcodebuild -project Clew.xcodeproj -scheme Clew -configuration Release \
     -derivedDataPath build/DerivedData -allowProvisioningUpdates build > build/xcodebuild.log 2>&1; then
  { grep -E 'error:' build/xcodebuild.log || true; } | sort -u | head -20
  echo "Build failed; the installed Clew was not changed. Full log: build/xcodebuild.log" >&2
  exit 1
fi
echo "** BUILD SUCCEEDED **"

APP="build/DerivedData/Build/Products/Release/Clew.app"
codesign --verify --deep --strict "$APP"

# Quit running copies (Clew Testnet is inside Clew) so they aren't replaced underneath themselves.
osascript -e 'tell application id "app.clew.wallet" to quit' 2>/dev/null || true
osascript -e 'tell application id "app.clew.wallet.testnet" to quit' 2>/dev/null || true
sleep 1

rm -rf /Applications/Clew.app
ditto "$APP" /Applications/Clew.app
# Copies of Clew left in build/ (same app ID) can hide the installed one from the Dock's Apps view
# and Launchpad, so they're removed and forgotten once installed.
rm -rf build/DerivedData/Build/Products/Release/*.app
scripts/unregister-build-copies.sh
echo "Installed /Applications/Clew.app ($(du -sh /Applications/Clew.app | cut -f1))"
