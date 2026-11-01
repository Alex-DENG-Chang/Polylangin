"""Host-side mixed-language composer for the Linux port.

Ported from SquirrelInputController.swift. The frontend only needs to:
  * forward printable characters / keys to this object,
  * render `preedit` and the candidate list (horizontal, paged or expanded),
  * call `set_commit_handler` to insert text into the focused application.
"""

from __future__ import annotations

import re
import time
from dataclasses import dataclass
from typing import Callable, Protocol

from .classification import FRENCH_DIACRITICS, Classifier, Conversion
from .data import MAX_CANDIDATES, WordData
from .journal import Journal

GRID_COLUMNS = 9
BACKSPACE_BURST_WINDOW = 1.2
BACKSPACE_BURST_COUNT = 4


class Backend(Protocol):
    def convert(self, token: str) -> tuple[list[str], list[str]]: ...
    def commit(self, text: str) -> None: ...
    def surrounding_text(self) -> str: ...
    def app_id(self) -> str: ...


@dataclass
class CandidatePage:
    page_index: int
    page_count: int
    candidates: list[str]
    comments: list[str]
    highlighted: int
    expanded: bool


FRENCH_MARKERS = {
    "le", "la", "les", "de", "des", "du", "un", "une", "et", "est", "je", "tu", "il", "elle",
    "nous", "vous", "ils", "elles", "mon", "ma", "mes", "ton", "ta", "tes", "son", "sa", "ses",
    "ce", "cette", "ces", "que", "qui", "dans", "pour", "avec", "sur", "pas", "ne", "plus",
    "mais", "ou", "où", "donc", "car", "si", "comme", "quand", "très", "tout", "tous", "faire",
    "être", "avoir", "au", "aux", "en", "y", "monde", "c'est", "qu'il", "qu'elle",
}
ENGLISH_MARKERS = {
    "the", "and", "you", "that", "was", "for", "are", "with", "his", "they", "this", "have",
    "from", "one", "had", "word", "but", "not", "what", "all", "were", "when", "your", "can",
    "said", "there", "use", "each", "which", "she", "how", "their", "will", "would", "about",
    "write", "like", "so", "these", "her", "long", "make", "thing", "see", "him",
}


