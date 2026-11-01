# Polylangin Changelog

Polylangin is a local, mixed-language input method for macOS (Rime/Squirrel fork).
中文 / English / Français — 无需切换输入模式。

## 0.9 (2026-10-18)

- Localized input-source name: menu shows **Polylangin v0.9** instead of the raw mode ID.
- French support:
  - French frequency word list (top 20k) + French autocorrect.
  - Context language detection (NaturalLanguage framework, French diacritics, function words).
  - French words such as `le`/`la`/`sa`/`un` no longer turn into Chinese in French context.
  - Chinese can still be typed mid-French (continuous pinyin that is not a French word).
- Candidate paging: up to 27 candidates (3 pages); ←/→ move across all,
  PageUp/PageDown flip pages, 1–9 select on the current page.
- Input-source duplicate cleanup: third-party sources are only written to
  `com.apple.inputsources.plist` (not HIToolbox), fixing duplicated entries in
  System Settings and duplicate candidate windows.
- `tools/install-and-select.sh` now automates install + enable + select.

## 0.8 — 0.8.1

- Context-aware language detection from the text before the caret.
- Capitalized words default to English (`But`, `The`, `I`).
- English autocorrect with a top-10k frequency ranking.
- Pinyin/nasal fuzzy input (g-final nasals only).

## 0.7

- Shift no longer toggles Chinese/ASCII mode or flashes the 中 icon.
- Complete pinyin that is not an English word converts to Chinese even in English
  context (`le`, `de`).
- Modifier keys are no longer forwarded to Rime.

## 0.6

- English punctuation (`. , ! ? ; :`) is emitted in half width in English context.
- Candidate window stays hidden while typing English.
- Local key log at `~/Library/Logs/Polylangin/keylog.txt`.

## 0.5

- Complete English words always win over pinyin (`change`, `of`, `keep`).
- Enter commits the raw Latin input (standard IME escape hatch).
- Pinyin typo correction for transposed letters (`zhognwen` → `zhongwen`).

## 0.4

- Inline preedit shows the raw Latin keys (not the converted Chinese).
- Default context is English; Chinese after English still works.

## 0.3

- Single space confirms (standard habit); English words get a trailing space.
- Context-aware English vs Chinese classification.
- Arrow keys no longer leak into Rime.

## 0.2

- Host-side composer: everything stays in the preedit until confirmed.
- Candidate window laid out horizontally.

## 0.1

- Squirrel 1.1.2 fork with librime and rime-ice data.
- Bundle `app.polylangin.inputmethod.Polylangin` installed to `~/Library/Input Methods`.
