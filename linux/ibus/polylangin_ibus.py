#!/usr/bin/env python3
"""Polylangin IBus engine (Linux port).

The mixed-language logic lives in ``polylangin_core`` (shared with the macOS
implementation conceptually); this file only adapts it to IBus.
"""

from __future__ import annotations

import os
import sys
import unicodedata
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import gi  # noqa: E402

gi.require_version("IBus", "1.0")
from gi.repository import GLib, IBus  # noqa: E402

from polylangin_core.composer import Composer  # noqa: E402
from polylangin_core.data import WordData  # noqa: E402
from polylangin_core.journal import Journal  # noqa: E402
from polylangin_core.rime_backend import RimeShimBackend  # noqa: E402

def _dlog(message: str) -> None:
    try:
        import time
        with open("/tmp/polylangin-engine.log", "a", encoding="utf-8") as handle:
            handle.write(f"{time.time():.3f} {message}\n")
    except OSError:
        pass


_dlog("import")
COMPONENT_NAME = "org.polylangin.ibus"
ENGINE_NAME = "polylangin"
INSTALL_DIR = Path.home() / ".local" / "share" / "polylangin"

KEY_ESCAPE = 0xFF1B
KEY_BACKSPACE = 0xFF08
KEY_TAB = 0xFF09
KEY_RETURN = 0xFF0D
KEY_KP_ENTER = 0xFF8D
KEY_LEFT = 0xFF51
KEY_UP = 0xFF52
KEY_RIGHT = 0xFF53
KEY_DOWN = 0xFF54
KEY_PAGE_UP = 0xFF55
KEY_PAGE_DOWN = 0xFF56
KEY_SPACE = 0x20

DEAD_KEYS = {
    0xFE50: "\u0300",  # grave
    0xFE51: "\u0301",  # acute
    0xFE52: "\u0302",  # circumflex
    0xFE53: "\u0303",  # tilde
    0xFE57: "\u0308",  # diaeresis
    0xFE5B: "\u0327",  # cedilla
}


PUNCTUATION_MAP = {
    ".": "。", ",": "，", "!": "！", "?": "？",
    ";": "；", ":": "：", "(": "（", ")": "）", "~": "～",
}


def discover_plugin_dirs() -> None:
    if os.environ.get("POLYLANGIN_RIME_PLUGINS"):
        return
    found: set[str] = set()
    for base in ("/usr/lib", "/usr/lib64", "/usr/local/lib"):
        root = Path(base)
        if not root.is_dir():
            continue
        search_root = root if root.name != "lib" else root
        for current, dirs, files in os.walk(search_root):
            depth = len(Path(current).relative_to(search_root).parts)
            if depth > 3:
                dirs[:] = []
                continue
            if "rime-plugins" in Path(current).parts:
                found.add(current)
            if any(name.startswith("librime-") and name.endswith(".so") for name in files):
                found.add(current)
    if found:
        os.environ["POLYLANGIN_RIME_PLUGINS"] = ":".join(sorted(found))


def make_backend() -> RimeShimBackend:
    discover_plugin_dirs()
    return RimeShimBackend(
        INSTALL_DIR / "librime_shim.so",
        Path("/usr/share/rime-data"),
        INSTALL_DIR / "rime",
        INSTALL_DIR / "logs",
    )


