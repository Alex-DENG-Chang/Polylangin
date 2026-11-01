//
//  PolylanginJournal.swift
//  Polylangin
//
//  Local-only typing journal for iterating on the IME with real usage data.
//  Writes JSON Lines to ~/Desktop/Polylangin-logs/YYYY-MM-DD.jsonl (falls back
//  to ~/Library/Logs/Polylangin if the Desktop is not writable). Nothing is
//  ever sent anywhere. Secure input (password fields) is never logged.
//

import AppKit
import Carbon

final class PolylanginJournal {
  static let shared = PolylanginJournal()

  private let queue = DispatchQueue(label: "app.polylangin.journal")
  private let directory: URL
  private var handle: FileHandle?
  private var currentDay: String = ""
  private let isoFormatter = ISO8601DateFormatter()
  private var lastApp: String = ""

  private init() {
    directory = Self.prepareDirectory()
    Self.writeReadme(at: directory)
  }

  var path: String { directory.path }

  private static func prepareDirectory() -> URL {
    let fm = FileManager.default
    let desktop = fm.homeDirectoryForCurrentUser
      .appendingPathComponent("Desktop/Polylangin-logs", isDirectory: true)
    do {
      try fm.createDirectory(at: desktop, withIntermediateDirectories: true)
      let probe = desktop.appendingPathComponent(".write-test")
      try Data("ok".utf8).write(to: probe)
      try? fm.removeItem(at: probe)
      return desktop
    } catch {
      let fallback = fm.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Polylangin", isDirectory: true)
      try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
      return fallback
    }
  }

  private static func writeReadme(at directory: URL) {
    let url = directory.appendingPathComponent("README.txt")
    guard !FileManager.default.fileExists(atPath: url.path) else { return }
    let text = """
    Polylangin typing journal (local only)

    One JSON object per line, one file per day: YYYY-MM-DD.jsonl
    Fields: ts (ISO8601), type, app (bundle id, when changed), and per event:
      key            kc, chars, buf, composer, expanded
      backspace      buf, composer
      backspace_burst count, window, composer, buf
      commit         text, raw, reason, lang, keys, backspaces, ms, grid, rank, correction
      raw_commit     text, keys, ms
      abandon        buf, reason, keys, backspaces, ms
      autocorrect    from, to, lang
      grid_open      count
    Secure input (password fields) is never recorded. Delete these files after
    they have been analysed.
    """
    try? text.data(using: .utf8)?.write(to: url)
  }

  private static func dayString() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
  }

  /// An event. Never records anything while secure input is active (passwords).
  func event(_ type: String, _ fields: [String: Any] = [:], app: String? = nil) {
    if IsSecureEventInputEnabled() { return }
    var payload = fields
    payload["ts"] = isoFormatter.string(from: Date())
    payload["type"] = type
    if let app, !app.isEmpty {
      lastApp = app
      payload["app"] = app
    }
    guard JSONSerialization.isValidJSONObject(payload),
          let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
    queue.sync { self.append(data) }
  }

  private func append(_ data: Data) {
    let day = Self.dayString()
    if day != currentDay || handle == nil {
      currentDay = day
      let url = directory.appendingPathComponent("\(day).jsonl")
      if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
      }
      handle = try? FileHandle(forWritingTo: url)
      _ = try? handle?.seekToEnd()
    }
    guard let handle else { return }
    try? handle.write(contentsOf: data)
    try? handle.write(contentsOf: Data([0x0A]))
  }
}
