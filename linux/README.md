# Polylangin for Linux (work in progress)

The macOS version (v0.13) is frozen and untouched: this directory is the Linux port.

## Status

- [x] Framework-agnostic **composer core** ported to Python:
  - raw preedit, space/enter/digits/arrows/expand behaviour,
  - Chinese/English/French classification, autocorrect, pinyin typo fix,
  - context detection from the text before the caret,
  - same local JSONL typing journal (Desktop `Polylangin-logs`).
  - 17 unit tests (run on macOS): `python3 -m unittest discover -s linux/tests -v`
- [ ] Frontend (needs to know which input-method framework the Linux machine uses)
- [ ] Installer + package
- [ ] Real-machine testing via the typing journal

## The two possible frontends

### A. Fcitx5 (C++ addon, recommended if that is what you already use)

- Keeps the current fcitx5 setup; works with the existing 雾凇拼音 Rime data dir
  (`~/.local/share/fcitx5/rime`), so no reinstall of Rime data.
- Needs `libfcitx5core-dev`, `librime-dev`, `cmake`, `g++` to build (installer can
  `apt-get install` them).
- We write a small `fcitx5-polylangin` engine that reuses
  `linux/polylangin_core` logic compiled as a small executable/service, or port the
  core to C++ (decision after reading the environment report).

### B. IBus (Python engine)

- Faster to prototype: `python3-ibus` + `ctypes` bindings to `librime`.
- Reuses the existing Rime data (雾凇拼音) or ships its own.
- Requires switching the desktop input framework from fcitx5 to IBus
  (`im-config -n ibus`), which changes the current setup.

## What we need from the Linux machine

Run:

```bash
bash linux/detect-env.sh > /tmp/polylangin-linux-env.txt
```

and send back the output. It only reads the environment (no installs, no changes).

## Logging

The Linux engine will writes the same JSONL journal to
`~/Desktop/Polylangin-logs/` (fallback `~/.local/share/polylangin/logs`), so the
same `tools/analyze-typing-log.py` report works after a day of use.
