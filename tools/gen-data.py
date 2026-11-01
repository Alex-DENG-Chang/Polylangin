#!/usr/bin/env python3
"""Generate Polylangin runtime data (pinyin syllables + English word list)
from the vendored rime-ice dictionaries.

Outputs:
  vendor/squirrel-master/resources/polylangin/syllables.txt
  vendor/squirrel-master/resources/polylangin/english_words.txt
"""
import re
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
RIME_ICE = ROOT / "vendor" / "rime-ice-main"
OUT = ROOT / "vendor" / "squirrel-master" / "resources" / "polylangin"
OUT.mkdir(parents=True, exist_ok=True)

syllables = set()
for name in ["8105.dict.yaml", "base.dict.yaml"]:
    path = RIME_ICE / "cn_dicts" / name
    if not path.exists():
        continue
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if not line or line.startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) < 2:
            continue
        for tok in cols[1].strip().split():
            if re.fullmatch(r"[a-z]+", tok):
                syllables.add(tok)

words = set()
for name in ["en.dict.yaml", "en_ext.dict.yaml"]:
    path = RIME_ICE / "en_dicts" / name
    if not path.exists():
        continue
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if not line or line.startswith("#"):
            continue
        w = line.split("\t")[0].strip().lower()
        if re.fullmatch(r"[a-z]+", w) and len(w) >= 2:
            words.add(w)

(OUT / "syllables.txt").write_text("\n".join(sorted(syllables)) + "\n", encoding="utf-8")
(OUT / "english_words.txt").write_text("\n".join(sorted(words)) + "\n", encoding="utf-8")
print(f"wrote {len(syllables)} syllables, {len(words)} words -> {OUT}")
