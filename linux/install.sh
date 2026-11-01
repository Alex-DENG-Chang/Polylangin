#!/bin/bash
# Polylangin for Linux (IBus engine) installer.
# Installs under ~/.local/share/polylangin, compiles the librime shim against the
# system librime headers, registers the IBus engine and seeds the Rime data.
set -euo pipefail

PKG="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$HOME/.local/share/polylangin"
COMPONENT_NAME="org.polylangin.ibus"
COMPONENT_PATH="/usr/share/ibus/component/polylangin.xml"
REQUIRED_PKGS=(librime-dev build-essential python3-gi python3-ibus-1.0)

say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
apt_install() {
  have sudo || { echo "需要 sudo 来安装依赖: $*" >&2; exit 1; }
  sudo apt-get install -y "$@"
}

say "检查依赖"
missing=()
for pkg in "${REQUIRED_PKGS[@]}"; do
  dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "缺少: ${missing[*]}"
  apt_install "${missing[@]}"
fi
have cc || apt_install build-essential
[ -f /usr/include/rime_api.h ] || apt_install librime-dev
python3 -c "import gi; gi.require_version('IBus','1.0'); from gi.repository import IBus" \
  || { echo "python3-ibus-1.0 / python3-gi 不可用，请先安装" >&2; exit 1; }

say "安装文件到 $INSTALL"
mkdir -p "$INSTALL" "$INSTALL/rime" "$INSTALL/logs"
rm -rf "$INSTALL/polylangin_core"
cp -R "$PKG/polylangin_core" "$INSTALL/"
cp "$PKG/ibus/polylangin_ibus.py" "$INSTALL/"
SEED_VERSION="polylangin-linux-0.1-minimal"
if [ "$(cat "$INSTALL/rime/.polylangin-seed" 2>/dev/null)" != "$SEED_VERSION" ]; then
  rm -rf "$INSTALL/rime"
  mkdir -p "$INSTALL/rime"
  cp -R "$PKG/rime-seed/." "$INSTALL/rime/"
  echo "$SEED_VERSION" > "$INSTALL/rime/.polylangin-seed"
fi
cp "$PKG/analyze-typing-log.py" "$INSTALL/" 2>/dev/null || true
cp "$PKG/collect-typing-logs.sh" "$INSTALL/" 2>/dev/null || true

say "编译 librime shim（使用系统 librime 头文件，确保 ABI 匹配）"
cc -O2 -fPIC -shared -o "$INSTALL/librime_shim.so" "$PKG/ibus/rime_shim.c" -lrime -ldl

say "注册 IBus engine"
sed "s|@EXEC@|python3 $INSTALL/polylangin_ibus.py|" "$PKG/ibus/component.xml.in" > /tmp/polylangin-component.xml
if [ -w /usr/share/ibus/component ]; then
  cp /tmp/polylangin-component.xml "$COMPONENT_PATH"
else
  have sudo && sudo cp /tmp/polylangin-component.xml "$COMPONENT_PATH" || {
    echo "无法写入 $COMPONENT_PATH（需要 sudo）" >&2; exit 1;
  }
fi

say "第一次初始化 Rime（需要重建 rime-ice 词库，约 1–3 分钟）"
python3 "$INSTALL/polylangin_ibus.py" --warmup || {
  echo "Rime 初始化失败，请把上面的报错发回给开发者" >&2; exit 1;
}

say "安装引擎自启动（IBus 组件拉起不稳定的兜底）"
cp "$PKG/ibus/polylangin-supervisor.sh" "$INSTALL/polylangin-supervisor.sh"
chmod +x "$INSTALL/polylangin-supervisor.sh"
mkdir -p "$HOME/.config/autostart"
cat > "$HOME/.config/autostart/polylangin-engine.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Polylangin engine
Comment=Keep the Polylangin IBus engine running
Exec=$INSTALL/polylangin-supervisor.sh
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
DESKTOP

say "重启 IBus"
ibus restart 2>/dev/null || {
  killall ibus-daemon 2>/dev/null || true
  sleep 1
  systemctl --user restart ibus 2>/dev/null || true
}
sleep 2

say "加入 GNOME 输入源（保留你现有的输入法）"
python3 - <<'PY' || true
import ast
import subprocess

def gsettings(*args):
    return subprocess.check_output(["gsettings", *args], text=True).strip()

try:
    current = gsettings("get", "org.gnome.desktop.input-sources", "sources")
    sources = list(ast.literal_eval(current))
    if ("ibus", "polylangin") not in sources:
        sources.append(("ibus", "polylangin"))
        value = "[" + ", ".join("('%s', '%s')" % item for item in sources) + "]"
        subprocess.check_call(["gsettings", "set", "org.gnome.desktop.input-sources",
                               "sources", value])
        print("已添加 Polylangin 到 GNOME 输入源")
    else:
        print("Polylangin 已在输入源列表中")
except Exception as exc:
    print("自动添加输入源失败（可手动添加）:", exc)
PY

say "检查引擎是否注册成功"
ibus list-engine 2>/dev/null | grep -i polylangin || {
  echo "IBus 暂未列出 Polylangin；请注销后重新登录一次，再检查输入源。" >&2
}

cat <<MSG

安装完成。

使用方法：
  1. 右上角输入法菜单 / 设置 → 键盘 → 输入法，选择 “Polylangin”；
  2. 中文直接连打拼音，空格确认；英文/法文直接打，空格确认；
  3. 候选：方向键 ←/→ 移动，PageUp/PageDown 翻页，数字 1–9 选择；
  4. Enter 原样上屏，Esc 清空，双击 Tab 清空。

日志（用于改进）：
  ~/Desktop/Polylangin-logs/   （桌面权限不可写时回退到 ~/.local/share/polylangin/logs/）
  下班前在终端执行:  bash ~/.local/share/polylangin/collect-typing-logs.sh

如果引擎没有出现在输入法列表里：
  - 注销并重新登录一次；
  - 或执行: ibus list-engine | grep -i polylangin

卸载：
  sudo rm -f $COMPONENT_PATH
  rm -rf "$INSTALL"
  （然后在输入法设置里移除 Polylangin）
MSG