class PolylanginEngine(IBus.Engine):
    def __init__(self, bus=None, object_path=None):
        _dlog("engine init start")
        IBus.Engine.__init__(self, bus, object_path)
        self.backend = make_backend()
        try:
            self.backend.init()
            _dlog("rime init ok")
        except Exception as exc:  # keep the engine alive; keys will pass through
            _dlog(f"rime init failed: {exc}")
            print(f"[polylangin] rime init failed: {exc}", file=sys.stderr)
        self.data = WordData.load(HERE / "polylangin_core" / "data")
        self.composer = Composer(
            self.backend,
            data=self.data,
            journal=Journal(),
            commit_handler=self._commit,
        )
        self.backend.surrounding_provider = self._surrounding_text
        self._pending_combining: str | None = None

    # -- IBus helpers ---------------------------------------------------------
    def _commit(self, text: str) -> None:
        if text:
            self.commit_text(IBus.Text.new_from_string(text))

    def _surrounding_text(self) -> str:
        try:
            result = self.get_surrounding_text()
        except Exception:
            return ""
        if result is None:
            return ""
        text_obj = None
        cursor = None
        if isinstance(result, tuple):
            for item in result:
                if isinstance(item, IBus.Text):
                    text_obj = item
                elif isinstance(item, int) and cursor is None:
                    cursor = item
        elif isinstance(result, IBus.Text):
            text_obj = result
        if text_obj is None:
            return ""
        text = text_obj.get_text() or ""
        if cursor is not None:
            text = text[:cursor]
        return text

    def _new_lookup_table(self, candidates: list[str], highlighted: int):
        try:
            table = IBus.LookupTable.new(len(candidates), highlighted, True)
        except TypeError:
            table = IBus.LookupTable.new(len(candidates), 0, 0, 0)
            table.set_cursor_pos(highlighted)
            table.set_cursor_visible(True)
        for candidate in candidates:
            table.append_candidate(IBus.Text.new_from_string(candidate))
        try:
            table.set_page_size(max(1, len(candidates)))
        except Exception:
            pass
        table.set_cursor_pos(highlighted)
        return table

    @staticmethod
    def _empty_lookup_table():
        # IBus asserts page_size > 0; creating a size-0 table aborts the process.
        try:
            return IBus.LookupTable.new(1, 0, False)
        except TypeError:
            return IBus.LookupTable.new(1, 0, 0, 0)

    def _hide_lookup(self) -> None:
        try:
            self.hide_lookup_table()
        except Exception:
            self.update_lookup_table(self._empty_lookup_table(), False)

    def _update_ui(self) -> None:
        if not self.composer.active:
            self.update_preedit_text(IBus.Text.new_from_string(""), 0, False)
            self._hide_lookup()
            return
        preedit = self.composer.preedit
        self.update_preedit_text(IBus.Text.new_from_string(preedit), len(preedit), True)
        page = self.composer.candidate_page()
        if page.candidates:
            self.update_lookup_table(self._new_lookup_table(page.candidates, page.highlighted), True)
        else:
            self._hide_lookup()

    # -- key handling ---------------------------------------------------------
    def do_process_key_event(self, keyval, keycode, state):
        if state & IBus.ModifierType.RELEASE_MASK:
            return False
        if state & (IBus.ModifierType.CONTROL_MASK
                    | IBus.ModifierType.MOD1_MASK
                    | IBus.ModifierType.SUPER_MASK):
            return False
        try:
            handled = self._handle_key(keyval)
            self._update_ui()
            return bool(handled)
        except Exception:
            import traceback
            traceback.print_exc()
            return False

    def _handle_key(self, keyval: int) -> bool:
        c = self.composer
        if keyval in DEAD_KEYS:
            self._pending_combining = DEAD_KEYS[keyval]
            return True
        if keyval == KEY_ESCAPE:
            return c.escape()
        if keyval == KEY_BACKSPACE:
            if c.active:
                return c.backspace()
            c.note_idle_backspace()
            return False
        if keyval in (KEY_RETURN, KEY_KP_ENTER):
            return c.enter()
        if keyval == KEY_TAB:
            return c.tab() if c.active else False
        if keyval == KEY_SPACE:
            return c.space() if c.active else False
        if 0x31 <= keyval <= 0x39:
            return c.digit(keyval - 0x30) if c.active else False
        if keyval == KEY_LEFT:
            return c.left() if c.active else False
        if keyval == KEY_RIGHT:
            return c.right() if c.active else False
        if keyval == KEY_DOWN:
            return c.page_next() if c.active else False
        if keyval == KEY_UP:
            return c.page_prev() if c.active else False
        if keyval == KEY_PAGE_DOWN:
            return c.page_next() if c.active else False
        if keyval == KEY_PAGE_UP:
            return c.page_prev() if c.active else False

        char = self._char_for_keyval(keyval)
        if char is None:
            return False
        if self._pending_combining is not None and char.isalpha():
            combining = self._pending_combining
            self._pending_combining = None
            composed = unicodedata.normalize("NFC", char + combining)
            return c.type_char(composed)
        if c.active:
            if char.isalpha() or char in "'-" or ord(char) > 127:
                return c.type_char(char)
            was_latin = c.is_latin
            c.commit("punct")
            self._commit_punctuation(char, hint=was_latin)
            return True
        if char.isalpha() or ord(char) > 127:
            return c.type_char(char)
        if char in PUNCTUATION_MAP:
            self._commit_punctuation(char)
            return True
        return False

    def _commit_punctuation(self, char: str, hint: bool | None = None) -> None:
        ascii_style = hint if hint is not None else self.composer.should_use_ascii_punctuation()
        self.composer.log_punctuation(char, ascii_style)
        text = char if ascii_style else PUNCTUATION_MAP.get(char, char)
        self._commit(text)

    @staticmethod
    def _char_for_keyval(keyval: int) -> str | None:
        if 0x20 <= keyval <= 0x7E:
            return chr(keyval)
        if 0x100 <= keyval < 0xFF00:
            try:
                return chr(keyval)
            except ValueError:
                return None
        return None

    # -- IBus callbacks -------------------------------------------------------
    def do_focus_out(self) -> None:
        if self.composer.active:
            self.composer.abandon("deactivate")
        self._update_ui()

    def do_reset(self) -> None:
        if self.composer.active:
            self.composer.abandon("reset")
        self._update_ui()

    def do_candidate_clicked(self, index, button, state) -> bool:
        if self.composer.select_candidate(index):
            self._update_ui()
            return True
        return False

    def do_page_up(self) -> bool:
        if self.composer.page_prev():
            self._update_ui()
            return True
        return False

    def do_page_down(self) -> bool:
        if self.composer.page_next():
            self._update_ui()
            return True
        return False


def warmup() -> str:
    backend = make_backend()
    try:
        return backend.warmup()
    finally:
        backend.finalize()


def main() -> int:
    if "--warmup" in sys.argv:
        try:
            print("warmup:", warmup())
            return 0
        except Exception as exc:
            print(f"warmup failed: {exc}", file=sys.stderr)
            return 1
    IBus.init()
    bus = IBus.Bus()
    if not bus.is_connected():
        print("IBus bus is not connected (is ibus-daemon running?)", file=sys.stderr)
        return 1
    _dlog("main: creating factory")
    factory = IBus.Factory.new(bus.get_connection())
    factory.add_engine(ENGINE_NAME, PolylanginEngine)
    flags = getattr(IBus.BusNameFlag, "REPLACE_EXISTING", 0) if hasattr(IBus, "BusNameFlag") else 0
    try:
        result = bus.request_name(COMPONENT_NAME, flags)
    except TypeError:
        result = bus.request_name(COMPONENT_NAME)
    _dlog(f"main: request_name -> {result}")
    GLib.MainLoop().run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
