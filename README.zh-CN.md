# Polylangin

[English](README.md) | [简体中文](README.zh-CN.md)

> 一个本地、中英法混合输入的 macOS 输入法：中文 / English / Français 混着打，
> 不需要切换输入模式。

**状态：v0.16 · 目前仅支持 macOS · 个人业余项目。**

> **个人业余项目**：Polylangin 由个人在业余时间开发，目前是我的主力输入法。
> 不是公司产品，没有官方支持承诺；问题和建议欢迎提，但回复可能较慢。

Polylangin 的核心不是"再造一个拼音引擎"，而是一层宿主侧 composer：

- **Host-side composer**：按键先进原始缓冲区，由 Polylangin 决定何时上屏、上屏什么；
- **librime 只做转换器**：通过一个辅助 session 把拼音转成候选，不直接使用 Rime 的组字模型；
- **逐词语言判定**：每个新词根据拼音结构、英文/法文词表、光标前上下文自动决定语言；
- **本地优先**：无网络、无遥测，打字日志只写本机。

## 特性

- 中文、英文、法文连续输入，无需 Shift 切换中/西
- 逐词语言判定：完整拼音自动转中文；英文单词保持英文；法文在法语上下文保持法文
- 保守的自动纠错：英文/法文拼写、漏撇号、拼音对调/漏字；**不碰合法词与全大写缩写**
- 上下文标点：数字后英文标点；文字按“上一个句号之后”的中英文占比选择中/英文标点
- 本地 JSONL 打字日志，用于数据驱动改进
- macOS 前端：Swift / InputMethodKit，基于 Squirrel 1.1.2 fork

## 架构

```text
InputMethodKit app (Swift, Squirrel 1.1.2 fork)
  └─ host composer ──> librime 1.16 (辅助 session，仅做转换)
                        └─ 内置 rime-ice 种子数据
```

语言判定的简化流程：完整拼音 → 中文；英文词典词/前缀 → 英文；法语上下文中的
法文词/变音 → 法文；混合 token（`feichangnormal`）按“拼音前缀 + 拉丁后缀”切分。
判定结果同时决定是否补空格、是否触发纠错、是否显示中文候选。

## 仓库结构

| 路径                                | 内容                                      |
| --------------------------------- | --------------------------------------- |
| `vendor/squirrel-master/`         | macOS 前端：Squirrel 1.1.2 fork（Swift/IMK） |
| `vendor/librime-master/`          | librime 源码（BSD-3-Clause），参考/构建          |
| `vendor/rime-ice-main/`           | 内置 Rime 数据（GPL-3.0）                     |
| `resources/rime-seed/`            | Polylangin 的 Rime 配置种子                  |
| `tools/`                          | 构建、安装、打包与日志分析脚本                         |
| `vendor/squirrel-master/sources/` | composer、候选窗、日志实现                       |

## 键盘布局说明

作者使用 **Canadian CSA** 布局。其他布局下的死键、重音和部分标点行为可能不同；
作为主力输入法使用前请先自行测试，反馈时请附上具体布局名。

## macOS 构建

前置：

- macOS 14+，安装 Command Line Tools（`xcode-select --install`）
- 建议安装官方 Squirrel 1.1.2（构建脚本会复用它已部署的 `SharedSupport/` 与图标）
- 可选：Apple Development 证书；不设置 `SIGN_ID` 时默认 ad-hoc 签名（仅本地自用）

```bash
# 默认 ad-hoc 签名
bash tools/build-polylangin.sh

# 分发构建：设置自己的签名身份
SIGN_ID="Apple Development: Your Name (TEAMID)" bash tools/build-polylangin.sh

# 安装 + 选中输入源
POLYLANGIN_APP="vendor/squirrel-master/build/app/Polylangin.app" \
  bash tools/install-and-select.sh
```

产物：`vendor/squirrel-master/build/app/Polylangin.app`。

## 隐私与日志

- **不联网、无遥测**；所有判定都在本机完成。
- 默认写本地 JSONL 日志：`~/Desktop/Polylangin-logs/YYYY-MM-DD.jsonl`
  （回退目录：`~/Library/Logs/Polylangin`）。
- 日志包含按键、上屏文本、语言、候选序号、耗时、应用 id 等，**可能包含你输入的内容**；
  密码框（secure input）不记录。
- 日志不会自动上传；请不要把日志目录提交到仓库，公开 issue 前先脱敏。
- 日志开关可在 `PolylanginJournal.swift` 中关闭。

## 开发历程

- **2026-10**：开始做 macOS 混合输入法。先尝试纯 Rime + Squirrel 配置方案，
  发现宿主层按键处理会破坏加拿大 CSA 布局的法语重音，于是 fork Squirrel 1.1.2，
  把 composer 移到 Swift 宿主层。
- **2026-10**：完成 raw buffer + 显式上屏、逐词语言判定、候选条、Enter 兜底；
  随后接入 rime-ice 数据与独立用户目录。
- **2026-10 末**：用真实本地打字日志做数据驱动修复：自动纠错误伤、Enter 行为、
  候选翻页、上下文标点等。
- **2026-10 / 11**：加入多步候选选择（选一部分后保留剩余拼音）；当前重点是把
  macOS 体验做稳。

## 其他语言与魔改

目前只覆盖中文 / 英文 / 法文。如果确实需要俄语、阿拉伯语等其他文字，代码量不大，
欢迎直接 fork 后自行修改；也欢迎提 PR 或开 discussion 讨论。

## 致谢与三方组件

- [Squirrel](https://github.com/rime/squirrel)（GPL-3.0）——macOS 前端底座
- [librime](https://github.com/rime/librime)（BSD-3-Clause）——转换引擎
- [rime-ice / 雾凇拼音](https://github.com/iDvel/rime-ice)（GPL-3.0）——中文词典与配置
- FrequencyWords、google-10000-english 等公开词频表——英/法词表来源
- Apple InputMethodKit / NaturalLanguage——系统框架，不随本项目分发

完整许可证见 [`LICENSE`](LICENSE) 与 [`NOTICE`](NOTICE)。本项目与 Rime、Squirrel、
Apple 官方无关。

## License

GPL-3.0，见 [`LICENSE`](LICENSE)。
