# Polylangin for Linux (IBus, experimental 0.1)

中英法混合输入法，Linux 版第一版（IBus 引擎 + librime/雾凇拼音数据）。
macOS 版不受影响，两者数据互相独立（Linux 使用 `~/.local/share/polylangin/`）。

## 环境要求

- Ubuntu / Debian（Zorin、Mint 等也可），GNOME + IBus
- 已安装 IBus（Zorin/Ubuntu 默认就是）
- 安装时会自动通过 apt 安装：`librime-dev`、`build-essential`、`python3-gi`、`python3-ibus-1.0`

## 安装

```bash
tar xzf Polylangin-Linux-0.1.tar.gz
cd Polylangin-Linux-0.1
bash install.sh
```

安装脚本会：
1. 安装/检查依赖；
2. 把引擎装到 `~/.local/share/polylangin/`；
3. 用系统 librime 头文件编译 `librime_shim.so`（保证 ABI 匹配）；
4. 把内置的 rime-ice（雾凇拼音）数据放到 `~/.local/share/polylangin/rime/`；
5. 注册 IBus 组件 `org.polylangin.ibus`（写到 `/usr/share/ibus/component/`，需要 sudo）；
6. 第一次初始化 Rime 并重建词库（1–3 分钟）；
7. 重启 IBus，并尽量自动把 Polylangin 加到 GNOME 输入源。

安装完成后：右上角输入法菜单 / 设置 → 键盘 → 输入法 → 选择 **Polylangin**。
如果没有出现，注销重新登录一次。

## 使用

- 中文：直接连打拼音，空格确认；候选 ←/→ 移动，PageUp/PageDown 翻页，数字 1–9 选择
- 英文/法文：直接打，空格确认并自动补空格
- Enter：原样上屏（逃生口）；Esc：清空；双击 Tab：清空
- 自动纠错：英文拼写、法文拼写、拼音相邻字母打反

## 打字日志（用于改进）

- 目录：`~/Desktop/Polylangin-logs/`（桌面不可写时回退到 `~/.local/share/polylangin/logs/`）
- 格式与 macOS 版相同，一天一个 `YYYY-MM-DD.jsonl`
- 收集：`bash ~/.local/share/polylangin/collect-typing-logs.sh`，会 zip 到桌面
- 密码框等 secure input 场景不会记录
- 分析完成后建议删除日志

## 已知限制（第一版）

- 候选窗是 IBus 原生候选条：单行、分页；macOS 版那个“↓ 展开多行网格”在 IBus 里还没有（需要自绘 GTK 候选窗，后续可做）
- 死键（^、´ 等）通过 IBus 的 keyval 处理，法文重音在大多数布局下可用；特殊布局可能需要再调
- 需要在你机器上编译一次 shim（apt 安装 librime-dev）；之后不需要编译器
- 与系统里已有的 ibus-rime 引擎互不影响：Polylangin 使用自己独立的数据目录

## 卸载

```bash
sudo rm -f /usr/share/ibus/component/polylangin.xml
rm -rf ~/.local/share/polylangin
```

然后在输入法设置里移除 Polylangin，重启 IBus（或注销重登）。

## 出问题时

把终端里的完整输出（尤其 `install.sh` 和 `python3 ~/.local/share/polylangin/polylangin_ibus.py --warmup` 的输出）发回给开发者。
常见检查：

```bash
ibus list-engine | grep -i polylangin
cat ~/.local/share/polylangin/logs/rime.polylangin.*.INFO 2>/dev/null | tail -20
```
