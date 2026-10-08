#!/bin/bash
# Builds Arti (the Tor Project's Rust Tor client) and signs it as a sandboxed helper for Clew.
# The signed binary goes to Frameworks/Arti/arti; Xcode copies it into Clew.app/Contents/MacOS.
set -euo pipefail

ARTI_VERSION="2.6.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Frameworks/Arti"

export MACOSX_DEPLOYMENT_TARGET=14.0
if [ "$("$ROOT/build/arti/bin/arti" --version 2>/dev/null | awk '{print $2}')" != "$ARTI_VERSION" ]; then
  # --locked builds with the exact dependency versions the Arti release was tested with.
  cargo install arti --version "$ARTI_VERSION" --locked --root "$ROOT/build/arti" --force
fi

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')}"
[ -n "$IDENTITY" ] || { echo "No Apple Development signing identity found" >&2; exit 1; }

mkdir -p "$OUT"
cp "$ROOT/build/arti/bin/arti" "$OUT/arti"
# Runs inside Clew's sandbox (inherit), with the hardened runtime.
codesign --force --options runtime --timestamp=none \
  --entitlements "$ROOT/Clew/ArtiHelper.entitlements" --sign "$IDENTITY" "$OUT/arti"
echo "$ARTI_VERSION" > "$OUT/VERSION"
echo "Signed Arti $ARTI_VERSION -> $OUT/arti"
