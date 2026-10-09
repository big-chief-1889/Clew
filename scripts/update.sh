#!/bin/bash
# One-command update of Clew's two outside components: Tari's wallet library and Arti (Tor).
#
#   scripts/update.sh          show what's new and ask before updating
#   scripts/update.sh --yes    update without asking
#
# 1. Looks up the newest stable Tari release, and the newest Arti release that's at least
#    ARTI_MIN_AGE_DAYS old (time for problems to surface before Clew uses it).
# 2. Rebuilds whichever changed: Tari's library with Clew's patch, and/or Arti.
# 3. Checks a throwaway wallet connects and syncs through the new Tor (scripts/check-wallet.sh).
# 4. Builds and installs Clew.
# If any step fails, every file is put back and the installed Clew is left untouched.
#
# Ootle (vendor/tari-ootle) isn't updated here: it is pre-release, with breaking changes most
# weeks, so it moves only by hand (OOTLE_TAG in build-ffi.sh plus its patch).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TARI="$ROOT/vendor/tari"
BACKUP="$ROOT/build/update-backup"
ARTI_MIN_AGE_DAYS=14
ASSUME_YES=false
[ "${1:-}" = "--yes" ] && ASSUME_YES=true

current_tari="$(sed -n 's/^TARI_TAG="\(.*\)"/\1/p' scripts/build-ffi.sh)"
current_arti="$(sed -n 's/^ARTI_VERSION="\(.*\)"/\1/p' scripts/build-arti.sh)"

