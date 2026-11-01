//
//  PolylanginData.swift
//  Polylangin
//
//  Runtime data for pinyin/Latin detection:
//  - valid Hanyu Pinyin syllables (from rime-ice dicts)
//  - English word list (for "is this run a Latin word?" decisions)
//

import Foundation

final class PolylanginData {
  static let shared = PolylanginData()

  private(set) var syllables: Set<String> = []
  private(set) var syllablePrefixes: Set<String> = []
  private(set) var englishWords: Set<String> = []
  private(set) var englishPrefixes: Set<String> = []
  private(set) var commonWordRank: [String: Int] = [:]
  private(set) var frenchWords: Set<String> = []
  private(set) var frenchWordRank: [String: Int] = [:]
  private(set) var isLoaded = false

  private init() {}

  func loadIfNeeded() {
    guard !isLoaded else { return }
    isLoaded = true
    let res = Bundle.main.resourcePath ?? ""
    syllables = loadLines(path: res + "/polylangin/syllables.txt", lowercased: true)
    englishWords = loadLines(path: res + "/polylangin/english_words.txt", lowercased: true)
    if let french = try? String(contentsOfFile: res + "/polylangin/french_words.txt", encoding: .utf8) {
      var rank = 0
      for line in french.split(whereSeparator: \.isNewline) {
        let w = line.trimmingCharacters(in: .whitespaces).lowercased()
        if w.isEmpty { continue }
        frenchWords.insert(w)
        if frenchWordRank[w] == nil { frenchWordRank[w] = rank }
        rank += 1
      }
    }
    if let common = try? String(contentsOfFile: res + "/polylangin/english_common.txt", encoding: .utf8) {
      var rank = 0
      for line in common.split(whereSeparator: \.isNewline) {
        let w = line.trimmingCharacters(in: .whitespaces).lowercased()
        if w.isEmpty { continue }
        if commonWordRank[w] == nil { commonWordRank[w] = rank }
        rank += 1
      }
    }
    for s in syllables where !s.isEmpty {
      var prefix = ""
      for ch in s {
        prefix.append(ch)
        syllablePrefixes.insert(prefix)
      }
    }
    for w in englishWords where w.count >= 2 {
      var prefix = ""
      for ch in w {
        prefix.append(ch)
        englishPrefixes.insert(prefix)
      }
    }
  }

  private func loadLines(path: String, lowercased: Bool) -> Set<String> {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    var set = Set<String>()
    for line in text.split(whereSeparator: \.isNewline) {
      let s = lowercased ? line.lowercased() : String(line)
      guard !s.isEmpty else { continue }
      set.insert(s)
    }
    return set
  }

  /// True if the whole string can be split into complete valid syllables.
  func canSegmentFull(_ s: String) -> Bool {
    let chars = Array(s)
    let n = chars.count
    guard n > 0 else { return false }
    var dp = [Bool](repeating: false, count: n + 1)
    dp[0] = true
    for i in 0..<n where dp[i] {
      var token = ""
      var j = i
      while j < n {
        token.append(chars[j])
        j += 1
        if token.count > 6 { break }
        if syllables.contains(token) { dp[j] = true }
      }
    }
    return dp[n]
  }

  /// True if `s` is a pinyin prefix: it can be fully segmented into syllables,
  /// except that the final syllable may be incomplete (still being typed).
  func canSegmentPrefix(_ s: String) -> Bool {
    let chars = Array(s)
    let n = chars.count
    guard n > 0 else { return true }
    var dp = [Bool](repeating: false, count: n + 1)
    dp[0] = true
    for i in 0..<n where dp[i] {
      var token = ""
      var j = i
      while j < n {
        token.append(chars[j])
        j += 1
        if token.count > 6 { break }
        if syllables.contains(token) {
          dp[j] = true
        } else if j == n && syllablePrefixes.contains(token) {
          return true  // final token is a still-incomplete syllable
        }
        if syllablePrefixes.contains(token) || syllables.contains(token) {
          continue
        }
        break
      }
    }
    return dp[n]
  }

  func isEnglishPrefix(_ s: String) -> Bool {
    guard !s.isEmpty else { return false }
    return englishPrefixes.contains(s)
  }

  /// A word we accept as intentional English: either in the word list or in the
  /// top-10k common list (used to avoid "correcting" valid words).
  func isKnownEnglishWordOrCommon(_ s: String) -> Bool {
    englishWords.contains(s) || commonWordRank[s] != nil
  }

  private static let contractionFixes: [String: String] = [
    "dont": "don't", "cant": "can't", "wont": "won't", "isnt": "isn't",
    "arent": "aren't", "wasnt": "wasn't", "werent": "weren't", "hasnt": "hasn't",
    "havent": "haven't", "hadnt": "hadn't", "wouldnt": "wouldn't",
    "shouldnt": "shouldn't", "couldnt": "couldn't", "doesnt": "doesn't",
    "didnt": "didn't", "aint": "ain't", "thats": "that's", "whats": "what's",
    "wheres": "where's", "theres": "there's", "heres": "here's",
    "im": "I'm", "ive": "I've", "youre": "you're",
    "youve": "you've", "youll": "you'll", "theyre": "they're", "theyve": "they've",
    "weve": "we've", "shes": "she's", "hes": "he's",
  ]