class Composer:
    def __init__(
        self,
        backend: Backend,
        data: WordData | None = None,
        journal: Journal | None = None,
        commit_handler: Callable[[str], None] | None = None,
    ) -> None:
        self.backend = backend
        self.data = data or WordData.load()
        self.classifier = Classifier(self.data, backend.convert)
        self.journal = journal
        self._commit_handler = commit_handler or backend.commit

        self.buffer = ""
        self.candidates: list[str] = []
        self.comments: list[str] = []
        self.highlight = 0
        self.expanded = False
        self.page_size = 9
        self.prefer_latin = True
        self.latin_language = "en"
        self.is_latin = False

        self._episode_start = time.monotonic()
        self._episode_keys = 0
        self._episode_backspaces = 0
        self._episode_grid_used = False
        self._episode_correction = ""
        self._last_backspace_times: list[float] = []
        self._last_tab = 0.0

    # -- state for the frontend ------------------------------------------------
    @property
    def active(self) -> bool:
        return bool(self.buffer)

    @property
    def preedit(self) -> str:
        return self.buffer

    def candidate_page(self) -> CandidatePage:
        total = len(self.candidates)
        if not total:
            return CandidatePage(0, 1, [], [], 0, self.expanded)
        if self.expanded:
            size = GRID_COLUMNS * 9
            return CandidatePage(0, 1, self.candidates[:size], self.comments[:size],
                                 self.highlight, True)
        page = self.highlight // GRID_COLUMNS
        pages = (total + GRID_COLUMNS - 1) // GRID_COLUMNS
        start = page * GRID_COLUMNS
        end = min(start + GRID_COLUMNS, total)
        return CandidatePage(page, pages, self.candidates[start:end],
                             self.comments[start:end], self.highlight - start, False)

    # -- context ---------------------------------------------------------------
    def _app(self) -> str:
        try:
            return self.backend.app_id()
        except Exception:
            return ""

    def _refresh_context(self) -> None:
        try:
            text = self.backend.surrounding_text() or ""
        except Exception:
            text = ""
        line = ""
        for candidate_line in reversed(text.splitlines()):
            if candidate_line.strip():
                line = candidate_line
                break
        line = line or text
        cjk = sum(1 for ch in line if "\u4e00" <= ch <= "\u9fff")
        latin = sum(1 for ch in line if ch.isascii() and ch.isalpha())
        if cjk or latin:
            self.prefer_latin = latin >= cjk
        else:
            self.prefer_latin = True
        if self.prefer_latin:
            self.latin_language = self.detect_latin_language(line)

    def detect_latin_language(self, text: str) -> str:
        if any(ch in FRENCH_DIACRITICS for ch in text):
            return "fr"
        french = english = 0
        for word in re.findall(r"[a-zA-ZÀ-ÿœŒæÆ']+", text.lower()):
            if word in FRENCH_MARKERS or word in self.data.french_words:
                french += 1
            if word in ENGLISH_MARKERS or word in self.data.english_words:
                english += 1
        if french and french >= english:
            return "fr"
        return "en"

    # -- episode / journal -----------------------------------------------------
    def _start_episode(self) -> None:
        self._episode_start = time.monotonic()
        self._episode_keys = 0
        self._episode_backspaces = 0
        self._episode_grid_used = False
        self._episode_correction = ""

    def _log(self, event_type: str, fields: dict | None = None) -> None:
        if self.journal:
            self.journal.event(event_type, fields, app=self._app())

    def _note_backspace(self, composing: bool) -> None:
        now = time.monotonic()
        self._last_backspace_times.append(now)
        self._last_backspace_times = [t for t in self._last_backspace_times
                                      if now - t <= BACKSPACE_BURST_WINDOW]
        if len(self._last_backspace_times) >= BACKSPACE_BURST_COUNT:
            self._log("backspace_burst", {
                "count": len(self._last_backspace_times),
                "window": BACKSPACE_BURST_WINDOW,
                "composer": composing,
                "buf": self.buffer,
            })
            self._last_backspace_times.clear()

    def note_idle_backspace(self) -> None:
        """Backspace pressed while we have no composition (deleting committed text)."""
        self._note_backspace(False)
        self._log("key", {"chars": "\b", "buf": "", "composer": False, "expanded": False})

    # -- recompute -------------------------------------------------------------
    def _recompute(self) -> None:
        conversion: Conversion = self.classifier.classify(self.buffer, self.prefer_latin,
                                                          self.latin_language)
        self.candidates = conversion.candidates
        self.comments = conversion.comments
        self.is_latin = conversion.is_latin
        self.highlight = max(0, min(self.highlight, len(self.candidates) - 1))
        try:
            self.page_size = max(1, int(getattr(self.backend, "last_page_size", self.page_size) or self.page_size))
        except (TypeError, ValueError):
            self.page_size = 9

    # -- key handling ----------------------------------------------------------
    def type_char(self, char: str, keycode: int | None = None) -> bool:
        if not char or len(char) != 1:
            return False
        if not self.buffer:
            self._refresh_context()
            self._start_episode()
        self.expanded = False
        self.buffer += char
        self._episode_keys += 1
        self._log("key", {"kc": keycode if keycode is not None else ord(char),
                          "chars": char, "buf": self.buffer,
                          "composer": True, "expanded": False})
        self.highlight = 0
        self._recompute()
        return True

    def note_idle_key(self, char: str, keycode: int | None = None) -> None:
        self._log("key", {"kc": keycode if keycode is not None else ord(char),
                          "chars": char, "buf": self.buffer,
                          "composer": False, "expanded": False})

    def backspace(self) -> bool:
        if not self.buffer:
            return False
        self.expanded = False
        self.buffer = self.buffer[:-1]
        self.highlight = 0
        self._episode_backspaces += 1
        self._note_backspace(True)
        self._log("backspace", {"buf": self.buffer, "composer": True})
        self._recompute()
        return True

    def space(self) -> bool:
        if not self.buffer:
            self._commit_handler(" ")
            return True
        self.commit("space", trailing=self.is_latin)
        return True

    def enter(self) -> bool:
        if not self.buffer:
            return False
        was_latin = self.is_latin
        self.raw_commit()
        # Latin input: let the application handle Enter as well (chat: send,
        # editor: newline).  Chinese input keeps the classic raw-commit behaviour.
        return not was_latin

    def escape(self) -> bool:
        if self.expanded:
            self.expanded = False
            return True
        if not self.buffer:
            return False
        self.abandon("esc")
        return True

    def tab(self) -> bool:
        if not self.buffer:
            return False
        now = time.monotonic()
        if now - self._last_tab <= 0.35:
            self._last_tab = 0.0
            self.abandon("tab")
        else:
            self._last_tab = now
        return True

    def digit(self, number: int) -> bool:
        if not self.buffer:
            return False
        if self.expanded:
            index = (self.highlight // GRID_COLUMNS) * GRID_COLUMNS + number - 1
        else:
            index = (self.highlight // GRID_COLUMNS) * GRID_COLUMNS + number - 1
        if 0 <= index < len(self.candidates):
            self.highlight = index
            self.commit("digit")
            return True
        return True

    def left(self) -> bool:
        if not self.buffer or len(self.candidates) <= 1:
            return False
        if self.expanded:
            row_start = (self.highlight // GRID_COLUMNS) * GRID_COLUMNS
            self.highlight = max(self.highlight - 1, row_start)
        else:
            self.highlight = max(self.highlight - 1, 0)
        return True

    def right(self) -> bool:
        if not self.buffer or len(self.candidates) <= 1:
            return False
        if self.expanded:
            row_start = (self.highlight // GRID_COLUMNS) * GRID_COLUMNS
            row_end = min(row_start + GRID_COLUMNS - 1, len(self.candidates) - 1)
            self.highlight = min(self.highlight + 1, row_end)
        else:
            self.highlight = min(self.highlight + 1, len(self.candidates) - 1)
        return True

    def down(self) -> bool:
        if not self.buffer:
            return False
        if not self.expanded:
            self.expanded = True
            self._episode_grid_used = True
            self._log("grid_open", {"count": len(self.candidates)})
        else:
            row = self.highlight // GRID_COLUMNS
            column = self.highlight % GRID_COLUMNS
            rows = max(1, (len(self.candidates) + GRID_COLUMNS - 1) // GRID_COLUMNS)
            new_row = min(row + 1, rows - 1)
            self.highlight = min(new_row * GRID_COLUMNS + column, len(self.candidates) - 1)
        return True

    def up(self) -> bool:
        if not self.buffer:
            return False
        if not self.expanded:
            return True
        row = self.highlight // GRID_COLUMNS
        column = self.highlight % GRID_COLUMNS
        new_row = max(row - 1, 0)
        self.highlight = min(new_row * GRID_COLUMNS + column, len(self.candidates) - 1)
        return True

    def page_next(self) -> bool:
        if not self.buffer or not self.candidates:
            return False
        page = self.highlight // GRID_COLUMNS
        pages = (len(self.candidates) + GRID_COLUMNS - 1) // GRID_COLUMNS
        if page + 1 < pages:
            self.highlight = min((page + 1) * GRID_COLUMNS, len(self.candidates) - 1)
        return True

    def page_prev(self) -> bool:
        if not self.buffer or not self.candidates:
            return False
        page = self.highlight // GRID_COLUMNS
        if page > 0:
            self.highlight = (page - 1) * GRID_COLUMNS
        return True

    def select_candidate(self, page_local_index: int) -> bool:
        page = self.candidate_page()
        absolute = page.page_index * GRID_COLUMNS + page_local_index
        if 0 <= absolute < len(self.candidates):
            self.highlight = absolute
            self.commit("click")
            return True
        return False

    # -- commit / abandon ------------------------------------------------------
    @staticmethod
    def _match_case(replacement: str, original: str) -> str:
        if original[:1].isupper():
            return replacement[:1].upper() + replacement[1:]
        return replacement

    @staticmethod
    def _is_protected_token(word: str) -> bool:
        letters = "".join(ch for ch in word if ch.isalpha())
        if any(ch.isdigit() for ch in word):
            return True
        if sum(1 for ch in letters if ch.isupper()) >= 2:
            return True
        return len(letters) <= 1

    SENTENCE_TERMINATORS = set("。！？.!?;；…\n")

    def should_use_ascii_punctuation(self, text: str | None = None) -> bool:
        """ASCII punctuation after digits, and when the current sentence is
        Latin-dominant; Chinese punctuation when CJK dominates."""
        if text is None:
            try:
                text = self.backend.surrounding_text() or ""
            except Exception:
                text = ""
        if not text:
            return self.prefer_latin
        stripped = text.rstrip()
        if stripped and stripped[-1].isdigit():
            return True
        start = 0
        for i in range(len(text) - 1, -1, -1):
            if text[i] in self.SENTENCE_TERMINATORS:
                start = i + 1
                break
        segment = text[start:]
        latin = sum(1 for ch in segment if ch.isascii() and ch.isalpha())
        cjk = sum(1 for ch in segment if "\u4e00" <= ch <= "\u9fff")
        if latin == 0 and cjk == 0:
            return self.prefer_latin
        return latin > cjk

    def log_punctuation(self, char: str, ascii_style: bool) -> None:
        self._log("punct", {"char": char, "ascii": ascii_style})

    def _autocorrect(self, text: str) -> str:
        lower = text.lower()
        if len(lower) < 2 or "'" in lower or "-" in lower:
            return text
        if not all(ch.isascii() and ch.isalpha() for ch in lower):
            return text
        if self._is_protected_token(text):
            return text
        if self.latin_language == "fr" or any(ch in FRENCH_DIACRITICS for ch in text):
            return self._autocorrect_french(text, lower)
        return self._autocorrect_english(text, lower)

    def _autocorrect_english(self, word: str, lower: str) -> str:
        contraction = self.data.contraction_fix(lower)
        if contraction:
            fixed = self._match_case(contraction, word)
            self._record_correction(word, fixed, "en")
            return fixed
        if self.data.is_known_english_word_or_common(lower):
            return word
        if len(lower) < 3:
            return word
        corrected = self.data.spell_correct_english(lower)
        if not corrected:
            return word
        fixed = self._match_case(corrected, word)
        self._record_correction(word, fixed, "en")
        return fixed

    def _autocorrect_french(self, word: str, lower: str) -> str:
        if self.data.is_french_word(lower) or self.data.is_known_english_word_or_common(lower):
            return word
        if len(lower) < 3 or not lower.isascii():
            return word
        corrected = self.data.spell_correct_french(lower)
        if not corrected:
            return word
        fixed = self._match_case(corrected, word)
        self._record_correction(word, fixed, "fr")
        return fixed

    def _record_correction(self, word: str, fixed: str, language: str) -> None:
        self._episode_correction = f"{word}->{fixed}"
        self._log("autocorrect", {"from": word, "to": fixed, "lang": language})

    def _is_pure_pinyin(self) -> bool:
        lower = self.buffer.lower()
        if not lower or not all(ch.isascii() and ch.isalpha() for ch in lower):
            return False
        return self.data.can_segment_prefix(lower) or self.data.can_segment_full(lower)

    def _try_partial_commit(self, reason: str) -> str | None:
        """Multi-step selection: commit only the selected candidate's part and
        keep the remaining pinyin in the composition (woshizhende|niubi)."""
        if reason not in ("space", "digit", "click"):
            return None
        if self.is_latin or not self.buffer or not self.candidates:
            return None
        if not self._is_pure_pinyin():
            return None
        select = getattr(self.backend, "select_candidate", None)
        if select is None:
            return None
        index = max(0, min(self.highlight, len(self.candidates) - 1))
        page = max(1, self.page_size)
        page_index = index // page
        local_index = index % page
        remaining = select(self.buffer, page_index, local_index)
        if not remaining or not self.buffer.lower().endswith(remaining.lower()):
            return None
        selected = self.candidates[index]
        old_buffer = self.buffer
        self._commit_handler(selected)
        self._log("commit_partial", {
            "text": selected, "raw": old_buffer, "remaining": remaining,
            "index": index, "page": page_index, "local": local_index,
        })
        self._episode_start = time.monotonic()
        self._episode_keys = 0
        self._episode_backspaces = 0
        self._episode_grid_used = False
        self._episode_correction = ""
        self.buffer = remaining
        self.highlight = 0
        self.expanded = False
        self._recompute()
        return selected

    def commit(self, reason: str = "space", trailing: bool = False) -> str:
        if not self.buffer:
            return ""
        partial = self._try_partial_commit(reason)
        if partial is not None:
            return partial
        index = max(0, min(self.highlight, len(self.candidates) - 1))
        text = self.candidates[index] if self.candidates else self.buffer
        if index == 0 and text == self.buffer and self.is_latin:
            text = self._autocorrect(text)
        if trailing and not text.endswith(" "):
            text += " "
        elapsed = int((time.monotonic() - self._episode_start) * 1000)
        language = ("fr" if self.latin_language == "fr" else "en") if self.is_latin else "zh"
        self._log("commit", {
            "text": text,
            "raw": self.buffer,
            "reason": reason,
            "lang": language,
            "keys": self._episode_keys,
            "backspaces": self._episode_backspaces,
            "ms": elapsed,
            "grid": self._episode_grid_used,
            "rank": self.highlight,
            "correction": self._episode_correction,
        })
        self._commit_handler(text)
        self.prefer_latin = trailing or self.is_latin
        self._reset()
        return text

    def raw_commit(self) -> str:
        if not self.buffer:
            return ""
        text = self.buffer
        elapsed = int((time.monotonic() - self._episode_start) * 1000)
        self._log("raw_commit", {
            "text": text,
            "keys": self._episode_keys,
            "ms": elapsed,
            "backspaces": self._episode_backspaces,
        })
        self._commit_handler(text)
        self.prefer_latin = self.is_latin
        self._reset()
        return text

    def abandon(self, reason: str = "clear") -> None:
        if not self.buffer:
            return
        elapsed = int((time.monotonic() - self._episode_start) * 1000)
        self._log("abandon", {
            "buf": self.buffer,
            "reason": reason,
            "keys": self._episode_keys,
            "backspaces": self._episode_backspaces,
            "ms": elapsed,
        })
        self._reset()

    def _reset(self) -> None:
        self.buffer = ""
        self.candidates = []
        self.comments = []
        self.highlight = 0
        self.expanded = False
        self.is_latin = False
        self._episode_correction = ""
