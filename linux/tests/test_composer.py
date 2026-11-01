"""Unit tests for the framework-agnostic Linux composer core.

Run from the repo root:  python3 -m unittest discover -s linux/tests -v
"""

from __future__ import annotations

import json
import pathlib
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from polylangin_core.composer import Composer  # noqa: E402
from polylangin_core.data import WordData  # noqa: E402
from polylangin_core.journal import Journal  # noqa: E402

DATA = WordData.load(ROOT / "polylangin_core" / "data")

CHINESE = {
    "nihao": ["你好", "你", "尼", "泥"],
    "shijie": ["世界", "时节"],
    "zhongwen": ["中文", "中问"],
    "feichang": ["非常", "飞常"],
    "le": ["了", "乐", "勒"],
    "de": ["的", "得", "地"],
    "shi": ["是", "事", "市", "时", "十", "使", "世", "视", "师", "式", "示", "石",
            "施", "史", "始", "识", "势", "适", "释", "士", "氏", "室", "试", "视"],
    "woshi": ["我是", "我时"],
    "bu": ["不", "部"],
    "neng": ["能"],
    "bunen": ["不能"],
    "pengyou": ["朋友"],
    "zhongguo": ["中国"],
    "zhangyunlong": ["张云龙"],
    "woshizhendeniubi": ["我是真的牛逼啊", "我是真的", "我是真的牛逼"],
    "niubi": ["牛逼", "牛比"],
}


class FakeBackend:
    def __init__(self) -> None:
        self.committed = ""
        self.pieces: list[str] = []
        self.context = ""
        self.app = "com.example.test"

    def convert(self, token: str):
        candidates = CHINESE.get(token, [token])
        self.last_page_size = 5
        return candidates, [""] * len(candidates)

    def select_candidate(self, buffer: str, page: int, index: int):
        if buffer == "woshizhendeniubi" and page == 0 and index == 1:
            return "niubi"
        return ""

    def commit(self, text: str) -> None:
        self.committed += text
        self.pieces.append(text)

    def surrounding_text(self) -> str:
        return self.context

    def app_id(self) -> str:
        return self.app


def make(tmp: str | None = None, context: str = "") -> tuple[Composer, FakeBackend, Journal]:
    backend = FakeBackend()
    backend.context = context
    journal = Journal(directory=pathlib.Path(tmp) if tmp else pathlib.Path(tempfile.mkdtemp()),
                      enabled=bool(tmp))
    composer = Composer(backend, data=DATA, journal=journal)
    return composer, backend, journal


def type_word(composer: Composer, word: str) -> None:
    for ch in word:
        composer.type_char(ch)


def read_events(journal: Journal) -> list[dict]:
    events = []
    for path in journal.directory.glob("*.jsonl"):
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                events.append(json.loads(line))
    return events


