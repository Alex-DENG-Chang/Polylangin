#!/bin/bash
# Install the built Polylangin.app to ~/Library/Input Methods, make sure it stays
# in the user's enabled input-source list (macOS drops it when the bundle is
# replaced), then select it.
#
# Usage: bash tools/install-and-select.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${POLYLANGIN_APP:-$ROOT/vendor/squirrel-master/build/app/Polylangin.app}"
DEST="$HOME/Library/Input Methods/Polylangin.app"
PLIST="$HOME/Library/Preferences/com.apple.HIToolbox.plist"
MODE="app.polylangin.inputmethod.Polylangin.Hans"
BUNDLE="app.polylangin.inputmethod.Polylangin"

[ -d "$APP" ] || { echo "missing build: $APP" >&2; exit 1; }

echo "== install =="
pkill -9 -f "Input Methods/Polylangin.app" 2>/dev/null || true
sleep 1
# update in place (bundle identity stays stable -> no duplicate input-source registration)
ditto "$APP" "$DEST"
xattr -c "$DEST" 2>/dev/null || true
echo "installed: $DEST"

echo "== launch =="
( "$DEST/Contents/MacOS/Polylangin" > /tmp/polylangin-run.log 2>&1 & )
sleep 4

echo "== ensure enabled input source (third-party list only) =="
# NOTE: com.apple.inputsources.plist is TCC-protected; edit it via
# `defaults export` / `defaults import` instead of writing the file directly.
defaults export com.apple.inputsources /tmp/polylangin-ins.plist 2>/dev/null || true
defaults export com.apple.HIToolbox /tmp/polylangin-ht.plist 2>/dev/null || true
POLY_BUNDLE="$BUNDLE" POLY_MODE="$MODE" python3 - <<'PY'
import os
import plistlib

bundle, mode = "${BUNDLE:-app.polylangin.inputmethod.Polylangin}", "${MODE:-app.polylangin.inputmethod.Polylangin.Hans}"
bundle = os.environ.get("POLY_BUNDLE", "app.polylangin.inputmethod.Polylangin")
mode = os.environ.get("POLY_MODE", "app.polylangin.inputmethod.Polylangin.Hans")

ins_path = "/tmp/polylangin-ins.plist"
if os.path.exists(ins_path):
    with open(ins_path, "rb") as f:
        ins = plistlib.load(f)
    sources = [item for item in ins.get("AppleEnabledThirdPartyInputSources", [])
               if item.get("Input Mode") == mode]
    if not sources:
        sources = [{"Bundle ID": bundle, "Input Mode": mode, "InputSourceKind": "Input Mode"}]
    ins["AppleEnabledThirdPartyInputSources"] = sources
    with open(ins_path, "wb") as f:
        plistlib.dump(ins, f)

ht_path = "/tmp/polylangin-ht.plist"
if os.path.exists(ht_path):
    with open(ht_path, "rb") as f:
        ht = plistlib.load(f)
    enabled = ht.get("AppleEnabledInputSources", [])
    filtered = [item for item in enabled if item.get("Bundle ID") != bundle]
    if len(filtered) != len(enabled):
        ht["AppleEnabledInputSources"] = filtered
        with open(ht_path, "wb") as f:
            plistlib.dump(ht, f)
        print("removed duplicate Polylangin entry from HIToolbox list")
PY
POLY_BUNDLE="$BUNDLE" POLY_MODE="$MODE" defaults import com.apple.inputsources /tmp/polylangin-ins.plist 2>/dev/null || true
defaults import com.apple.HIToolbox /tmp/polylangin-ht.plist 2>/dev/null || true

echo "== refresh text input agents =="
killall cfprefsd 2>/dev/null || true
killall TextInputMenuAgent 2>/dev/null || true
sleep 2

echo "== select =="
"$DEST/Contents/MacOS/Polylangin" --select-input-source 2>&1 | tail -2 || true
sleep 1
echo "== done =="
