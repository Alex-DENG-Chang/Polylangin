"""Word data + pinyin segmentation helpers (ported from PolylanginData.swift)."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent / "data"
MAX_CANDIDATES = 27


def _load_lines(path: Path) -> list[str]:
    try:
        return [line.strip().lower() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    except OSError:
        return []


@dataclass
class WordData:
    syllables: set[str] = field(default_factory=set)
    syllable_prefixes: set[str] = field(default_factory=set)
    english_words: set[str] = field(default_factory=set)
    english_prefixes: set[str] = field(default_factory=set)
    english_rank: dict[str, int] = field(default_factory=dict)
    french_words: set[str] = field(default_factory=set)
    french_rank: dict[str, int] = field(default_factory=dict)

    @classmethod
    def load(cls, data_dir: Path | None = None) -> "WordData":
        directory = data_dir or DATA_DIR
        data = cls()
        data.syllables = set(_load_lines(directory / "syllables.txt"))
        for syllable in data.syllables:
            for i in range(1, len(syllable) + 1):
                data.syllable_prefixes.add(syllable[:i])
        data.english_words = set(_load_lines(directory / "english_words.txt"))
        for word in data.english_words:
            for i in range(1, len(word) + 1):
                data.english_prefixes.add(word[:i])
        data.english_words.update({"a", "i"})
        data.english_rank = {
            word: rank for rank, word in enumerate(_load_lines(directory / "english_common.txt"))
        }
        data.french_words = set(_load_lines(directory / "french_words.txt"))
        data.french_rank = {
            word: rank for rank, word in enumerate(_load_lines(directory / "french_words.txt"))
        }
        return data

    # -- English validity / contractions --------------------------------------
    def is_known_english_word_or_common(self, word: str) -> bool:
        return word in self.english_words or word in self.english_rank

    CONTRACTIONS = {
        "dont": "don't", "cant": "can't", "wont": "won't", "isnt": "isn't",
        "arent": "aren't", "wasnt": "wasn't", "werent": "weren't", "hasnt": "hasn't",
        "havent": "haven't", "hadnt": "hadn't", "wouldnt": "wouldn't",
        "shouldnt": "shouldn't", "couldnt": "couldn't", "doesnt": "doesn't",
        "didnt": "didn't", "aint": "ain't", "thats": "that's", "whats": "what's",
        "wheres": "where's", "theres": "there's", "heres": "here's",
        "im": "I'm", "ive": "I've", "youre": "you're", "youve": "you've",
        "youll": "you'll", "theyre": "they're", "theyve": "they've",
        "weve": "we've", "shes": "she's", "hes": "he's",
    }

    def is_french_word(self, word: str) -> bool:
        return word in self.french_words

    def contraction_fix(self, word: str) -> str | None:
        return self.CONTRACTIONS.get(word)

    # -- pinyin segmentation -------------------------------------------------
    def can_segment_full(self, text: str) -> bool:
        n = len(text)
        dp = [False] * (n + 1)
        dp[0] = True
        for i in range(n):
            if not dp[i]:
                continue
            for j in range(i + 1, min(n, i + 5) + 1):
                if text[i:j] in self.syllables:
                    dp[j] = True
        return dp[n]

    def can_segment_prefix(self, text: str) -> bool:
        if self.can_segment_full(text):
            return True
        n = len(text)
        for i in range(1, n):
            if self.can_segment_full(text[:i]) and text[i:] in self.syllable_prefixes:
                return True
        return False

    def pinyin_typo_correct(self, text: str) -> str | None:
        """Fix pinyin typos: letter swap, missing letter, or extra letter.

        Only complete-pinyin candidates are accepted so English words cannot be
        captured by accident.
        """
        if len(text) < 4 or not all(ch.isascii() and ch.isalpha() for ch in text):
            return None
        chars = list(text)
        # 1) adjacent swap
        for i in range(len(chars) - 1):
            swapped = chars.copy()
            swapped[i], swapped[i + 1] = swapped[i + 1], swapped[i]
            if self.can_segment_full("".join(swapped)):
                return "".join(swapped)
        # 2) missing letter (zhangyunlon -> zhangyunlong).
        # Try appending at the end first and prefer common final letters, so we
        # do not mis-correct to an odd but technically valid segmentation.
        ordered = [ord(c) for c in "gnraeiousv"] + [
            code for code in range(ord("a"), ord("z") + 1) if chr(code) not in "gnraeiousv"
        ]
        for i in range(len(chars), -1, -1):
            for code in ordered:
                inserted = chars.copy()
                inserted.insert(i, chr(code))
                if self.can_segment_full("".join(inserted)):
                    return "".join(inserted)
        # 3) extra letter
        if len(chars) >= 5:
            for i in range(len(chars)):
                if self.can_segment_full("".join(chars[:i] + chars[i + 1:])):
                    return "".join(chars[:i] + chars[i + 1:])
        return None

    def best_split(self, text: str) -> tuple[str, str] | None:
        """Split into a full-pinyin prefix + English prefix suffix (feichangnormal)."""
        for i in range(len(text) - 1, 1, -1):
            prefix, suffix = text[:i], text[i:]
            if suffix in self.english_prefixes and self.can_segment_full(prefix):
                return prefix, suffix
        return None

    # -- typo correction -----------------------------------------------------
    def _correct(self, word: str, vocabulary: set[str], rank: dict[str, int]) -> str | None:
        """Conservative typo fix: swap / missing letter / extra letter only."""
        if len(word) < 3:
            return None
        best: str | None = None
        best_rank = 20_000

        def consider(candidate: str) -> None:
            nonlocal best, best_rank
            if len(candidate) < 2 or candidate == word:
                return
            if not candidate.isascii():
                return
            if candidate not in vocabulary and candidate not in rank:
                return
            candidate_rank = rank.get(candidate, 5_000)
            if candidate_rank < best_rank:
                best_rank = candidate_rank
                best = candidate

        chars = list(word)
        for i in range(len(chars) - 1):
            swapped = chars.copy()
            swapped[i], swapped[i + 1] = swapped[i + 1], swapped[i]
            consider("".join(swapped))
        if len(chars) >= 4:
            for i in range(len(chars)):
                consider("".join(chars[:i] + chars[i + 1:]))
            for i in range(len(chars) + 1):
                for code in range(ord("a"), ord("z") + 1):
                    inserted = chars.copy()
                    inserted.insert(i, chr(code))
                    consider("".join(inserted))
        return best

    def spell_correct_english(self, word: str) -> str | None:
        return self._correct(word, self.english_words, self.english_rank)

    def spell_correct_french(self, word: str) -> str | None:
        return self._correct(word, self.french_words, self.french_rank)
