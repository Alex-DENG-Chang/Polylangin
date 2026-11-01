# Polylangin v0.16 — macOS (Apple Silicon)

**A personal hobby project.** This is an early, single-developer input method.
It is currently the author's daily driver on macOS, but there is no support
guarantee. Please back up your existing input sources before installing.

- Requires **macOS 14+** on **Apple Silicon** (arm64)
- The author uses the **Canadian CSA** keyboard layout. Other layouts may have
  different dead-key/ punctuation behavior; please test before relying on it.
- The app is ad-hoc signed (not notarized). `install.sh` removes the quarantine
  flag; if macOS still blocks it, see "Gatekeeper" below.

## Install

```bash
# 1. Double-click the extracted folder, open Terminal there, then:
bash install.sh
```

The installer copies `Polylangin.app` into `~/Library/Input Methods/`, registers
it, enables it in the third-party input-source list and tries to select it.

After installation:

1. First launch takes ~1 minute to build the Rime dictionary under
   `~/Library/Rime-Polylangin/`.
2. If Polylangin does not appear in the menu bar:
   **System Settings → Keyboard → Input Sources → + → add Polylangin**,
   or log out and back in once.

### Gatekeeper

The app is not notarized. If macOS says it cannot verify the developer:

**System Settings → Privacy & Security → Open Anyway**, or run:

```bash
xattr -dr com.apple.quarantine "$HOME/Library/Input Methods/Polylangin.app"
```

## Usage

- Chinese: type pinyin, Space confirms; digits / arrow keys choose candidates
- English / French: type normally; Space confirms and adds a trailing space
- Enter: commit the raw Latin keys (escape hatch)
- Esc: clear; double-Tab: clear
- `woshizhendeniubi` → choose "我是真的" → the remaining `niubi` stays active
- Mixed words: `feichangnormal` → "非常normal"

## Privacy

- No network, no telemetry.
- Local JSONL journal: `~/Desktop/Polylangin-logs/YYYY-MM-DD.jsonl`
  (fallback: `~/Library/Logs/Polylangin`). It may contain typed text;
  secure input fields are skipped. Logs are never uploaded.
- Do not paste raw logs into public issues without redacting them.

## Uninstall

```bash
rm -rf "$HOME/Library/Input Methods/Polylangin.app"
rm -rf "$HOME/Library/Rime-Polylangin"
```

Then remove Polylangin in **System Settings → Keyboard → Input Sources**.

---

# Polylangin v0.16 — macOS（Apple Silicon）

**个人业余项目**：由个人开发者维护的早期输入法，目前是作者的主力输入法，
但没有官方支持承诺；安装前请先确认你还能切回原有输入法。

- 需要 **macOS 14+**，**Apple Silicon（arm64）**
- 作者使用 **Canadian CSA** 键盘布局；其他布局的死键/标点行为可能不同，请先测试
- 应用为 ad-hoc 签名（未公证）；`install.sh` 会清除 quarantine 标记；
  如果仍被系统拦截，见下方 Gatekeeper

## 安装

```bash
# 1. 解压后在终端进入该目录
bash install.sh
```

安装脚本会把 `Polylangin.app` 复制到 `~/Library/Input Methods/`，注册输入源并尝试选中。

首次启动会在 `~/Library/Rime-Polylangin/` 重建 Rime 词库，约 1 分钟。
如果菜单栏没有 Polylangin：
**系统设置 → 键盘 → 输入法 → + → 添加 Polylangin**，或注销后重新登录一次。

### Gatekeeper

应用未公证。如果提示无法验证开发者：
**系统设置 → 隐私与安全性 → 仍要打开**，或执行：

```bash
xattr -dr com.apple.quarantine "$HOME/Library/Input Methods/Polylangin.app"
```

## 使用

- 中文：直接连打拼音，空格确认；数字/方向键选候选
- 英文/法文：直接打，空格确认并自动补空格
- Enter：原样提交拉丁字母（逃生口）
- Esc：清空；双击 Tab：清空
- `woshizhendeniubi` → 选“我是真的”后，剩余 `niubi` 会保留
- 中英混合：`feichangnormal` → “非常normal”

## 隐私

- 不联网、无遥测
- 本地 JSONL 日志：`~/Desktop/Polylangin-logs/YYYY-MM-DD.jsonl`
  （回退：`~/Library/Logs/Polylangin`），可能包含输入内容；密码框不记录；不会上传
- 请不要把原始日志直接贴到公开 issue

## 卸载

```bash
rm -rf "$HOME/Library/Input Methods/Polylangin.app"
rm -rf "$HOME/Library/Rime-Polylangin"
```

然后在 **系统设置 → 键盘 → 输入法** 中移除 Polylangin。
