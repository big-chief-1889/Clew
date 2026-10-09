#!/bin/bash
# Xcode registers every copy of Clew it builds with macOS. Extra copies of the same app can hide
# Clew from the Dock's Apps view, so this forgets every copy under build/ and re-registers the
# installed one.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"$LSREGISTER" -dump 2>/dev/null | sed -n 's/^[[:space:]]*path:[[:space:]]*\(.*\.app\) (0x[0-9a-f]*)$/\1/p' | sort -u \
  | while IFS= read -r copy; do
      case "$copy" in "$ROOT/build/"*) "$LSREGISTER" -u "$copy" 2>/dev/null || true ;; esac
    done
[ -d /Applications/Clew.app ] && "$LSREGISTER" -f /Applications/Clew.app 2>/dev/null || true
