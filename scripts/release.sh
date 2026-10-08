#!/bin/bash
# Builds a downloadable Clew: build/release/Clew-<version>-mac.zip plus SHA256SUMS.txt.
#
# The release is ad-hoc signed (no developer certificate, so no name or team in it) and built with
# the build machine's paths remapped, so it doesn't contain your home folder or username. It ends
# with a scan of every file in the app and fails if anything identifying is found.
# Nothing is uploaded.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export MACOSX_DEPLOYMENT_TARGET=14.0
OUT="$ROOT/build/release"
STAGE="$OUT/stage"
ARTI_VERSION="$(sed -n 's/^ARTI_VERSION="\(.*\)"/\1/p' scripts/build-arti.sh)"
VERSION="$(sed -n 's/.*MARKETING_VERSION: "\(.*\)".*/\1/p' project.yml)"

# Things that must not appear anywhere in the release. Extra ones (your name, email) can be added
# with CLEW_RELEASE_FORBIDDEN="Name|email@example.com".
FORBIDDEN="$HOME|/Users/$USER|$USER"
[ -n "${CLEW_RELEASE_FORBIDDEN:-}" ] && FORBIDDEN="$FORBIDDEN|$CLEW_RELEASE_FORBIDDEN"

# Remap paths in compiled code: the repo becomes /clew, the rest of the home folder /build.
# For rustc the last matching rule wins, so the more specific one goes last.
export RUSTFLAGS="--remap-path-prefix=$HOME=/build --remap-path-prefix=$ROOT=/clew"
export CFLAGS="-ffile-prefix-map=$HOME=/build -ffile-prefix-map=$ROOT=/clew"
export CXXFLAGS="$CFLAGS"

rm -rf "$OUT" && mkdir -p "$STAGE/TariFFI"

echo "Building Tari's wallet library with remapped paths (a few minutes)…"
NETWORK="$(sed -n 's/.*static let network = "\(.*\)".*/\1/p' Clew/App/Config.swift)"
[ "$NETWORK" = mainnet ] && BUILD_NETWORK=mainnet || BUILD_NETWORK=esme
CARGO_TARGET_DIR="$ROOT/build/release-cargo" scripts/build-ffi.sh "$BUILD_NETWORK" > "$OUT/ffi.log" 2>&1 \
  || { tail -20 "$OUT/ffi.log"; exit 1; }
cp Frameworks/TariFFI/libminotari_wallet_ffi.a "$STAGE/TariFFI/"
cp Frameworks/TariFFI/wallet.h Frameworks/TariFFI/module.modulemap "$STAGE/TariFFI/"

echo "Building Arti $ARTI_VERSION with remapped paths (a few minutes)…"
CARGO_TARGET_DIR="$ROOT/build/release-arti-target" cargo install arti --version "$ARTI_VERSION" --locked \
  --root "$ROOT/build/release-arti" --force > "$OUT/arti.log" 2>&1 || { tail -20 "$OUT/arti.log"; exit 1; }

echo "Building Clew $VERSION…"
CLEW_TEAM_ID="" xcodegen generate --quiet
PREFIX_MAPS="-file-prefix-map $HOME=/build -file-prefix-map $ROOT=/clew"
xcodebuild -project Clew.xcodeproj -scheme Clew -configuration Release \
  -derivedDataPath "$ROOT/build/release-derived" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
  LIBRARY_SEARCH_PATHS="$STAGE/TariFFI" SWIFT_INCLUDE_PATHS="$STAGE/TariFFI" \
  OTHER_SWIFT_FLAGS="$PREFIX_MAPS" OTHER_CFLAGS="-ffile-prefix-map=$HOME=/build -ffile-prefix-map=$ROOT=/clew" \
  DEBUG_INFORMATION_FORMAT=dwarf DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES \
  build > "$OUT/xcodebuild.log" 2>&1 || { grep -E 'error:' "$OUT/xcodebuild.log" | sort -u | head; exit 1; }
scripts/generate-project.sh   # put the normal (signed) project back for install.sh

APP="$OUT/Clew.app"
ditto "$ROOT/build/release-derived/Build/Products/Release/Clew.app" "$APP"
# Swap in the remapped Arti, then sign everything ad-hoc (helper first, then the app around it).
cp "$ROOT/build/release-arti/bin/arti" "$APP/Contents/MacOS/arti"
strip -x "$APP/Contents/MacOS/arti" 2>/dev/null || true
codesign --force --sign - --options runtime --timestamp=none \
  --entitlements Clew/ArtiHelper.entitlements "$APP/Contents/MacOS/arti"
codesign --force --sign - --options runtime --timestamp=none \
  --entitlements Clew/ClewRelease.entitlements "$APP"
codesign --verify --deep --strict "$APP"

echo "Scanning the app for anything identifying…"
found=0
while IFS= read -r -d '' file; do
  if LC_ALL=C grep -a -q -E "$FORBIDDEN" "$file"; then
    echo "  found in ${file#$APP/}: $(LC_ALL=C strings -a "$file" | grep -E "$FORBIDDEN" | sort -u | head -3 | tr '\n' ' ')"
    found=1
  fi
done < <(find "$APP" -type f -print0)
if codesign -dvv "$APP" 2>&1 | grep -qE 'Authority=|TeamIdentifier=[A-Z0-9]'; then
  echo "  the signature contains a certificate or team"; found=1
fi
[ "$found" = 0 ] || { echo "Release NOT made: remove the items above first." >&2; exit 1; }
echo "  clean"

# Zip timestamps have no time zone, so write them in UTC rather than local time.
ZIP="Clew-$VERSION-mac.zip"
(cd "$OUT" && TZ=UTC ditto -c -k --norsrc --noextattr --noqtn --keepParent Clew.app "$ZIP" && shasum -a 256 "$ZIP" > SHA256SUMS.txt)
rm -rf "$STAGE"
echo "Done: build/release/$ZIP ($(du -h "$OUT/$ZIP" | cut -f1)) and build/release/SHA256SUMS.txt"
