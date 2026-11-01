# Polylangin

[English](README.md) | [简体中文](README.zh-CN.md)

> A local mixed-language input method for macOS: Chinese / English / Français,
> no mode switching.

**Status: private preview · v0.16 — macOS only.**

Polylangin is not another pinyin engine. It is a host-side composer built on top
of a Squirrel fork, with librime used only as a converter:

- **Host-side composer** — keys go into a raw buffer first; Polylangin decides
  when and what to commit.
- **librime as converter** — pinyin is sent through a private auxiliary session;
  the shipped app does not expose Rime's own composition model.
- **Per-word language detection** — each new token is classified from pinyin
  structure, English/French word lists, and the text before the caret.
- **Local first** — no network, no telemetry; the typing journal stays on disk.

## Features

- Chinese, English and French input without Shift mode switching
- Per-word language detection: complete pinyin becomes Chinese; English words
  stay English; French words stay French in a French context
- **Multi-step candidate selection**: choosing a candidate that covers only part
  of the pinyin keeps the rest active
  (`woshizhendeniubi` → choose "我是真的" → continue with `niubi`)
- Horizontal candidate bar with an expandable multi-row list; digits, arrow
  keys and page keys all work
- Conservative autocorrect: English/French spelling, missing apostrophes,
  pinyin letter swaps/missing letters — valid words and all-caps acronyms are
  never rewritten
- Context-aware punctuation: ASCII after digits; Chinese vs English punctuation
  based on the text since the last sentence terminator
- Local JSONL typing journal for data-driven improvements
- macOS frontend: Swift / InputMethodKit, based on a Squirrel 1.1.2 fork

## Architecture

```text
InputMethodKit app (Swift, Squirrel 1.1.2 fork)
  └─ host composer ──> librime 1.16 (auxiliary session, converter only)
                        └─ bundled rime-ice seed data
```

Language detection in brief: complete pinyin → Chinese; English dictionary
word/prefix → English; French word or diacritics in a French context → French;
mixed tokens (`feichangnormal`) are split into a pinyin prefix plus a Latin
suffix. The classification result also decides trailing spaces, autocorrect and
whether Chinese candidates should be shown.

## Repository layout

| Path | Contents |
|---|---|
| `vendor/squirrel-master/` | macOS frontend: Squirrel 1.1.2 fork (Swift/IMK) |
| `vendor/librime-master/` | librime sources (BSD-3-Clause), reference/build |
| `vendor/rime-ice-main/` | Bundled Rime data (GPL-3.0) |
| `resources/rime-seed/` | Polylangin Rime seed configuration |
| `tools/` | Build, install, packaging and log-analysis scripts |
| `vendor/squirrel-master/sources/` | Composer, candidate panel, journal |

## Build on macOS

Prerequisites:

- macOS 14+ and Command Line Tools (`xcode-select --install`)
- A stock Squirrel 1.1.2 installation is recommended; the build reuses its
  deployed `SharedSupport/` and icon
- Optional: an Apple Development signing identity; without `SIGN_ID` the app is
  ad-hoc signed for local use only

```bash
# Default: ad-hoc signing (local use)
bash tools/build-polylangin.sh

# Distribution build: use your own signing identity
SIGN_ID="Apple Development: Your Name (TEAMID)" bash tools/build-polylangin.sh

# Install and select the input source
POLYLANGIN_APP="vendor/squirrel-master/build/app/Polylangin.app" \
  bash tools/install-and-select.sh
```

Output: `vendor/squirrel-master/build/app/Polylangin.app`.

## Privacy and logs

- **Offline and telemetry-free** — all classification happens locally.
- A local JSONL journal is written by default:
  `~/Desktop/Polylangin-logs/YYYY-MM-DD.jsonl`
  (fallback: `~/Library/Logs/Polylangin`).
- Entries include keystrokes, committed text, language, candidate rank, timing
  and the active application id. **They may contain what you type.**
  Secure-input fields are skipped.
- Logs are never uploaded automatically. Do not commit logs or paste raw logs
  into public issues without redaction.
- Logging can be disabled in `PolylanginJournal.swift`.

## Development history

- **Oct 2026** — Started the macOS input method. Pure Rime/Squirrel configuration
  was not enough: the host key handling broke French accents on a Canadian CSA
  layout, so the project forked Squirrel 1.1.2 and moved the composer into Swift.
- **Oct 2026** — Raw buffer + explicit commit, per-word language detection,
  candidate bar and raw-Enter escape hatch; then rime-ice data and an isolated
  user data directory.
- **Late Oct 2026** — Data-driven fixes from real local typing logs: autocorrect
  harm, Enter behavior, candidate paging and context punctuation.
- **Oct–Nov 2026** — Multi-step candidate selection (keep the remaining pinyin);
  macOS experience is the current focus.

## Acknowledgements

- [Squirrel](https://github.com/rime/squirrel) (GPL-3.0) — macOS frontend base
- [librime](https://github.com/rime/librime) (BSD-3-Clause) — conversion engine
- [rime-ice / 雾凇拼音](https://github.com/iDvel/rime-ice) (GPL-3.0) — Chinese
  dictionary and schema data
- FrequencyWords, google-10000-english and related public word-frequency lists —
  English/French word lists
- Apple InputMethodKit / NaturalLanguage — system frameworks, not redistributed

See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE) for details. This project is not
affiliated with Rime, Squirrel or Apple.

## License

GPL-3.0. See [`LICENSE`](LICENSE).
