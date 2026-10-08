#!/bin/bash
# Generates Clew.xcodeproj from project.yml. The Apple team ID isn't stored in the repository:
# it's read from this Mac's Apple Development signing certificate (or set CLEW_TEAM_ID yourself).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "${CLEW_TEAM_ID:-}" ]; then
  CLEW_TEAM_ID="$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p')"
fi
[ -n "$CLEW_TEAM_ID" ] || { echo "No Apple Development certificate found; set CLEW_TEAM_ID." >&2; exit 1; }
export CLEW_TEAM_ID

cd "$ROOT"
xcodegen generate --quiet
