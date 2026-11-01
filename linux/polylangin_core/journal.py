"""Local typing journal for the Linux port (same idea as PolylanginJournal.swift)."""

from __future__ import annotations

import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path

README = """Polylangin typing journal (local only)

One JSON object per line, one file per day: YYYY-MM-DD.jsonl
Fields: ts (ISO8601), type, app (bundle/desktop app id when available), and:
  key              chars, buf, composer, expanded
  backspace        buf, composer
  backspace_burst  count, window, composer, buf
  commit           text, raw, reason, lang, keys, backspaces, ms, grid, rank, correction
  raw_commit       text, keys, ms
  abandon          buf, reason, keys, backspaces, ms
  autocorrect      from, to, lang
  grid_open        count
Nothing is uploaded. Delete the files after analysis.
"""


def _default_directory() -> Path:
    home = Path.home()
    desktop = home / "Desktop" / "Polylangin-logs"
    try:
        desktop.mkdir(parents=True, exist_ok=True)
        probe = desktop / ".write-test"
        probe.write_text("ok", encoding="utf-8")
        probe.unlink()
        return desktop
    except OSError:
        fallback = home / ".local" / "share" / "polylangin" / "logs"
        fallback.mkdir(parents=True, exist_ok=True)
        return fallback


class Journal:
    def __init__(self, directory: Path | None = None, enabled: bool = True):
        self.enabled = enabled
        self.directory = directory or _default_directory()
        self._handle = None
        self._day = ""
        if self.enabled:
            self.directory.mkdir(parents=True, exist_ok=True)
            readme = self.directory / "README.txt"
            if not readme.exists():
                readme.write_text(README, encoding="utf-8")

    def event(self, event_type: str, fields: dict | None = None, app: str = "") -> None:
        if not self.enabled:
            return
        payload = dict(fields or {})
        payload["ts"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
        payload["type"] = event_type
        if app:
            payload["app"] = app
        day = datetime.now().strftime("%Y-%m-%d")
        if day != self._day or self._handle is None:
            self._day = day
            path = self.directory / f"{day}.jsonl"
            self._handle = path.open("a", encoding="utf-8")
        try:
            self._handle.write(json.dumps(payload, ensure_ascii=False) + "\n")
            self._handle.flush()
        except OSError:
            pass
