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
cp "$ROOT/tools/release/安装说明.md" "$STAGE/安装说明.md"
cp "$ROOT/tools/collect-typing-logs.sh" "$STAGE/collect-typing-logs.sh"
chmod +x "$STAGE/collect-typing-logs.sh"
cp "$ROOT/tools/analyze-typing-log.py" "$STAGE/analyze-typing-log.py"
chmod +x "$STAGE/analyze-typing-log.py"

# Preserve metadata/symlinks and keep the .app intact inside the zip.
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$DIST/Polylangin-$VERSION-mac-arm64.zip"
echo "packaged: $DIST/Polylangin-$VERSION-mac-arm64.zip"
du -sh "$DIST/Polylangin-$VERSION-mac-arm64.zip"
