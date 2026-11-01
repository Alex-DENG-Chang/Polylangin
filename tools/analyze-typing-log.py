#!/usr/bin/env python3
"""Analyze Polylangin typing journals (~/Desktop/Polylangin-logs/*.jsonl).

Usage: python3 tools/analyze-typing-log.py [logdir] [-o report.md]

Prints a Markdown report designed for an IME developer: language mix, typing
speed, backspace/frustration hotspots, autocorrect hits, candidate navigation,
abandoned buffers and likely misclassification cases.
"""
import argparse
import collections
import json
import pathlib
import statistics
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("logdir", nargs="?", default=str(pathlib.Path.home() / "Desktop/Polylangin-logs"))
    parser.add_argument("-o", "--out", default="")
    parser.add_argument("--top", type=int, default=20)
    args = parser.parse_args()

    logdir = pathlib.Path(args.logdir).expanduser()
    if not logdir.is_dir():
        fallback = pathlib.Path.home() / "Library/Logs/Polylangin"
        print(f"# Polylangin typing report\n\n(log dir {logdir} not found, using {fallback})\n")
        logdir = fallback
    files = sorted(logdir.glob("*.jsonl"))
    events = []
    for path in files:
        with path.open(encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError:
                    continue

    out = []
    def add(line=""):
        out.append(line)

    add("# Polylangin typing report")
    add()
    add(f"- log dir: `{logdir}`")
    add(f"- files: {len(files)}, events: {len(events)}")
    if not events:
        add("\nNo events found. Type something with Polylangin first.")
        text = "\n".join(out)
        print(text)
        if args.out:
            pathlib.Path(args.out).write_text(text, encoding="utf-8")
        return 0

    commits = [e for e in events if e.get("type") == "commit"]
    abandons = [e for e in events if e.get("type") == "abandon"]
    keys = [e for e in events if e.get("type") == "key"]
    autocorrects = [e for e in events if e.get("type") == "autocorrect"]
    bursts = [e for e in events if e.get("type") == "backspace_burst"]
    grid_opens = [e for e in events if e.get("type") == "grid_open"]
    apps = collections.Counter(e.get("app") for e in events if e.get("app"))

    add("\n## Volume\n")
    add(f"- keys logged: {len(keys)}")
    add(f"- commits: {len(commits)}")
    add(f"- abandoned buffers: {len(abandons)} ({len(abandons) / max(1, len(commits) + len(abandons)) * 100:.1f}%)")
    add(f"- autocorrects: {len(autocorrects)}")
    add(f"- backspace bursts (>=4 within 1.2 s): {len(bursts)}")
    add(f"- expanded-list opens: {len(grid_opens)}")
    if apps:
        add("\nApps:\n")
        for app, n in apps.most_common(10):
            add(f"- `{app}`: {n} events")

    by_lang = collections.Counter(e.get("lang", "?") for e in commits)
    add("\n## Commits by language\n")
    for lang, n in by_lang.most_common():
        add(f"- {lang}: {n} ({n / max(1, len(commits)) * 100:.1f}%)")

    if commits:
        keys_per_commit = [e.get("keys", 0) for e in commits]
        ms_per_commit = [e.get("ms", 0) for e in commits if e.get("ms")]
        add("\n## Commit efficiency\n")
        add(f"- keys/commit: avg {statistics.mean(keys_per_commit):.2f}, median {statistics.median(keys_per_commit):.0f}")
        if ms_per_commit:
            add(f"- time/commit: median {statistics.median(ms_per_commit):.0f} ms,"
                f" p90 {sorted(ms_per_commit)[int(len(ms_per_commit) * 0.9)]} ms")
        ranked = [e.get("rank", 0) for e in commits]
        add(f"- commits needing candidate navigation (rank > 0): {sum(1 for r in ranked if r)}"
            f" ({sum(1 for r in ranked if r) / len(ranked) * 100:.1f}%)")
        add(f"- commits from expanded grid: {sum(1 for e in commits if e.get('grid'))}")

    add("\n## Backspace hotspots\n")
    backspaces = [e for e in events if e.get("type") == "backspace"]
    add(f"- backspace events: {len(backspaces)}")
    worst = sorted(commits, key=lambda e: e.get("backspaces", 0), reverse=True)[: args.top]
    add("\nWorst committing episodes (most backspaces before commit):\n")
    for e in worst:
        if e.get("backspaces", 0) == 0:
            continue
        add(f"- bs={e.get('backspaces')} keys={e.get('keys')} ms={e.get('ms')} lang={e.get('lang')}"
            f" raw=`{e.get('raw','')}` -> `{e.get('text','')}`")
    if bursts:
        add("\nBursts:\n")
        for e in bursts[: args.top]:
            add(f"- {e.get('ts')} count={e.get('count')} composer={e.get('composer')} buf=`{e.get('buf','')}`")

    abandoned_bufs = collections.Counter(e.get("buf", "") for e in abandons)
    if abandoned_bufs:
        add("\n## Most abandoned buffers\n")
        for buf, n in abandoned_bufs.most_common(15):
            add(f"- `{buf}`: {n}×")

    if autocorrects:
        pairs = collections.Counter((e.get("from", ""), e.get("to", "")) for e in autocorrects)
        add("\n## Autocorrections\n")
        for (src, dst), n in pairs.most_common(args.top):
            add(f"- `{src}` -> `{dst}`: {n}×")

    # Possible Chinese/English classification mistakes: ASCII raw committed with CJK output.
    suspicious = [e for e in commits if e.get("lang") == "zh" and e.get("raw", "").isascii()
                  and any("\u4e00" <= ch <= "\u9fff" for ch in e.get("text", ""))]
    if suspicious:
        add("\n## Raw pinyin -> Chinese commits (check for accidental conversions)\n")
        for e in suspicious[: args.top]:
            add(f"- raw=`{e.get('raw')}` -> `{e.get('text')}`")

    text = "\n".join(out)
    print(text)
    if args.out:
        pathlib.Path(args.out).write_text(text, encoding="utf-8")
        print(f"\n(saved to {args.out})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
