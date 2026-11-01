#!/bin/bash
# Run this on the Linux machine and paste the output back.
# It only reads your environment; nothing is installed or changed.
echo "=== Polylangin Linux environment check ==="
echo "--- distro ---"
cat /etc/os-release 2>/dev/null | head -4
echo "--- desktop / session ---"
echo "XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-?}  XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-?}  DESKTOP_SESSION=${DESKTOP_SESSION:-?}"
echo
echo "--- input method framework processes ---"
ps -eo pid,comm,args 2>/dev/null | grep -E 'fcitx5|ibus-daemon|ibus-engine|kimpanel' | grep -v grep
echo
echo "--- packages (dpkg) ---"
dpkg -l 2>/dev/null | grep -E 'fcitx5|librime|ibus|rime-data|fcitx5-rime' | awk '{print $2, $3}'
echo
echo "--- rime libraries on the system ---"
ldconfig -p 2>/dev/null | grep -i librime
echo
echo "--- rime user data dirs ---"
for d in "$HOME/.local/share/fcitx5/rime" "$HOME/.config/ibus/rime" "$HOME/.local/share/ibus/rime" "$HOME/.config/fcitx5/rime"; do
  if [ -d "$d" ]; then
    echo "[$d]"
    ls "$d" 2>/dev/null | head -15
    echo "  -- default.custom.yaml / user.yaml --"
    grep -h -E 'schema|patch' "$d/default.custom.yaml" "$d/user.yaml" 2>/dev/null | head -8
    echo "  -- rime_ice present? --"
    ls "$d"/rime_ice.* 2>/dev/null | head -5
  fi
done
echo
echo "--- active schema / rime build ---"
for d in "$HOME/.local/share/fcitx5/rime/build" "$HOME/.config/ibus/rime/build"; do
  [ -f "$d/default.yaml" ] && grep -E 'schema_list|schema:' "$d/default.yaml" | head -8
done
echo
echo "--- apt candidates for dev headers ---"
apt-cache policy libfcitx5core-dev librime-dev python3-ibus fcitx5-rime 2>/dev/null | grep -E '^[a-z]|Candidate' | head -20
echo
echo "--- python / ibus ---"
python3 --version 2>/dev/null
python3 -c 'import ibus; print("python3-ibus: OK", ibus.__file__)' 2>&1 | head -2
echo
echo "--- fcitx5 diagnostics (if present) ---"
command -v fcitx5-diagnose >/dev/null 2>&1 && fcitx5-diagnose 2>/dev/null | sed -n '1,60p'
echo "=== end ==="
