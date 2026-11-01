#!/bin/bash
# Polylangin installer: copies the app into ~/Library/Input Methods, registers it,
# enables it in the third-party input-source list and selects it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Input Methods/Polylangin.app"
BUNDLE="app.polylangin.inputmethod.Polylangin"
MODE="$BUNDLE.Hans"

echo "== 安装 Polylangin =="
pkill -f "Input Methods/Polylangin.app" 2>/dev/null || true
sleep 1
mkdir -p "$HOME/Library/Input Methods"
# Update in place when possible: replacing the bundle with rm -rf + copy makes
# macOS register the same input source again and it shows up twice in System Settings.
ditto "$HERE/Polylangin.app" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
xattr -c "$DEST" 2>/dev/null || true
echo "已复制到 $DEST"

echo "== 注册输入源 =="
"$DEST/Contents/MacOS/Polylangin" --install 2>/dev/null || true

echo "== 加入第三方输入法启用列表 =="
INS=/tmp/polylangin-ins.plist
rm -f "$INS"
defaults export com.apple.inputsources "$INS" 2>/dev/null || true
if [ ! -s "$INS" ]; then
cat > "$INS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>AppleEnabledThirdPartyInputSources</key><array/></dict></plist>
PLIST
fi
PB=/usr/libexec/PlistBuddy
i=0
while $PB -c "Print :AppleEnabledThirdPartyInputSources:$i" "$INS" >/dev/null 2>&1; do
  if $PB -c "Print :AppleEnabledThirdPartyInputSources:$i:Bundle ID" "$INS" 2>/dev/null | grep -q "$BUNDLE"; then
    $PB -c "Delete :AppleEnabledThirdPartyInputSources:$i" "$INS" >/dev/null 2>&1 || true
  else
    i=$((i + 1))
  fi
done
$PB -c "Add :AppleEnabledThirdPartyInputSources:0 dict" "$INS" >/dev/null 2>&1 || true
$PB -c "Add :AppleEnabledThirdPartyInputSources:0:Bundle ID string $BUNDLE" "$INS" >/dev/null 2>&1 || true
$PB -c "Add :AppleEnabledThirdPartyInputSources:0:Input Mode string $MODE" "$INS" >/dev/null 2>&1 || true
$PB -c "Add :AppleEnabledThirdPartyInputSources:0:InputSourceKind string Input Mode" "$INS" >/dev/null 2>&1 || true
defaults import com.apple.inputsources "$INS" >/dev/null 2>&1 || true

echo "== 刷新输入法服务 =="
killall cfprefsd 2>/dev/null || true
killall TextInputMenuAgent 2>/dev/null || true
sleep 2

echo "== 启动并选中 =="
( "$DEST/Contents/MacOS/Polylangin" > /tmp/polylangin-run.log 2>&1 & )
sleep 4
"$DEST/Contents/MacOS/Polylangin" --select-input-source 2>&1 | tail -1 || true

echo
echo "安装完成。首次启动会在 ~/Library/Rime-Polylangin 重建 Rime 词库（约 1 分钟）。"
echo "如果菜单栏还没有 Polylangin："
echo "  1) 系统设置 → 键盘 → 输入法，点 + 添加 Polylangin；"
echo "  2) 或注销后重新登录一次。"
echo "如果提示无法验证开发者：系统设置 → 隐私与安全性 → 仍要打开，"
echo "  或运行: xattr -dr com.apple.quarantine \"$DEST\""
