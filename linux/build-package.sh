#!/bin/bash
# Build the Linux (IBus) tarball: app engine + core + rime-ice seed + installer.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
STAGE="$DIST/Polylangin-Linux-0.1"

rm -rf "$DIST/linux" "$STAGE"
mkdir -p "$STAGE/ibus" "$STAGE/rime-seed"

cp "$ROOT/linux/install.sh" "$STAGE/install.sh"
chmod +x "$STAGE/install.sh"
cp -R "$ROOT/linux/polylangin_core" "$STAGE/"
cp "$ROOT/linux/ibus/polylangin_ibus.py" "$STAGE/ibus/"
cp "$ROOT/linux/ibus/rime_shim.c" "$STAGE/ibus/"
cp "$ROOT/linux/ibus/component.xml.in" "$STAGE/ibus/"
cp "$ROOT/linux/ibus/polylangin-supervisor.sh" "$STAGE/ibus/"
cp "$ROOT/tools/analyze-typing-log.py" "$STAGE/analyze-typing-log.py"
cp "$ROOT/tools/collect-typing-logs.sh" "$STAGE/collect-typing-logs.sh"
cp "$ROOT/linux/LICENSE-THIRD-PARTY.md" "$STAGE/" 2>/dev/null || true

# Minimal Rime seed: no lua/octagram plugins required on Linux.
RIME="$ROOT/vendor/rime-ice-main"
cp "$ROOT/resources/rime-seed-linux"/*.yaml "$STAGE/rime-seed/"
mkdir -p "$STAGE/rime-seed/cn_dicts"
for name in 8105 base ext; do
  cp "$RIME/cn_dicts/$name.dict.yaml" "$STAGE/rime-seed/cn_dicts/" 2>/dev/null || true
done

cp "$ROOT/linux/README-LINUX.md" "$STAGE/README.md"

mkdir -p "$DIST"
tar --exclude='__pycache__' -C "$DIST" -czf "$DIST/Polylangin-Linux-0.1.tar.gz" "Polylangin-Linux-0.1"
echo "built: $DIST/Polylangin-Linux-0.1.tar.gz"
du -sh "$DIST/Polylangin-Linux-0.1.tar.gz"