# "a < b" for versions like v6.1.0 / 2.6.0
newer() { python3 -c '
import re, sys
v = lambda s: tuple(int(n) for n in re.findall(r"\d+", s))
sys.exit(0 if v(sys.argv[2]) > v(sys.argv[1]) else 1)' "$1" "$2"; }

echo "Checking for new releases…"
latest_tari="$(curl -fsS 'https://api.github.com/repos/tari-project/tari/releases?per_page=40' | python3 -c '
import json, re, sys
stable = [r["tag_name"] for r in json.load(sys.stdin) if not r["prerelease"] and not r["draft"]]
v = lambda s: tuple(int(n) for n in re.findall(r"\d+", s))
print(max(stable, key=v))')"
latest_arti="$(curl -fsS -H 'User-Agent: clew-updater' 'https://crates.io/api/v1/crates/arti' | python3 -c '
import datetime, json, re, sys
min_age = datetime.timedelta(days=int(sys.argv[1]))
now = datetime.datetime.now(datetime.timezone.utc)
v = lambda s: tuple(int(n) for n in re.findall(r"\d+", s))
ok = [x["num"] for x in json.load(sys.stdin)["versions"]
      if not x["yanked"] and "-" not in x["num"]
      and now - datetime.datetime.fromisoformat(x["created_at"].replace("Z", "+00:00")) >= min_age]
print(max(ok, key=v))' "$ARTI_MIN_AGE_DAYS")"

update_tari=false; newer "$current_tari" "$latest_tari" && update_tari=true
update_arti=false; newer "$current_arti" "$latest_arti" && update_arti=true

printf '\n%-14s %-10s %s\n' "" "current" "available"
printf '%-14s %-10s %s\n' "Tari wallet" "$current_tari" "$($update_tari && echo "$latest_tari  https://github.com/tari-project/tari/releases/tag/$latest_tari" || echo "up to date")"
printf '%-14s %-10s %s\n\n' "Arti (Tor)" "$current_arti" "$($update_arti && echo "$latest_arti  https://gitlab.torproject.org/tpo/core/arti/-/blob/main/CHANGELOG.md" || echo "up to date (newest $ARTI_MIN_AGE_DAYS+ days old)")"

if ! $update_tari && ! $update_arti; then
  echo "Clew is up to date."
  exit 0
fi

if ! $ASSUME_YES; then
  $update_tari && echo "Note: a new Tari version may upgrade your wallet files the first time Clew opens them, and older versions may not read them afterwards."
  read -r -p "Update and reinstall Clew? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "Nothing changed."; exit 0; }
fi

# --- Safety net: back up everything this script changes ---------------------------------
rm -rf "$BACKUP" && mkdir -p "$BACKUP"
cp -R Frameworks/TariFFI Frameworks/TariFFI-testnet Frameworks/Arti patches Config "$BACKUP/"
cp scripts/build-ffi.sh scripts/build-arti.sh project.yml rust/clew-core/Cargo.lock "$BACKUP/"
tari_moved=false

rollback() {
  trap - ERR INT
  echo
  echo "Update failed — putting everything back. Your installed Clew hasn't been touched."
  rm -rf Frameworks/TariFFI Frameworks/TariFFI-testnet Frameworks/Arti patches Config
  cp -R "$BACKUP/TariFFI" "$BACKUP/TariFFI-testnet" "$BACKUP/Arti" Frameworks/
  cp -R "$BACKUP/patches" "$BACKUP/Config" .
  cp "$BACKUP/build-ffi.sh" "$BACKUP/build-arti.sh" scripts/
  cp "$BACKUP/project.yml" .
  cp "$BACKUP/Cargo.lock" rust/clew-core/
  if $tari_moved; then
    git -C "$TARI" reset -q --hard
    git -C "$TARI" checkout -q "$current_tari"
    git -C "$TARI" apply -N "patches/tari-$current_tari-clew.patch"
  fi
  exit 1
}
trap rollback ERR INT

# --- Tari ---------------------------------------------------------------------------------
if $update_tari; then
  saved="patches/tari-$current_tari-clew.patch"
  # The vendor folder must hold exactly Clew's saved patch, so resetting it loses nothing.
  if ! diff -q <(git -C "$TARI" diff -- . ':(exclude)Cargo.lock' ':(exclude)base_layer/wallet_ffi/wallet.h') \
       "$saved" > /dev/null; then
    echo "vendor/tari has changes that aren't in $saved. Stopping so they aren't lost."
    false
  fi
  echo "Fetching Tari $latest_tari…"
  tari_moved=true
  git -C "$TARI" reset -q --hard
  git -C "$TARI" fetch -q --depth 1 origin tag "$latest_tari"
  git -C "$TARI" checkout -q "$latest_tari"
  if ! git -C "$TARI" apply --check "$saved" 2>/dev/null; then
    echo "Clew's changes to Tari don't apply to $latest_tari: the code they touch has changed."
    echo "This one needs a manual update: port $saved to $latest_tari."
    false
  fi
  git mv -f "$saved" "patches/tari-$latest_tari-clew.patch" 2>/dev/null \
    || mv "$saved" "patches/tari-$latest_tari-clew.patch"
  sed -i '' "s/^TARI_TAG=\".*\"/TARI_TAG=\"$latest_tari\"/" scripts/build-ffi.sh
  # Let clew-core's lockfile follow the new Tari crates, changing as little else as it can.
  git -C "$TARI" apply -N "patches/tari-$latest_tari-clew.patch"
  cargo update --manifest-path "$TARI/Cargo.toml" --workspace --offline --quiet
  cargo metadata --manifest-path rust/clew-core/Cargo.toml --format-version 1 > /dev/null
  echo "Building Tari's wallet libraries, mainnet and testnet (this takes a while)…"
  scripts/build-ffi.sh > build/update-ffi.log 2>&1 \
    || { tail -20 build/update-ffi.log; false; }

  # Point out interface changes, so a human can check Clew still uses the library correctly.
  api() { grep -oE '\b[a-z_0-9]+\(' "$1" | sort -u; }
  changed="$(diff <(api "$BACKUP/TariFFI/wallet.h") <(api Frameworks/TariFFI/wallet.h) | grep -E '^[<>]' || true)"
  if [ -n "$changed" ]; then
    echo "The library's functions changed (added '>' / removed '<'):"
    echo "$changed" | sed 's/^/   /'
  fi
fi

# --- Arti ---------------------------------------------------------------------------------
if $update_arti; then
  sed -i '' "s/^ARTI_VERSION=\".*\"/ARTI_VERSION=\"$latest_arti\"/" scripts/build-arti.sh
  echo "Building Arti $latest_arti (this takes a few minutes)…"
  scripts/build-arti.sh > build/update-arti.log 2>&1 || { tail -20 build/update-arti.log; false; }
fi

# --- Check, then install -------------------------------------------------------------------
echo "Checking a throwaway wallet syncs through the new Tor…"
scripts/check-wallet.sh

python3 - <<'EOF'
import re
p = "project.yml"
s = open(p).read()
s = re.sub(r'MARKETING_VERSION: "(\d+)\.(\d+)\.(\d+)"',
           lambda m: f'MARKETING_VERSION: "{m[1]}.{m[2]}.{int(m[3]) + 1}"', s)
open(p, "w").write(s)
EOF

echo "Building and installing Clew…"
scripts/install.sh

trap - ERR INT
echo
$update_tari && echo "Tari wallet: $current_tari → $latest_tari"
$update_arti && echo "Arti (Tor):  $current_arti → $latest_arti"
echo "Clew $(plutil -extract CFBundleShortVersionString raw /Applications/Clew.app/Contents/Info.plist) is installed. Previous files are kept in build/update-backup."
