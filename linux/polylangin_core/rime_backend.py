"""ctypes bridge to the compiled librime shim (see linux/ibus/rime_shim.c)."""

from __future__ import annotations

import atexit
import ctypes
import os
from pathlib import Path


class RimeShimBackend:
    def __init__(self, shim_path: Path, shared_dir: Path, user_dir: Path, log_dir: Path):
        self.shim_path = Path(shim_path)
        self.shared_dir = Path(shared_dir)
        self.user_dir = Path(user_dir)
        self.log_dir = Path(log_dir)
        self.surrounding_provider = None
        self._lib = None
        self._initialized = False
        self.last_page_size = 5

    def _load(self):
        if self._lib is not None:
            return
        lib = ctypes.CDLL(str(self.shim_path))
        lib.polylangin_rime_init.argtypes = [
            ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int
        ]
        lib.polylangin_rime_init.restype = ctypes.c_int
        lib.polylangin_rime_finalize.restype = None
        lib.polylangin_session.restype = ctypes.c_ulonglong
        lib.polylangin_clear.restype = ctypes.c_int
        lib.polylangin_process_key.argtypes = [ctypes.c_int, ctypes.c_int]
        lib.polylangin_process_key.restype = ctypes.c_int
        lib.polylangin_convert.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
        lib.polylangin_convert.restype = ctypes.c_int
        lib.polylangin_last_page_size.restype = ctypes.c_int
        lib.polylangin_select.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_int,
                                          ctypes.c_char_p, ctypes.c_int]
        lib.polylangin_select.restype = ctypes.c_int
        self._lib = lib

    def init(self) -> None:
        if self._initialized:
            return
        self._load()
        assert self._lib is not None
        self.user_dir.mkdir(parents=True, exist_ok=True)
        self.log_dir.mkdir(parents=True, exist_ok=True)
        error = ctypes.create_string_buffer(1024)
        rc = self._lib.polylangin_rime_init(
            str(self.shared_dir).encode(), str(self.user_dir).encode(),
            str(self.log_dir).encode(), error, len(error),
        )
        if rc != 0:
            raise RuntimeError(error.value.decode(errors="replace") or "librime init failed")
        self._lib.polylangin_session()
        self._initialized = True
        atexit.register(self.finalize)

    def finalize(self) -> None:
        if self._lib is not None and self._initialized:
            try:
                self._lib.polylangin_rime_finalize()
            except Exception:
                pass
            self._initialized = False

    def warmup(self) -> str:
        self.init()
        candidates, _ = self.convert("ni")
        return f"{len(candidates)} candidates ready"

    def convert(self, token: str) -> tuple[list[str], list[str]]:
        self.init()
        assert self._lib is not None
        buffer = ctypes.create_string_buffer(128 * 1024)
        count = self._lib.polylangin_convert(token.encode("utf-8"), buffer, len(buffer))
        if count <= 0:
            return [], []
        self.last_page_size = self._lib.polylangin_last_page_size() or 5
        raw = buffer.raw[:count].decode("utf-8", errors="replace")
        candidates: list[str] = []
        comments: list[str] = []
        for record in raw.split("\x1e"):
            if not record:
                continue
            parts = record.split("\x1f", 1)
            candidates.append(parts[0])
            comments.append(parts[1] if len(parts) > 1 else "")
        return candidates, comments

    def select_candidate(self, buffer: str, page: int, index: int) -> str | None:
        """Ask Rime to select a candidate; returns remaining pinyin or None."""
        self.init()
        assert self._lib is not None
        out = ctypes.create_string_buffer(4096)
        rc = self._lib.polylangin_select(buffer.encode("utf-8"), page, index, out, len(out))
        if rc != 0:
            return None
        return out.value.decode("utf-8", errors="replace")

    def commit(self, text: str) -> None:  # the engine provides its own commit handler
        del text

    def surrounding_text(self) -> str:
        if self.surrounding_provider is None:
            return ""
        try:
            return self.surrounding_provider() or ""
        except Exception:
            return ""

    def app_id(self) -> str:
        return os.environ.get("POLYLANGIN_APP_ID", "desktop")
