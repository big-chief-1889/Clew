#!/bin/bash
# Builds an optimized Clew and installs it as /Applications/Clew.app.
# Wallets and Keychain items are tied to the app's identity, not its location, so they carry over.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$ROOT"
[ -x Frameworks/Arti/arti ] || scripts/build-arti.sh
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

# Quit a running copy so it isn't replaced underneath itself.
osascript -e 'tell application id "app.clew.wallet" to quit' 2>/dev/null || true
sleep 1

rm -rf /Applications/Clew.app
ditto "$APP" /Applications/Clew.app
echo "Installed /Applications/Clew.app ($(du -sh /Applications/Clew.app | cut -f1))"
