#!/bin/bash
# End-to-end check of the built wallet library and Tor helper, before they're installed:
# starts the new Arti build, then has a throwaway wallet connect and sync through it.
# Uses temporary folders that are deleted afterwards. Exit code 0 = passed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
NETWORK="$(sed -n 's/.*static let network = "\(.*\)".*/\1/p' "$ROOT/Clew/App/Config.swift")"
NODE="$(sed -n 's/.*static let defaultNodeURL = "\(.*\)".*/\1/p' "$ROOT/Clew/App/Config.swift")"

WORK="$(mktemp -d)"
ARTI_PID=""
# Stop Tor and delete the temp folders, keeping the check's own result as the exit status
# (otherwise Tor's "terminated" status would turn a pass into a failure).
cleanup() {
  local status=$?
  if [ -n "$ARTI_PID" ]; then kill "$ARTI_PID" 2>/dev/null || true; wait "$ARTI_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT
mkdir -p "$WORK/tor/state" "$WORK/tor/cache" "$WORK/wallet"
chmod -R 700 "$WORK"

echo "Compiling the check against the new wallet library…"
FFI="$ROOT/Frameworks/TariFFI"
xcrun swiftc -O "$ROOT/scripts/wallet-check/main.swift" -I "$FFI" -L "$FFI" \
  -framework Security -framework SystemConfiguration -framework CoreFoundation -lc++ -lresolv \
  -o "$WORK/wallet-check" 2>&1 | grep -v 'ld: warning' || true
[ -x "$WORK/wallet-check" ] || { echo "FAIL: the check didn't compile against the new library"; exit 1; }

echo "Starting the new Tor helper…"
cat > "$WORK/tor/arti.toml" <<EOF
[proxy]
socks_listen = "127.0.0.1:auto"
dns_listen = 0
[storage]
cache_dir = "$WORK/tor/cache"
state_dir = "$WORK/tor/state"
port_info_file = "$WORK/tor/port_info.json"
[logging]
console = "info"
EOF
# The copy in Frameworks/Arti is signed to run only inside Clew's sandbox and is killed if started
# on its own, so run the identical build it was copied from.
ARTI="$ROOT/build/arti/bin/arti"
[ "$("$ARTI" --version | awk 'NR==1{print $2}')" = "$(cat "$ROOT/Frameworks/Arti/VERSION")" ] \
  || { echo "FAIL: build/arti doesn't match Frameworks/Arti"; exit 1; }
"$ARTI" proxy -c "$WORK/tor/arti.toml" > "$WORK/tor/arti.log" 2>&1 &
ARTI_PID=$!
for _ in $(seq 1 120); do
  grep -q 'Sufficiently bootstrapped' "$WORK/tor/arti.log" && break
  kill -0 "$ARTI_PID" 2>/dev/null || break
  sleep 1
done
grep -q 'Sufficiently bootstrapped' "$WORK/tor/arti.log" || { echo "FAIL: Tor didn't connect"; tail -5 "$WORK/tor/arti.log"; exit 1; }
PORT="$(python3 -c "import json,sys; print([p['address'] for p in json.load(open(sys.argv[1]))['ports'] if p['protocol']=='socks'][0].rsplit(':',1)[1])" "$WORK/tor/port_info.json")"
echo "Tor connected (SOCKS on 127.0.0.1:$PORT)"

# A SOCKS username, as Clew uses per wallet for separate Tor circuits.
"$WORK/wallet-check" "$WORK/wallet" "$NETWORK" "$NODE" "socks5h://check:clew@127.0.0.1:$PORT"