class ComposerTests(unittest.TestCase):
    def test_english_sentence(self) -> None:
        composer, backend, _ = make()
        for word in ["I", "am", "a", "good", "person"]:
            type_word(composer, word)
            composer.space()
        self.assertEqual(backend.committed, "I am a good person ")

    def test_chinese_word(self) -> None:
        composer, backend, _ = make()
        type_word(composer, "nihao")
        composer.space()
        self.assertEqual(backend.committed, "你好")

    def test_chinese_sentence_continuous(self) -> None:
        composer, backend, _ = make()
        type_word(composer, "nihao")
        composer.space()
        type_word(composer, "shijie")
        composer.space()
        self.assertEqual(backend.committed, "你好世界")

    def test_mixed_pinyin_english(self) -> None:
        composer, backend, _ = make()
        type_word(composer, "feichangnormal")
        composer.space()
        self.assertEqual(backend.committed, "非常normal")

    def test_change_stays_english(self) -> None:
        composer, backend, _ = make()
        type_word(composer, "change")
        composer.space()
        self.assertEqual(backend.committed, "change ")

    def test_of_after_english(self) -> None:
        composer, backend, _ = make()
        for word in ["lots", "of"]:
            type_word(composer, word)
            composer.space()
        self.assertEqual(backend.committed, "lots of ")

    def test_le_after_english_becomes_chinese(self) -> None:
        composer, backend, _ = make()
        for word in ["amazing", "work"]:
            type_word(composer, word)
            composer.space()
        type_word(composer, "le")
        composer.space()
        self.assertEqual(backend.committed, "amazing work 了")

    def test_french_context_keeps_le(self) -> None:
        composer, backend, _ = make(context="Je m'appelle Alex, j'habite à Montréal.")
        type_word(composer, "le")
        composer.space()
        self.assertEqual(backend.committed, "le ")

    def test_french_autocorrect(self) -> None:
        composer, backend, _ = make(context="C'est très bien, n'est-ce pas ?")
        type_word(composer, "beacoup")
        composer.space()
        self.assertEqual(backend.committed, "beaucoup ")

    def test_enter_commits_raw(self) -> None:
        composer, backend, _ = make()
        type_word(composer, "woshi")
        self.assertTrue(composer.enter())
        self.assertEqual(backend.committed, "woshi")

    def test_english_autocorrect(self) -> None:
        composer, backend, _ = make()
        type_word(composer, "teh")
        composer.space()
        self.assertEqual(backend.committed, "the ")

    def test_pinyin_typo_correction(self) -> None:
        composer, backend, _ = make()
        type_word(composer, "zhognwen")
        composer.space()
        self.assertEqual(backend.committed, "中文")

    def test_expanded_grid_row_selection(self) -> None:
        composer, backend, _ = make()
        type_word(composer, "shi")
        self.assertTrue(composer.down())      # expand
        self.assertTrue(composer.down())      # second row
        self.assertTrue(composer.digit(1))    # first column of second row
        self.assertEqual(backend.committed, CHINESE["shi"][9])

    def test_backspace_journal(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            composer, backend, journal = make(tmp)
            type_word(composer, "nihao")
            composer.backspace()
            type_word(composer, "o")
            composer.space()
            self.assertEqual(backend.committed, "你好")
            commits = [e for e in read_events(journal) if e["type"] == "commit"]
            self.assertEqual(commits[-1]["backspaces"], 1)
            self.assertEqual(commits[-1]["text"], "你好")
            self.assertEqual(commits[-1]["lang"], "zh")

    def test_escape_abandons(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            composer, backend, journal = make(tmp)
            type_word(composer, "nih")
            self.assertTrue(composer.escape())
            self.assertEqual(backend.committed, "")
            abandons = [e for e in read_events(journal) if e["type"] == "abandon"]
            self.assertEqual(abandons[-1]["buf"], "nih")
            self.assertEqual(abandons[-1]["reason"], "esc")

    def test_backspace_burst(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            composer, backend, journal = make(tmp)
            type_word(composer, "nihaoo")
            for _ in range(4):
                composer.backspace()
            bursts = [e for e in read_events(journal) if e["type"] == "backspace_burst"]
            self.assertTrue(bursts)
            self.assertGreaterEqual(bursts[-1]["count"], 4)

    def test_autocorrect_does_not_touch_valid_words(self) -> None:
        composer, backend, _ = make()
        for word in ["its", "reg", "pls", "KYC", "ACR"]:
            type_word(composer, word)
            composer.space()
        self.assertEqual(backend.committed, "its reg pls KYC ACR ")

    def test_contraction_autocorrect(self) -> None:
        composer, backend, _ = make()
        for word in ["dont", "thats"]:
            type_word(composer, word)
            composer.space()
        self.assertEqual(backend.committed, "don't that's ")

    def test_transposition_autocorrect(self) -> None:
        composer, backend, _ = make()
        type_word(composer, "teh")
        composer.space()
        self.assertEqual(backend.committed, "the ")

    def test_french_autocorrect_does_not_mangle_english(self) -> None:
        composer, backend, _ = make(context="C'est très bien, n'est-ce pas ?")
        type_word(composer, "pay")
        composer.space()
        self.assertEqual(backend.committed, "pay ")

    def test_pinyin_missing_letter_repair(self) -> None:
        composer, backend, _ = make()
        type_word(composer, "zhangyunlon")
        composer.space()
        self.assertEqual(backend.committed, "张云龙")

    def test_enter_passthrough_for_latin(self) -> None:
        composer, backend, _ = make()
        type_word(composer, "hello")
        self.assertFalse(composer.enter())  # let the app handle Enter too
        self.assertEqual(backend.committed, "hello")

    def test_enter_consumed_for_chinese(self) -> None:
        composer, backend, _ = make()
        type_word(composer, "nihao")
        self.assertTrue(composer.enter())
        self.assertEqual(backend.committed, "nihao")  # raw commit, no Chinese

    def test_multi_step_partial_selection(self) -> None:
        composer, backend, _ = make()
        type_word(composer, "woshizhendeniubi")
        composer.digit(2)  # candidate 2 = 我是真的, consumes "woshizhende"
        self.assertEqual(backend.committed, "我是真的")
        self.assertEqual(composer.buffer, "niubi")
        composer.space()   # now choose a candidate for niubi
        self.assertEqual(backend.committed, "我是真的牛逼")

    def test_full_sentence_selection_commits_everything(self) -> None:
        composer, backend, _ = make()
        type_word(composer, "woshizhendeniubi")
        composer.digit(1)  # candidate 1 = whole sentence
        self.assertEqual(backend.committed, "我是真的牛逼啊")
        self.assertFalse(composer.active)

    def test_punctuation_after_digit_is_ascii(self) -> None:
        for context in ["价格是2", "2", "版本 2.5"]:
            composer, _, _ = make(context=context)
            self.assertTrue(composer.should_use_ascii_punctuation(), context)

    def test_punctuation_latin_sentence_is_ascii(self) -> None:
        for context in ["I am fine", "This is a test", "他说 hello world"]:
            composer, _, _ = make(context=context)
            self.assertTrue(composer.should_use_ascii_punctuation(), context)

    def test_punctuation_chinese_sentence_is_fullwidth(self) -> None:
        for context in ["我今天很好", "你好世界再见 hello"]:
            composer, _, _ = make(context=context)
            self.assertFalse(composer.should_use_ascii_punctuation(), context)

    def test_punctuation_uses_text_since_last_terminator(self) -> None:
        composer, _, _ = make(context="上一句。今天不错")
        self.assertFalse(composer.should_use_ascii_punctuation())
        composer, _, _ = make(context="上一句。This is English")
        self.assertTrue(composer.should_use_ascii_punctuation())

    def test_language_context_detection(self) -> None:
        composer, _, _ = make(context="the quick brown fox jumps over the lazy dog")
        self.assertEqual(composer.detect_latin_language("the quick brown fox"), "en")
        self.assertEqual(composer.detect_latin_language("je suis très content de te voir"), "fr")


if __name__ == "__main__":
    unittest.main()
