"""Language classification for a raw token (ported from SquirrelInputController)."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

from .data import WordData

FRENCH_DIACRITICS = set("éèêëàâäùûüîïôöçœæÉÈÊËÀÂÄÙÛÜÎÏÔÖÇŒÆ")
MAX_CANDIDATES = 27


@dataclass
class Conversion:
    candidates: list[str]
    comments: list[str]
    is_latin: bool


def normalize(token: str) -> str:
    lower = token.lower()
    return lower.replace("'", "").replace("-", "").replace("\u2011", "")


class Classifier:
    def __init__(self, data: WordData, convert: Callable[[str], tuple[list[str], list[str]]]):
        self.data = data
        self._convert = convert

    def classify(self, token: str, prefer_latin: bool, latin_language: str = "en") -> Conversion:
        if not token:
            return Conversion([], [], False)
        lower = token.lower()
        if not token.isascii():
            return Conversion([token], [""], True)

        normalized = normalize(token)
        bare = "'" not in token and "-" not in token
        french_word = normalized in self.data.french_words
        has_french_diacritics = any(ch in FRENCH_DIACRITICS for ch in token)
        if latin_language == "fr" and (french_word or has_french_diacritics):
            return Conversion([token], [""], True)

        pinyin_full = bare and self.data.can_segment_full(normalized)
        pinyin_ok = bare and (pinyin_full or self.data.can_segment_prefix(normalized))
        english_word = normalized in self.data.english_words
        english_prefix = normalized in self.data.english_prefixes
        starts_upper = token[:1].isupper()

        if starts_upper and (english_word or english_prefix):
            return self._english(token, normalized, pinyin_ok)

        if english_word:
            if prefer_latin or not pinyin_ok:
                return self._english(token, normalized, pinyin_ok)
            candidates, comments = self._convert(normalized)
            if not candidates:
                return Conversion([token], [""], True)
            return Conversion(candidates[:MAX_CANDIDATES], comments[:MAX_CANDIDATES], False)

        # Complete pinyin that is not an English word converts to Chinese even in
        # English context (le / de / shi ...); French context is handled above.
        if pinyin_full:
            candidates, comments = self._convert(normalized)
            if not candidates:
                return Conversion([token], [""], False)
            return Conversion(candidates[:MAX_CANDIDATES], comments[:MAX_CANDIDATES], False)

        if prefer_latin and english_prefix:
            return Conversion([token], [""], True)

        if prefer_latin and latin_language == "en" and not pinyin_full:
            if self._spell_english(normalized):
                return Conversion([token], [""], True)

        if bare and "'" not in token and "\u2011" not in token and "-" not in token:
            fixed = self.data.pinyin_typo_correct(normalized)
            if fixed:
                candidates, comments = self._convert(fixed)
                if candidates:
                    return Conversion(candidates[:MAX_CANDIDATES], comments[:MAX_CANDIDATES], False)

        split = self.data.best_split(normalized)
        if split:
            prefix, suffix = split
            candidates, _ = self._convert(prefix)
            converted = (candidates[0] if candidates else prefix) + suffix
            return Conversion([converted], [""], False)

        if pinyin_ok:
            candidates, comments = self._convert(normalized)
            if not candidates:
                return Conversion([token], [""], False)
            return Conversion(candidates[:MAX_CANDIDATES], comments[:MAX_CANDIDATES], False)

        return Conversion([token], [""], True)

    def _english(self, token: str, normalized: str, pinyin_ok: bool) -> Conversion:
        if not pinyin_ok:
            return Conversion([token], [""], True)
        chinese, comments = self._convert(normalized)
        merged = [token] + chinese
        merged_comments = [""] + comments
        return Conversion(merged[:MAX_CANDIDATES], merged_comments[:MAX_CANDIDATES], True)

    def _spell_english(self, word: str) -> str | None:
        if len(word) < 3 or not word.isascii() or self.data.is_known_english_word_or_common(word):
            return None
        return self.data.spell_correct_english(word)