  /// Common missing-apostrophe contractions (dont -> don't).
  func contractionFix(_ word: String) -> String? {
    Self.contractionFixes[word]
  }

  func isEnglishWord(_ s: String) -> Bool {
    guard !s.isEmpty else { return false }
    return englishWords.contains(s)
  }

  /// Split an invalid pinyin buffer into (pinyinPrefix, latinSuffix).
  /// Prefers the longest Latin suffix that could still become an English word.
  /// Conservative English typo fix.
  /// Only fixes typo *patterns* (letter swap, missing letter, doubled letter) and
  /// never performs arbitrary letter substitutions — the 2-week logs showed that
  /// substitutions turned valid words/acronyms into nonsense (reg->red, KYC->kfc).
  func spellCorrect(_ word: String) -> String? {
    let chars = Array(word)
    guard chars.count >= 3 else { return nil }
    var best: String?
    var bestRank = Int.max
    func consider(_ candidate: String) {
      guard candidate.count >= 2, candidate != word,
            candidate.unicodeScalars.allSatisfy({ $0.isASCII }) else { return }
      guard englishWords.contains(candidate) || commonWordRank[candidate] != nil else { return }
      let rank = commonWordRank[candidate] ?? 5000
      if rank < bestRank {
        bestRank = rank
        best = candidate
      }
    }
    // letter swap (teh -> the, taht -> that, recieve -> receive)
    for i in 0..<(chars.count - 1) {
      var c = chars
      c.swapAt(i, i + 1)
      consider(String(c))
    }
    // extra letter (needs at least 4 letters to stay meaningful)
    if chars.count >= 4 {
      for i in chars.indices {
        var c = chars
        c.remove(at: i)
        consider(String(c))
      }
    }
    // missing letter (skip 3-letter words: too easy to mangle pls/reg)
    if chars.count >= 4 {
      for i in 0...chars.count {
        for scalar in UnicodeScalar("a").value...UnicodeScalar("z").value {
          var c = chars
          c.insert(Character(UnicodeScalar(scalar)!), at: i)
          consider(String(c))
        }
      }
    }
    return best
  }

  /// Fix common pinyin typos: swapped letters (zhognwen), a missing letter
  /// (zhangyunlon -> zhangyunlong), or an extra letter. Only complete-pinyin
  /// candidates are accepted, so English words cannot be captured by accident.
  func pinyinTypoCorrect(_ s: String) -> String? {
    let chars = Array(s)
    guard chars.count >= 4, chars.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
    // 1) adjacent letter swap
    for i in 0..<(chars.count - 1) {
      var c = chars
      c.swapAt(i, i + 1)
      if canSegmentFull(String(c)) { return String(c) }
    }
    // 2) missing letter: try appending at the end first, and prefer common final
    // letters (g/n/r...), so zhangyunlon -> zhangyunlong, not an odd segmentation.
    let preferred: [Character] = ["g", "n", "r", "a", "e", "i", "o", "u", "s", "v"]
    let preferredSet = Set(preferred)
    let rest = (UnicodeScalar("a").value...UnicodeScalar("z").value)
      .compactMap { Character(UnicodeScalar($0)!) }
      .filter { !preferredSet.contains($0) }
    for i in stride(from: chars.count, through: 0, by: -1) {
      for letter in preferred + rest {
        var c = chars
        c.insert(letter, at: i)
        if canSegmentFull(String(c)) { return String(c) }
      }
    }
    // 3) extra letter
    if chars.count >= 5 {
      for i in chars.indices {
        var c = chars
        c.remove(at: i)
        if canSegmentFull(String(c)) { return String(c) }
      }
    }
    return nil
  }

  func isFrenchWord(_ word: String) -> Bool {
    frenchWords.contains(word)
  }

  /// Conservative French typo fix (swap / missing / extra letter only).
  func frenchSpellCorrect(_ word: String) -> String? {
    let chars = Array(word)
    guard chars.count >= 3 else { return nil }
    var best: String?
    var bestRank = Int.max
    func consider(_ candidate: String) {
      guard candidate.count >= 2, candidate != word, frenchWords.contains(candidate) else { return }
      let rank = frenchWordRank[candidate] ?? 20000
      if rank < bestRank {
        bestRank = rank
        best = candidate
      }
    }
    for i in 0..<(chars.count - 1) {
      var c = chars
      c.swapAt(i, i + 1)
      consider(String(c))
    }
    if chars.count >= 4 {
      for i in chars.indices {
        var c = chars
        c.remove(at: i)
        consider(String(c))
      }
      for i in 0...chars.count {
        for scalar in UnicodeScalar("a").value...UnicodeScalar("z").value {
          var c = chars
          c.insert(Character(UnicodeScalar(scalar)!), at: i)
          consider(String(c))
        }
      }
    }
    return best
  }

  func bestSplit(_ s: String) -> (String, String)? {
    let chars = Array(s)
    let n = chars.count
    guard n >= 3 else { return nil }
    for i in 1..<n {
      let prefix = String(chars[0..<i])
      let suffix = String(chars[i..<n])
      if suffix.count >= 2, isEnglishPrefix(suffix), canSegmentFull(prefix) {
        return (prefix, suffix)
      }
    }
    return nil
  }
}
