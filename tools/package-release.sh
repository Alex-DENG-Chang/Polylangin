#!/bin/bash
# Build a distributable zip containing Polylangin.app and the installer.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
APP="${POLYLANGIN_APP:-$ROOT/vendor/squirrel-master/build/app/Polylangin.app}"
DIST="$ROOT/dist"
STAGE="$DIST/Polylangin-$VERSION"

[ -d "$APP" ] || { echo "missing build: $APP (run tools/build-polylangin.sh first)" >&2; exit 1; }

rm -rf "$DIST"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Polylangin.app"
cp "$ROOT/tools/release/install.sh" "$STAGE/install.sh"
chmod +x "$STAGE/install.sh"
cp "$ROOT/INSTALL.md" "$STAGE/INSTALL.md"
cp "$ROOT/LICENSE" "$STAGE/LICENSE"
cp "$ROOT/NOTICE" "$STAGE/NOTICE"

# Preserve metadata/symlinks and keep the .app intact inside the zip.
ditto -c -k --norsrc --keepParent "$STAGE" "$DIST/Polylangin-$VERSION-macOS-arm64.zip"
shasum -a 256 "$DIST/Polylangin-$VERSION-macOS-arm64.zip" | awk '{print $1"  Polylangin-'"$VERSION"'-macOS-arm64.zip"}' > "$DIST/Polylangin-$VERSION-macOS-arm64.zip.sha256"
echo "packaged: $DIST/Polylangin-$VERSION-macOS-arm64.zip"
du -sh "$DIST/Polylangin-$VERSION-macOS-arm64.zip"
