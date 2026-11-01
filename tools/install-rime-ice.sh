#!/bin/bash
# 安装 rime-ice 配置 + Polylangin 探针到 ~/Library/Rime
# 用法: bash tools/install-rime-ice.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/rime-ice-main"
DEST="$HOME/Library/Rime"

if [ ! -d "$SRC" ]; then
  echo "missing $SRC" >&2
  exit 1
fi

mkdir -p "$DEST/lua"

echo "== copy top-level yaml/txt =="
for f in "$SRC"/*.yaml "$SRC"/custom_phrase.txt; do
  [ -e "$f" ] || continue
  base="$(basename "$f")"
  case "$base" in
    weasel.yaml) continue ;;  # Windows only
  esac
  cp -f "$f" "$DEST/$base"
  echo "  $base"
done

echo "== copy data dirs =="
for d in cn_dicts en_dicts opencc lua; do
  [ -d "$SRC/$d" ] || continue
  mkdir -p "$DEST/$d"
  cp -Rf "$SRC/$d/." "$DEST/$d/"
  echo "  $d"
done

echo "== install probe =="
cp -f "$ROOT/spike/rime/polylangin_probe.lua" "$DEST/lua/polylangin_probe.lua"
cp -f "$ROOT/spike/rime/rime_ice.custom.yaml" "$DEST/rime_ice.custom.yaml"

# clear old probe log
: > "$DEST/polylangin-probe.log" 2>/dev/null || true

echo "== done: $DEST =="
