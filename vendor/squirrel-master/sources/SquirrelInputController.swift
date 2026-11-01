//
//  SquirrelInputController.swift
//  Squirrel
//
//  Created by Leo Liu on 5/7/24.
//

import InputMethodKit
import NaturalLanguage

final class SquirrelInputController: IMKInputController {
  private static let keyRollOver = 50
  private static var unknownAppCnt: UInt = 0

  // Canadian-CSA circumflex dead-key compositions (â ê î ô û ...)
  private static let circumflexMap: [Character: Character] = [
    "a": "â", "e": "ê", "i": "î", "o": "ô", "u": "û",
    "A": "Â", "E": "Ê", "I": "Î", "O": "Ô", "U": "Û"
  ]

  private weak var client: IMKTextInput?

  private func journal(_ type: String, _ fields: [String: Any] = [:]) {
    PolylanginJournal.shared.event(type, fields, app: client?.bundleIdentifier())
  }
  private let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var lastModifiers: NSEvent.ModifierFlags = .init()
  private var session: RimeSessionId = 0
  private var schemaId: String = ""
  private var inlinePreedit = false
  private var inlineCandidate = false
  private var chordKeyCodes: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  private var chordModifiers: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  private var chordKeyCount: Int = 0
  private var chordTimer: Timer?
  private var chordDuration: TimeInterval = 0
  private var currentApp: String = ""

  // MARK: - Polylangin multilingual layer
  private let plData = PolylanginData.shared
  private var plRaw: String = ""
  private var plLower: String = ""
  private var plLatin = false
  private var plLastTab: TimeInterval = 0
  private var plCircumflexPending = false

  // Composer v0.2: buffer everything, commit only on explicit gesture
  private var plComposeBuffer = ""
  private var plComposeDisplay = ""
  private var plComposeCandidates: [String] = []
  private var plComposeComments: [String] = []
  private var plComposeOverride: String?
  private var plComposeLastSpace: TimeInterval = 0
  private var plComposeLastTab: TimeInterval = 0
  private var plAuxSession: RimeSessionId = 0
  private enum LatinLanguage { case english, french }
  private static let frenchDiacritics: Set<Character> = [
    "é", "è", "ê", "ë", "à", "â", "ä", "ù", "û", "ü", "î", "ï", "ô", "ö", "ç", "œ", "æ",
    "É", "È", "Ê", "Ë", "À", "Â", "Ä", "Ù", "Û", "Ü", "Î", "Ï", "Ô", "Ö", "Ç", "Œ", "Æ",
  ]
  private var plLatinLanguage: LatinLanguage = .english
  private var plGridExpanded = false
  private var plGridPanel: PolylanginGridPanel?
  private var plComposePageSize = 5
  private var plComposePage = 0
  private var plComposeHighlight = 0
  private var plComposeLastWasLatin = false
  private var lastCommittedWasLatin = true
  private var plComposerActive: Bool { !plComposeBuffer.isEmpty }

  // Typing journal bookkeeping (local analysis only).
  private var plEpisodeStart: TimeInterval = 0
  private var plEpisodeKeys = 0
  private var plEpisodeBackspaces = 0
  private var plEpisodeGridUsed = false
  private var plEpisodeCorrection = ""
  private var plCommitReason = "unknown"
  private var plBackspaceTimes: [TimeInterval] = []

  // swiftlint:disable:next cyclomatic_complexity
  override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    guard let event = event else { return false }
    let modifiers = event.modifierFlags
    let changes = lastModifiers.symmetricDifference(modifiers)

    // Return true to consume the key event; return false to pass it to the client app.
    var handled = false

    if session == 0 || !rimeAPI.find_session(session) {
      createSession()
      if session == 0 {
        return false
      }
    }

    self.client ?= sender as? IMKTextInput
    if let app = client?.bundleIdentifier(), currentApp != app {
      currentApp = app
      updateAppOptions()
      PolylanginJournal.shared.event("app_change", ["app": app])
    }

    switch event.type {
    case .flagsChanged:
      // Polylangin: modifiers only matter for the current key event (via
      // NSEvent.modifierFlags). Do not forward them to Rime, so Shift no longer
      // toggles ascii_mode or flashes the 中/Ａ status icon.
      lastModifiers = modifiers
      handled = true

    case .keyDown:
      // Let client apps handle Command shortcuts.
      if modifiers.contains(.command) {
        break
      }

      let keyCode = event.keyCode
      plLog("KEY kc=\(keyCode) chars=[\(event.characters ?? "")] mods=\(modifiers.rawValue) ctxLatin=\(lastCommittedWasLatin) buf=[\(plComposeBuffer)]")
      if !modifiers.contains(.control), !modifiers.contains(.option) {
        journal("key", ["kc": Int(keyCode), "chars": event.characters ?? "",
                        "buf": plComposeBuffer, "composer": plComposerActive,
                        "expanded": plGridExpanded])
        if keyCode == 51 {
          let now = ProcessInfo.processInfo.systemUptime
          plBackspaceTimes.append(now)
          plBackspaceTimes.removeAll { now - $0 > 1.2 }
          if plBackspaceTimes.count >= 4 {
            journal("backspace_burst", ["count": plBackspaceTimes.count, "window": 1.2,
                                        "composer": plComposerActive, "buf": plComposeBuffer])
            plBackspaceTimes.removeAll()
          }
        }
      }

      // MARK: Polylangin composer policy (mode-less; Shift 中/西 toggle disabled)
      plData.loadIfNeeded()
      if rimeAPI.get_option(session, "ascii_mode") {
        rimeAPI.set_option(session, "ascii_mode", false)
      }
      if let handled = plHandleKey(event: event, modifiers: modifiers, keyCode: keyCode) {
        return handled
      }

      var keyChars = event.charactersIgnoringModifiers
      let capitalModifiers = modifiers.isSubset(of: [.shift, .capsLock])
      if let code = keyChars?.first,
         (capitalModifiers && !code.isLetter) || (!capitalModifiers && !code.isASCII) {
        keyChars = event.characters
      }
      if let char = keyChars?.first {
        let rimeKeycode = SquirrelKeycode.osxKeycodeToRime(keycode: keyCode, keychar: char,
                                                           shift: modifiers.contains(.shift),
                                                           caps: modifiers.contains(.capsLock))
        if rimeKeycode != 0 {
          let rimeModifiers = SquirrelKeycode.osxModifiersToRime(modifiers: modifiers)
          handled = processKey(rimeKeycode, modifiers: rimeModifiers)
          rimeUpdate()
        }
      }

    default:
      break
    }

    return handled
  }

  func selectCandidate(_ index: Int) -> Bool {
    if plComposerActive {
      selectComposerCandidate(index)
      return true
    }
    let success = rimeAPI.select_candidate_on_current_page(session, index)
    if success {
      rimeUpdate()
    }
    return success
  }

  // swiftlint:disable:next identifier_name
  func page(up: Bool) -> Bool {
    var handled = false
    handled = rimeAPI.change_page(session, up)
    if handled {
      rimeUpdate()
    }
    return handled
  }

  func moveCaret(forward: Bool) -> Bool {
    let currentCaretPos = rimeAPI.get_caret_pos(session)
    guard let input = rimeAPI.get_input(session) else { return false }
    if forward {
      if currentCaretPos <= 0 {
        return false
      }
      rimeAPI.set_caret_pos(session, currentCaretPos - 1)
    } else {
      let inputStr = String(cString: input)
      if currentCaretPos >= inputStr.utf8.count {
        return false
      }
      rimeAPI.set_caret_pos(session, currentCaretPos + 1)
    }
    rimeUpdate()
    return true
  }

  override func recognizedEvents(_ sender: Any!) -> Int {
    return Int(NSEvent.EventTypeMask.Element(arrayLiteral: .keyDown, .flagsChanged).rawValue)
  }

  override func activateServer(_ sender: Any!) {
    self.client ?= sender as? IMKTextInput
    var keyboardLayout = NSApp.squirrelAppDelegate.config?.getString("keyboard_layout") ?? ""
    if keyboardLayout == "last" || keyboardLayout == "" {
      keyboardLayout = ""
    } else if keyboardLayout == "default" {
      keyboardLayout = "com.apple.keylayout.ABC"
    } else if !keyboardLayout.hasPrefix("com.apple.keylayout.") {
      keyboardLayout = "com.apple.keylayout.\(keyboardLayout)"
    }
    if keyboardLayout != "" {
      client?.overrideKeyboard(withKeyboardNamed: keyboardLayout)
    }
    // Activation delivers no flagsChanged event, and NSEvent.modifierFlags
    // only reflects this process's own event stream, so lastModifiers may
    // disagree with the actual Caps Lock state by now. Seed it from the
    // session-wide hardware state; otherwise the next Caps Lock press can
    // compare equal to the stale lastModifiers and be dropped by the
    // early-return in handle().
    if CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift) {
      lastModifiers.insert(.capsLock)
    } else {
      lastModifiers.remove(.capsLock)
    }
    preedit = ""
    if session != 0 {
      let state = rimeAPI.get_option(session, "ascii_mode")
      let label = rimeAPI.get_state_label_abbreviated(session, "ascii_mode", state, true).asString
      NSApp.squirrelAppDelegate.updateStatusIcon(asciiMode: state, schemaLabel: label)
    }
  }

  override init!(server: IMKServer!, delegate: Any!, client: Any!) {
    self.client = client as? IMKTextInput
    super.init(server: server, delegate: delegate, client: client)
    createSession()

    NotificationCenter.default.addObserver(
      forName: .init("SquirrelSetASCIIModeNotification"),
      object: nil,
      queue: nil
    ) { [weak self] notification in
      self?.handleASCIIModeToggle(notification)
    }

    NotificationCenter.default.addObserver(
      forName: .init("SquirrelReportASCIIModeNotification"),
      object: nil,
      queue: nil
    ) { [weak self] notification in
      self?.reportASCIIMode(notification)
    }
  }

  override func deactivateServer(_ sender: Any!) {
    if plComposerActive {
      self.client ?= sender as? IMKTextInput
      plCommitReason = "deactivate"
      commitComposer(addTrailingSpace: false)
      lastCommittedWasLatin = true
    }
    hidePalettes()
    commitComposition(sender)
    client = nil
  }

  override func hidePalettes() {
    NSApp.squirrelAppDelegate.panel?.hide()
    super.hidePalettes()
  }

  override func commitComposition(_ sender: Any!) {
    self.client ?= sender as? IMKTextInput
    if plComposerActive {
      commitComposer(addTrailingSpace: false)
      return
    }
    if session != 0 {
      if let input = rimeAPI.get_input(session) {
        commit(string: String(cString: input))
        rimeAPI.clear_composition(session)
      }
    }
  }

  override func menu() -> NSMenu! {
    let deploy = NSMenuItem(title: NSLocalizedString("Deploy", comment: "Menu item"), action: #selector(deploy), keyEquivalent: "`")
    deploy.target = self
    deploy.keyEquivalentModifierMask = [.control, .option]
    let sync = NSMenuItem(title: NSLocalizedString("Sync user data", comment: "Menu item"), action: #selector(syncUserData), keyEquivalent: "")
    sync.target = self
    let logDir = NSMenuItem(title: NSLocalizedString("Logs...", comment: "Menu item"), action: #selector(openLogFolder), keyEquivalent: "")
    logDir.target = self
    let setting = NSMenuItem(title: NSLocalizedString("Settings...", comment: "Menu item"), action: #selector(openRimeFolder), keyEquivalent: "")
    setting.target = self
    let wiki = NSMenuItem(title: NSLocalizedString("Rime Wiki...", comment: "Menu item"), action: #selector(openWiki), keyEquivalent: "")
    wiki.target = self
    let update = NSMenuItem(title: NSLocalizedString("Check for updates...", comment: "Menu item"), action: #selector(checkForUpdates), keyEquivalent: "")
    update.target = self

    let menu = NSMenu()
    menu.addItem(deploy)
    menu.addItem(sync)
    menu.addItem(logDir)
    menu.addItem(setting)
    menu.addItem(wiki)
    menu.addItem(update)

    return menu
  }

  @objc func deploy() {
    NSApp.squirrelAppDelegate.deploy()
  }

  @objc func syncUserData() {
    NSApp.squirrelAppDelegate.syncUserData()
  }

  @objc func openLogFolder() {
    NSApp.squirrelAppDelegate.openLogFolder()
  }

  @objc func openRimeFolder() {
    NSApp.squirrelAppDelegate.openRimeFolder()
  }

  @objc func checkForUpdates() {
    NSApp.squirrelAppDelegate.checkForUpdates()
  }

  @objc func openWiki() {
    NSApp.squirrelAppDelegate.openWiki()
  }

  private(set) var specialCommentIndices: [ReservedPropertyKey: Set<Int>] = [:]

  func handleReservedProperty(key rawKey: String, value rawValue: String, for sessionId: RimeSessionId) throws(ReservedPropertyError) {
    guard session == sessionId, session != 0, rimeAPI.find_session(session) else { return }
    guard let key = ReservedPropertyKey(rawValue: rawKey) else { throw .unknownInput(rawKey) }
    let parsed = try ReservedPropertyValue.parse(rawValue)
    switch key {
    case .commentHighlight:
      specialCommentIndices[.commentHighlight] = try parsed.indices()
    case .commentWarning:
      specialCommentIndices[.commentWarning] = try parsed.indices()
    case .refreshUI:
      rimeUpdate(clearReservedComments: false)
    }
  }

  deinit {
    if plAuxSession != 0 { _ = rimeAPI.destroy_session(plAuxSession) }
    destroySession()
  }
}

private extension SquirrelInputController {

  func onChordTimer(_: Timer) {
    var processedKeys = false
    if chordKeyCount > 0 && session != 0 {
      // Chord typing releases are synthesized after the configured timeout.
      for i in 0..<chordKeyCount {
        let handled = rimeAPI.process_key(session, Int32(chordKeyCodes[i]), Int32(chordModifiers[i] | kReleaseMask.rawValue))
        if handled {
          processedKeys = true
        }
      }
    }
    clearChord()
    if processedKeys {
      rimeUpdate()
    }
  }

  func updateChord(keycode: UInt32, modifiers: UInt32) {
    for i in 0..<chordKeyCount where chordKeyCodes[i] == keycode {
      return
    }
    if chordKeyCount >= Self.keyRollOver {
      return
    }
    chordKeyCodes[chordKeyCount] = keycode
    chordModifiers[chordKeyCount] = modifiers
    chordKeyCount += 1
    if let timer = chordTimer, timer.isValid {
      timer.invalidate()
    }
    chordDuration = 0.1
    if let duration = NSApp.squirrelAppDelegate.config?.getDouble("chord_duration"), duration > 0 {
      chordDuration = duration
    }
    chordTimer = Timer.scheduledTimer(withTimeInterval: chordDuration, repeats: false, block: onChordTimer)
  }

  func clearChord() {
    chordKeyCount = 0
    if let timer = chordTimer {
      if timer.isValid {
        timer.invalidate()
      }
      chordTimer = nil
    }
  }

  func createSession() {
    let app = client?.bundleIdentifier() ?? {
      SquirrelInputController.unknownAppCnt &+= 1
      return "UnknownApp\(SquirrelInputController.unknownAppCnt)"
    }()
    print("createSession: \(app)")
    currentApp = app
    session = rimeAPI.create_session()
    schemaId = ""

    if session != 0 {
      updateAppOptions()
    }
  }

  func updateAppOptions() {
    if currentApp == "" {
      return
    }
    if let appOptions = NSApp.squirrelAppDelegate.config?.getAppOptions(currentApp) {
      for (key, value) in appOptions {
        print("set app option: \(key) = \(value)")
        rimeAPI.set_option(session, key, value)
      }
    }
    if let reportBundleID = NSApp.squirrelAppDelegate.config?.getBool("unsafe/report_bundleid"), reportBundleID {
      currentApp.withCString { name in
        rimeAPI.set_property(session, "client_app", name)
      }
    }
  }

  func destroySession() {
    if session != 0 {
      _ = rimeAPI.destroy_session(session)
      session = 0
    }
    clearChord()
  }

  func processKey(_ rimeKeycode: UInt32, modifiers rimeModifiers: UInt32) -> Bool {
    if let panel = NSApp.squirrelAppDelegate.panel {
      if panel.linear != rimeAPI.get_option(session, "_linear") {
        rimeAPI.set_option(session, "_linear", panel.linear)
      }
      if panel.vertical != rimeAPI.get_option(session, "_vertical") {
        rimeAPI.set_option(session, "_vertical", panel.vertical)
      }
    }

    let handled = rimeAPI.process_key(session, Int32(rimeKeycode), Int32(rimeModifiers))

    if !handled {
      let isVimBackInCommandMode = rimeKeycode == XK_Escape || ((rimeModifiers & kControlMask.rawValue != 0) && (rimeKeycode == XK_c || rimeKeycode == XK_C || rimeKeycode == XK_bracketleft))
      if isVimBackInCommandMode && rimeAPI.get_option(session, "vim_mode") &&
          !rimeAPI.get_option(session, "ascii_mode") {
        rimeAPI.set_option(session, "ascii_mode", true)
      }
    } else {
      let isChordingKey = switch Int32(rimeKeycode) {
      case XK_space...XK_asciitilde, XK_Control_L, XK_Control_R, XK_Alt_L, XK_Alt_R, XK_Shift_L, XK_Shift_R:
        true
      default:
        false
      }
      if isChordingKey && rimeAPI.get_option(session, "_chord_typing") {
        updateChord(keycode: rimeKeycode, modifiers: rimeModifiers)
      } else if (rimeModifiers & kReleaseMask.rawValue) == 0 {
        clearChord()
      }
    }

    return handled
  }

  func rimeConsumeCommittedText() {
    var commitText = RimeCommit.rimeStructInit()
    if rimeAPI.get_commit(session, &commitText) {
      if let text = commitText.text {
        commit(string: String(cString: text))
      }
      _ = rimeAPI.free_commit(&commitText)
    }
  }

  // Preserve reserved comment marks when librime requests a UI-only refresh.
  func rimeUpdate(clearReservedComments: Bool = true) {
    if plComposerActive { return }
    if clearReservedComments {
      specialCommentIndices = [:]
    }
    rimeConsumeCommittedText()

    var status = RimeStatus_stdbool.rimeStructInit()
    if rimeAPI.get_status(session, &status) {
      // swiftlint:disable:next identifier_name
      if let schema_id = status.schema_id, schemaId == "" || schemaId != String(cString: schema_id) {
        schemaId = String(cString: schema_id)
        NSApp.squirrelAppDelegate.loadSettings(for: schemaId)
        if let panel = NSApp.squirrelAppDelegate.panel {
          inlinePreedit = (panel.inlinePreedit && !rimeAPI.get_option(session, "no_inline")) || rimeAPI.get_option(session, "inline")
          inlineCandidate = panel.inlineCandidate && !rimeAPI.get_option(session, "no_inline")
          rimeAPI.set_option(session, "soft_cursor", !inlinePreedit)
        }
      }
      _ = rimeAPI.free_status(&status)
    }

    var ctx = RimeContext_stdbool.rimeStructInit()
    if rimeAPI.get_context(session, &ctx) {
      let preedit = ctx.composition.preedit.map({ String(cString: $0) }) ?? ""

      let start = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.sel_start)), within: preedit) ?? preedit.startIndex
      let end = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.sel_end)), within: preedit) ?? preedit.startIndex
      let caretPos = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.cursor_pos)), within: preedit) ?? preedit.startIndex

      if inlineCandidate {
        var candidatePreview = ctx.commit_text_preview.map { String(cString: $0) } ?? ""
        let endOfCandidatePreview = candidatePreview.endIndex
        if inlinePreedit {
          // 左移光標後的情形：
          // preedit:             ^已選某些字[xiang zuo yi dong]|guangbiao$
          // commit_text_preview: ^已選某些字向左移動$
          // candidate_preview:   ^已選某些字[向左移動]|guangbiao$
          // 繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidong$
          // candidate_preview:   ^已選某些字[向左]yidong|guangbiao$
          // 光標移至當前段落最左端的情形：
          // preedit:             ^已選某些字|[xiang zuo yi dong guang biao]$
          // commit_text_preview: ^已選某些字向左移動光標$
          // candidate_preview:   ^已選某些字|[向左移動光標]$
          // 討論：
          // preedit 與 commit_text_preview 中“已選某些字”部分一致
          // 因此，選中範圍即正在翻譯的碼段“向左移動”中，兩者的 start 值一致
          // 光標位置的範圍是 start ..= endOfCandidatePreview
          if caretPos >= end && caretPos < preedit.endIndex {
            // 從 preedit 截取光標後未翻譯的編碼“guangbiao”
            candidatePreview += preedit[caretPos...]
          }
        } else {
          // 翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字[向左???]|$
          // 光標移至當前段落最左端，繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字|[xiang zuo]yidongguangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字|[向左]???$
          // FIXME: add librime APIs to support preview candidate without remaining code.
        }
        // preedit can contain additional prompt text before start:
        // ^(prompt)[selection]$
        let start = min(start, candidatePreview.endIndex)
        let caretPos = caretPos <= start ? caretPos : endOfCandidatePreview
        show(preedit: candidatePreview,
             selRange: NSRange(location: start.utf16Offset(in: candidatePreview),
                               length: candidatePreview.utf16.distance(from: start, to: candidatePreview.endIndex)),
             caretPos: caretPos.utf16Offset(in: candidatePreview))
      } else {
        if inlinePreedit {
          show(preedit: preedit, selRange: NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end)), caretPos: caretPos.utf16Offset(in: preedit))
        } else {
          // Use a full-width space placeholder to prevent iTerm2 from echoing raw preedit;
          // half-width placeholders make the Chinese composition baseline unstable.
          show(preedit: preedit.isEmpty ? "" : "　", selRange: NSRange(location: 0, length: 0), caretPos: 0)
        }
      }

      let numCandidates = Int(ctx.menu.num_candidates)
      var candidates = [String]()
      var comments = [String]()
      for i in 0..<numCandidates {
        let candidate = ctx.menu.candidates[i]
        candidates.append(candidate.text.map { String(cString: $0) } ?? "")
        comments.append(candidate.comment.map { String(cString: $0) } ?? "")
      }
      var labels = [String]()
      // swiftlint:disable identifier_name
      if let select_keys = ctx.menu.select_keys {
        labels = String(cString: select_keys).map { String($0) }
      } else if let select_labels = ctx.select_labels {
        let pageSize = Int(ctx.menu.page_size)
        for i in 0..<pageSize {
          labels.append(select_labels[i].map { String(cString: $0) } ?? "")
        }
      }
      // swiftlint:enable identifier_name
      let page = Int(ctx.menu.page_no)
      let lastPage = ctx.menu.is_last_page

      let selRange = NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end))
      showPanel(preedit: inlinePreedit ? "" : preedit, selRange: selRange, caretPos: caretPos.utf16Offset(in: preedit),
                candidates: candidates, comments: comments, labels: labels, highlighted: Int(ctx.menu.highlighted_candidate_index),
                page: page, lastPage: lastPage)
      _ = rimeAPI.free_context(&ctx)
    } else {
      hidePalettes()
    }
  }

  func commit(string: String) {
    guard let client = client else { return }

    let forceMarkedText =
      session != 0 &&
      rimeAPI.get_option(session, "force_marked_text_for_direct_commit")

    // Direct commits such as full-width punctuation do not necessarily have an
    // active marked-text phase. Some NSTextInputClient implementations require
    // one before accepting insertText.
    if forceMarkedText && preedit.isEmpty && !string.isEmpty {
      let markedText = NSMutableAttributedString(string: string)
      client.setMarkedText(
        markedText,
        selectionRange: NSRange(location: markedText.length, length: 0),
        replacementRange: .empty
      )
    }

    client.insertText(string, replacementRange: .empty)
    preedit = ""
    hidePalettes()
  }

  func show(preedit: String, selRange: NSRange, caretPos: Int) {
    guard let client = client else { return }
    if self.preedit == preedit && self.caretPos == caretPos && self.selRange == selRange {
      return
    }

    self.preedit = preedit
    self.caretPos = caretPos
    self.selRange = selRange

    let start = selRange.location
    let attrString = NSMutableAttributedString(string: preedit)
    if start > 0 {
      let attrs = mark(forStyle: kTSMHiliteConvertedText, at: NSRange(location: 0, length: start))! as! [NSAttributedString.Key: Any]
      attrString.setAttributes(attrs, range: NSRange(location: 0, length: start))
    }
    let remainingRange = NSRange(location: start, length: preedit.utf16.count - start)
    let attrs = mark(forStyle: kTSMHiliteSelectedRawText, at: remainingRange)! as! [NSAttributedString.Key: Any]
    attrString.setAttributes(attrs, range: remainingRange)
    client.setMarkedText(attrString, selectionRange: NSRange(location: caretPos, length: 0), replacementRange: .empty)
  }

  // swiftlint:disable:next function_parameter_count
  func showPanel(preedit: String, selRange: NSRange, caretPos: Int, candidates: [String], comments: [String], labels: [String], highlighted: Int, page: Int, lastPage: Bool) {
    guard let client = client else { return }
    var inputPos = NSRect()
    client.attributes(forCharacterIndex: 0, lineHeightRectangle: &inputPos)
    if let panel = NSApp.squirrelAppDelegate.panel {
      panel.position = inputPos
      panel.inputController = self
      panel.update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels,
                   highlighted: highlighted, page: page, lastPage: lastPage, update: true)
    }
  }

  private func handleASCIIModeToggle(_ notification: Notification) {
    guard let enableASCII = notification.object as? Bool else { return }
    guard session != 0 && rimeAPI.find_session(session) else { return }

    rimeAPI.set_option(session, "ascii_mode", enableASCII)
    rimeUpdate()
  }

  private func reportASCIIMode(_: Notification) {
    guard client != nil else { return }
    guard session != 0 && rimeAPI.find_session(session) else { return }

    let isASCIIMode = rimeAPI.get_option(session, "ascii_mode")
    let status = isASCIIMode ? "ascii" : "nascii"

    DistributedNotificationCenter.default().postNotificationName(
      .init("SquirrelASCIIModeResponse"),
      object: status
    )
  }

  // MARK: - Polylangin debug log (for local iteration)

  private static let plLogFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
  }()

  private func plLog(_ message: String) {
    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Polylangin", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("keylog.txt")
    let line = Self.plLogFormatter.string(from: Date()) + " " + message + "\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: url)
    }
  }

  // MARK: - Polylangin composer (v0.4: raw preedit, space confirms)

  private func isEnglishWord(_ token: String) -> Bool {
    let lower = token.lowercased()
    if lower == "a" || lower == "i" { return true }
    // NOTE: classification intentionally uses the curated word list only; the
    // common list is used by autocorrect for validity checks instead.
    return plData.isEnglishWord(lower)
  }

  private func plHandleKey(event: NSEvent, modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> Bool? {
    if modifiers.contains(.control) || modifiers.contains(.command) || modifiers.contains(.option) {
      return nil
    }

    if keyCode == 53 {  // Escape
      if plGridExpanded {
        plGridExpanded = false
        updateComposer()
        return true
      }
      if plComposerActive { clearComposer(reason: "esc"); return true }
      return nil
    }
    if keyCode == 36 {  // Return: commit the raw keys; for Latin input let the app handle Enter too
      if plComposerActive {
        let wasLatin = plComposeLastWasLatin
        commitRawComposer()
        // In chat apps this sends the message / in editors it inserts a newline.
        return wasLatin ? false : true
      }
      return nil
    }
    if keyCode == 48 {  // Tab
      return plComposeTab()
    }
    if keyCode == 51 {  // Backspace
      if plComposerActive { plComposeBackspace(); return true }
      return nil
    }
    if keyCode == 49 {  // Space = confirm (adds a space for Latin runs)
      return plComposeSpace()
    }
    if keyCode == 33, !modifiers.contains(.shift) {  // CSA circumflex dead key
      plCircumflexPending = true
      return true
    }
    if keyCode == 123 || keyCode == 124 {  // Left / Right
      if plComposerActive, plComposeCandidates.count > 1 {
        if plGridExpanded {
          // Move within the current row of the expanded grid.
          let rowStart = (plComposeHighlight / 9) * 9
          let rowEnd = min(rowStart + 8, plComposeCandidates.count - 1)
          if keyCode == 124 {
            plComposeHighlight = min(plComposeHighlight + 1, rowEnd)
          } else {
            plComposeHighlight = max(plComposeHighlight - 1, rowStart)
          }
        } else if keyCode == 124 {
          plComposeHighlight = min(plComposeHighlight + 1, plComposeCandidates.count - 1)
        } else {
          plComposeHighlight = max(plComposeHighlight - 1, 0)
        }
        updateComposer()
        return true
      }
      return nil
    }
    if keyCode == 121 {  // PageDown
      if plComposerActive {
        plComposeHighlight = min(plComposeHighlight + 9, max(plComposeCandidates.count - 1, 0))
        updateComposer()
        return true
      }
      return nil
    }
    if keyCode == 116 {  // PageUp
      if plComposerActive {
        plComposeHighlight = max(plComposeHighlight - 9, 0)
        updateComposer()
        return true
      }
      return nil
    }
    if keyCode == 125 || keyCode == 126 {  // Down expands the grid; Up/Down move between rows
      if plComposerActive {
        if !plGridExpanded {
          if keyCode == 125 {
            plGridExpanded = true
            plEpisodeGridUsed = true
            journal("grid_open", ["count": plComposeCandidates.count])
            updateComposer()
          }
        } else {
          let row = plComposeHighlight / 9
          let column = plComposeHighlight % 9
          let rows = max(1, (plComposeCandidates.count + 8) / 9)
          let newRow = max(0, min(row + (keyCode == 125 ? 1 : -1), rows - 1))
          plComposeHighlight = min(newRow * 9 + column, plComposeCandidates.count - 1)
          updateComposer()
        }
        return true
      }
      return nil
    }

    guard let chars = event.characters, let first = chars.first else { return nil }

    if plCircumflexPending, first.isASCII, first.isLetter {
      plCircumflexPending = false
      let composed = SquirrelInputController.circumflexMap[first] ?? first
      plComposeAppend(composed)
      return true
    }
    if first.isNumber {
      if plComposerActive, let value = first.wholeNumberValue, value >= 1 {
        // In the expanded grid, numbers select the column within the current row.
        let index = plGridExpanded
          ? (plComposeHighlight / 9) * 9 + value - 1
          : plComposePage * 9 + value - 1
        if index < plComposeCandidates.count {
          plComposeHighlight = index
          plCommitReason = "digit"
          updateComposer()
          commitComposer(addTrailingSpace: false)
          return true
        }
      }
      if plComposerActive { commitComposer(addTrailingSpace: false) }
      return false
    }
    if first.isLetter || !first.isASCII {
      plComposeAppend(first)
      return true
    }
    if first == "'" || first == "-" {
      plComposeAppend(first)
      return true
    }
    let hadComposition = plComposerActive
    let compositionLatin = plComposeLastWasLatin
    if hadComposition {
      plCommitReason = "punct"
      commitComposer(addTrailingSpace: false)
    }
    // Right after our own commit, the client's surrounding text may still be
    // stale; use the language of what we just committed in that case.
    let asciiPunctuation = hadComposition ? compositionLatin : shouldUseASCIIPunctuation()
    journal("punct", ["char": String(first), "ascii": asciiPunctuation])
    if asciiPunctuation {
      plLog("PUNCT ascii [\(first)]")
      plInsertDirect(String(first))
      return true
    }
    return nil
  }

  private func plInsertDirect(_ text: String) {
    guard let client = client else { return }
    if !text.isEmpty { client.insertText(text, replacementRange: .empty) }
    preedit = ""
    NSApp.squirrelAppDelegate.panel?.hide()
  }

  private func isCJK(_ ch: Character) -> Bool {
    guard let scalar = ch.unicodeScalars.first else { return false }
    return (0x4E00...0x9FFF).contains(scalar.value)
      || (0x3400...0x4DBF).contains(scalar.value)
      || (0xF900...0xFAFF).contains(scalar.value)
  }

  /// Read the text before the caret and infer the current language context.
  private func refreshLanguageContext() {
    guard let client = client else { return }
    let selection = client.selectedRange()
    let caret = selection.location == NSNotFound ? 0 : selection.location
    let length = min(600, caret)
    guard length > 0 else { lastCommittedWasLatin = true; return }
    guard let attributed = client.attributedSubstring(from: NSRange(location: caret - length, length: length)) else {
      return
    }
    let text = attributed.string
    // Use the current (last non-empty) line as context; fall back to the whole tail.
    let lines = text.split(whereSeparator: \.isNewline).map(String.init)
    let contextLine = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? text
    var latinCount = 0
    var cjkCount = 0
    for ch in contextLine {
      if isCJK(ch) { cjkCount += 1 }
      else if ch.isASCII, ch.isLetter { latinCount += 1 }
    }
    if latinCount == 0 && cjkCount == 0 {
      lastCommittedWasLatin = true
    } else {
      lastCommittedWasLatin = latinCount >= cjkCount
    }
    if lastCommittedWasLatin {
      plLatinLanguage = Self.detectLatinLanguage(contextLine)
    }
  }

  private static func detectLatinLanguage(_ text: String) -> LatinLanguage {
    if text.contains(where: { frenchDiacritics.contains($0) }) { return .french }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    if let language = recognizer.dominantLanguage {
      if language == .french { return .french }
      if language == .english { return .english }
    }
    // Fallback: count French vs English words in the line.
    var french = 0
    var english = 0
    var current = ""
    func flush() {
      defer { current = "" }
      guard current.count >= 2 else { return }
      let word = current.lowercased()
      if englishWordsForDetection.contains(word) { english += 1 }
      else if frenchWordsForDetection.contains(word) { french += 1 }
    }
    for ch in text.lowercased() {
      if ch.isLetter { current.append(ch) } else { flush() }
    }
    flush()
    if french > 0, french >= english { return .french }
    return .english
  }

  private static var englishWordsForDetection: Set<String> {
    ["the", "and", "you", "that", "was", "for", "are", "with", "his", "they", "this", "have",
     "from", "one", "had", "word", "but", "not", "what", "all", "were", "when", "your", "can",
     "said", "there", "use", "each", "which", "she", "how", "their", "will", "would", "there",
     "about", "write", "like", "so", "these", "her", "long", "make", "thing", "see", "him"]
  }

  private static var frenchWordsForDetection: Set<String> {
    ["le", "la", "les", "de", "des", "du", "un", "une", "et", "est", "je", "tu", "il", "elle",
     "nous", "vous", "ils", "elles", "mon", "ma", "mes", "ton", "ta", "tes", "son", "sa", "ses",
     "ce", "cette", "ces", "que", "qui", "dans", "pour", "avec", "sur", "pas", "ne", "plus",
     "mais", "ou", "où", "donc", "car", "si", "comme", "quand", "très", "tout", "tous", "faire",
     "être", "avoir", "je", "c'est", "qu'il", "qu'elle", "au", "aux", "en", "y", "monde"]
  }

  /// Decide whether the next punctuation mark should be ASCII or full-width.
  /// Rule: after a digit always ASCII (2.5); otherwise look at the text since the
  /// last sentence terminator and use ASCII when Latin letters dominate.
  private func shouldUseASCIIPunctuation() -> Bool {
    guard let client else { return lastCommittedWasLatin }
    let selection = client.selectedRange()
    let caret = selection.location == NSNotFound ? 0 : selection.location
    let length = min(400, caret)
    guard length > 0,
          let attributed = client.attributedSubstring(from: NSRange(location: caret - length, length: length)) else {
      return lastCommittedWasLatin
    }
    let text = attributed.string
    var lastNonSpace: Character?
    for ch in text.reversed() where !ch.isWhitespace {
      lastNonSpace = ch
      break
    }
    if let lastNonSpace, lastNonSpace.isNumber { return true }
    let terminators: Set<Character> = ["。", "！", "？", ".", "!", "?", ";", "；", "…", "\n"]
    var start = text.startIndex
    var index = text.endIndex
    while index > text.startIndex {
      index = text.index(before: index)
      if terminators.contains(text[index]) {
        start = text.index(after: index)
        break
      }
    }
    var latin = 0
    var cjk = 0
    for ch in text[start...] {
      if ch.isASCII, ch.isLetter { latin += 1 }
      else if let scalar = ch.unicodeScalars.first,
              (0x4E00...0x9FFF).contains(scalar.value) { cjk += 1 }
    }
    if latin == 0 && cjk == 0 { return lastCommittedWasLatin }
    return latin > cjk
  }

  private func autocorrectLatin(_ word: String) -> String {
    if plLatinLanguage == .french
      || word.contains(where: { Self.frenchDiacritics.contains($0) }) {
      return autocorrectFrench(word)
    }
    return autocorrectEnglish(word)
  }

  private func matchCase(_ replacement: String, original: String) -> String {
    guard let first = original.first, first.isUppercase,
          let replacementFirst = replacement.first else { return replacement }
    return replacementFirst.uppercased() + replacement.dropFirst()
  }

  /// Returns true when the token looks like an acronym / proper-noun-style word
  /// where autocorrect must never interfere.
  private func isProtectedToken(_ word: String) -> Bool {
    let letters = word.filter { $0.isLetter }
    let digits = word.filter { $0.isNumber }
    if !digits.isEmpty { return true }
    let uppercaseCount = letters.filter { $0.isUppercase }.count
    if uppercaseCount >= 2 { return true }          // KYC / ACR / OJK / NDA / PLS
    if letters.count <= 1 { return true }
    return false
  }

  private func autocorrectEnglish(_ word: String) -> String {
    let lower = word.lowercased()
    guard lower.count >= 2,
          lower.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic) }),
          !lower.contains("'"), !lower.contains("-"),
          !isProtectedToken(word) else { return word }
    // Missing-apostrophe contractions first (dont -> don't, thats -> that's).
    if let contraction = plData.contractionFix(lower) {
      let fixed = matchCase(contraction, original: word)
      plEpisodeCorrection = "\(word)->\(fixed)"
      journal("autocorrect", ["from": word, "to": fixed, "lang": "en"])
      plLog("AUTOCORRECT_EN [\(word)] -> [\(fixed)]")
      return fixed
    }
    // Never touch a word that is already valid English.
    if plData.isKnownEnglishWordOrCommon(lower) { return word }
    guard lower.count >= 3,
          let corrected = plData.spellCorrect(lower) else { return word }
    let fixed = matchCase(corrected, original: word)
    plEpisodeCorrection = "\(word)->\(fixed)"
    journal("autocorrect", ["from": word, "to": fixed, "lang": "en"])
    plLog("AUTOCORRECT_EN [\(word)] -> [\(fixed)]")
    return fixed
  }

  private func autocorrectFrench(_ word: String) -> String {
    let lower = word.lowercased()
    guard lower.count >= 3, !lower.contains("'"), !lower.contains("-"),
          !isProtectedToken(word) else { return word }
    // Never touch valid French or valid English words (pay -> pas was wrong).
    if plData.isFrenchWord(lower) || plData.isKnownEnglishWordOrCommon(lower) { return word }
    guard lower.unicodeScalars.allSatisfy({ $0.isASCII }) else { return word }
    guard let corrected = plData.frenchSpellCorrect(lower) else { return word }
    let fixed = matchCase(corrected, original: word)
    plEpisodeCorrection = "\(word)->\(fixed)"
    journal("autocorrect", ["from": word, "to": fixed, "lang": "fr"])
    plLog("AUTOCORRECT_FR [\(word)] -> [\(fixed)]")
    return fixed
  }

  private func plComposeAppend(_ char: Character) {
    plGridExpanded = false
    if plComposeBuffer.isEmpty {
      refreshLanguageContext()
      plEpisodeStart = ProcessInfo.processInfo.systemUptime
      plEpisodeKeys = 0
      plEpisodeBackspaces = 0
      plEpisodeGridUsed = false
      plEpisodeCorrection = ""
    }
    plEpisodeKeys += 1
    plComposeHighlight = 0
    plComposeBuffer.append(char)
    plLog("APPEND [\(char)] buf=[\(plComposeBuffer)]")
    updateComposer()
  }

  private func plComposeBackspace() {
    plGridExpanded = false
    if !plComposeBuffer.isEmpty { plComposeBuffer.removeLast() }
    plComposeHighlight = 0
    plEpisodeBackspaces += 1
    journal("backspace", ["buf": plComposeBuffer, "composer": true])
    plLog("BACKSPACE buf=[\(plComposeBuffer)]")
    updateComposer()
  }

  private func plComposeSpace() -> Bool? {
    if !plComposerActive { return false }
    plCommitReason = "space"
    commitComposer(addTrailingSpace: plComposeLastWasLatin)
    return true
  }

  private func plComposeTab() -> Bool? {
    if !plComposerActive { return nil }
    let now = ProcessInfo.processInfo.systemUptime
    if now - plComposeLastTab < 0.35 {
      plComposeLastTab = 0
      clearComposer(reason: "tab")
      return true
    }
    plComposeLastTab = now
    return true
  }

  private func updateComposer() {
    guard let client = client else { return }
    if !plComposerActive {
      client.setMarkedText(NSAttributedString(string: ""),
                           selectionRange: NSRange(location: 0, length: 0),
                           replacementRange: .empty)
      NSApp.squirrelAppDelegate.panel?.hide()
      return
    }
    let (candidates, comments, isLatin) = composerCandidates()
    plComposeCandidates = candidates
    plComposeComments = comments
    plComposeLastWasLatin = isLatin
    self.preedit = plComposeBuffer

    // Inline preedit always shows the raw Latin keys the user typed.
    let attributed = NSAttributedString(string: plComposeBuffer)
    client.setMarkedText(attributed,
                         selectionRange: NSRange(location: attributed.length, length: 0),
                         replacementRange: .empty)

    if plGridExpanded, !candidates.isEmpty {
      NSApp.squirrelAppDelegate.panel?.hide()
      showExpandedGrid(candidates: candidates, highlighted: plComposeHighlight)
      return
    }
    plGridPanel?.hideGrid()

    let lower = plComposeBuffer.lowercased()
    let hasFrench = lower.contains(where: { Self.frenchDiacritics.contains($0) })
    let couldBeLatin = lastCommittedWasLatin
      && (isEnglishWord(lower) || plData.isEnglishPrefix(lower)
          || plData.isFrenchWord(lower) || hasFrench)
    let showPanelForThis = !couldBeLatin && !candidates.isEmpty && (candidates.count > 1 || !isLatin)
    if showPanelForThis {
      let pageCount = max(1, (candidates.count + 8) / 9)
      let page = min(plComposeHighlight / 9, pageCount - 1)
      plComposePage = page
      let start = page * 9
      let end = min(start + 9, candidates.count)
      let pageCandidates = Array(candidates[start..<end])
      let pageComments = Array(comments[start..<end])
      let labels = (0..<pageCandidates.count).map { String($0 + 1) }
      showPanel(preedit: "", selRange: .empty, caretPos: 0,
                candidates: pageCandidates, comments: pageComments, labels: labels,
                highlighted: plComposeHighlight - start, page: page,
                lastPage: page == pageCount - 1)
    } else {
      NSApp.squirrelAppDelegate.panel?.hide()
    }
  }

  /// Candidates for the current raw buffer; isLatin tells whether space should add a space.
  private func composerCandidates() -> ([String], [String], Bool) {
    let token = plComposeBuffer
    guard !token.isEmpty else { return ([], [], false) }
    return convertComposerToken(token, preferLatin: lastCommittedWasLatin)
  }

  private func convertComposerToken(_ token: String, preferLatin: Bool) -> ([String], [String], Bool) {
    let lower = token.lowercased()
    let normalized = lower.replacingOccurrences(of: "'", with: "-")
      .replacingOccurrences(of: "‑", with: "-")
      .replacingOccurrences(of: "-", with: "")
    let isASCII = token.unicodeScalars.allSatisfy { $0.isASCII }
    guard isASCII else {
      return ([token], [""], true)
    }
    let bare = !token.contains("'") && !token.contains("-")
    let frenchWord = plData.isFrenchWord(normalized)
    let hasFrenchDiacritics = token.contains(where: { Self.frenchDiacritics.contains($0) })
    if plLatinLanguage == .french, frenchWord || hasFrenchDiacritics {
      plLatinLanguage = .french
      return ([token], [""], true)
    }
    let pinyinFull = bare && plData.canSegmentFull(normalized)
    let pinyinOK = bare
      && (pinyinFull || plData.canSegmentPrefix(normalized))
    let englishWord = isEnglishWord(normalized)
    let englishPrefix = plData.isEnglishPrefix(normalized)
    plLog("CLASSIFY [\(token)] preferLatin=\(preferLatin) pinyinOK=\(pinyinOK) full=\(pinyinFull) word=\(englishWord) prefix=\(englishPrefix)")

    let startsUppercase = token.first?.isUppercase ?? false
    if startsUppercase, englishWord || englishPrefix {
      return englishCandidates(token: token, normalized: normalized, pinyinOK: pinyinOK)
    }
    if englishWord {
      if preferLatin || !pinyinOK {
        return englishCandidates(token: token, normalized: normalized, pinyinOK: pinyinOK)
      }
      // Chinese context: prefer the Chinese reading of an ambiguous word.
      let (_, candidates, comments) = auxConvert(normalized)
      if candidates.isEmpty { return ([token], [""], true) }
      return (candidates, comments, false)
    }
    // Complete pinyin that is not an English word: Chinese even in English context
    // (le / de / shi / hao ...). This is what makes "amazing work le" possible.
    if pinyinFull {
      let (_, candidates, comments) = auxConvert(normalized)
      if candidates.isEmpty { return ([token], [""], false) }
      return (candidates, comments, false)
    }
    if preferLatin, englishPrefix {
      // Looks like an English word being typed: don't show Chinese candidates yet.
      return ([token], [""], true)
    }
    // English typo in English context: keep it Latin, correction happens on commit.
    if preferLatin, plLatinLanguage == .english, !pinyinFull,
       plData.spellCorrect(normalized) != nil {
      return ([token], [""], true)
    }
    // Pinyin typo with swapped adjacent letters (zhognwen -> zhongwen).
    if let fixed = plData.pinyinTypoCorrect(normalized) {
      plLog("PINYIN_FIX [\(token)] -> [\(fixed)]")
      let (_, candidates, comments) = auxConvert(fixed)
      if !candidates.isEmpty { return (candidates, comments, false) }
    }
    if let (prefix, suffix) = plData.bestSplit(normalized), suffix.count >= 2 {
      let (top, _, _) = auxConvert(prefix)
      let converted = (top ?? prefix) + suffix
      return ([converted], [""], false)
    }
    if pinyinOK {
      let (_, candidates, comments) = auxConvert(normalized)
      if candidates.isEmpty { return ([token], [""], false) }
      return (candidates, comments, false)
    }
    return ([token], [""], true)
  }

  private func englishCandidates(token: String, normalized: String, pinyinOK: Bool) -> ([String], [String], Bool) {
    guard pinyinOK else {
      return ([token], [""], true)
    }
    // Ambiguous word: English first, Chinese alternatives after it.
    let (_, chinese, comments) = auxConvert(normalized)
    var merged = [token]
    merged.append(contentsOf: chinese)
    var mergedComments = [""]
    mergedComments.append(contentsOf: comments)
    let limit = min(merged.count, 27)
    return (Array(merged.prefix(limit)), Array(mergedComments.prefix(limit)), true)
  }

  /// Query the Rime engine (auxiliary session) for candidates of a Latin/pinyin run.
  private func auxConvert(_ token: String) -> (String?, [String], [String]) {
    guard !token.isEmpty else { return (nil, [], []) }
    if plAuxSession == 0 {
      plAuxSession = rimeAPI.create_session()
    }
    guard plAuxSession != 0 else { return (nil, [], []) }
    rimeAPI.clear_composition(plAuxSession)
    for ch in token.lowercased() {
      guard ch.isASCII, let ascii = ch.asciiValue else { continue }
      _ = rimeAPI.process_key(plAuxSession, Int32(ascii), 0)
    }
    var top: String?
    var candidates: [String] = []
    var comments: [String] = []
    var page = 0
    while page < 6 {
      var ctx = RimeContext_stdbool.rimeStructInit()
      guard rimeAPI.get_context(plAuxSession, &ctx) else { break }
      let count = Int(ctx.menu.num_candidates)
      if page == 0 {
        let rimePageSize = Int(ctx.menu.page_size)
        if rimePageSize > 0 { plComposePageSize = rimePageSize }
      }
      for i in 0..<count {
        let candidate = ctx.menu.candidates[i]
        let text = candidate.text.map { String(cString: $0) } ?? ""
        if top == nil, page == 0, i == 0 { top = text }
        candidates.append(text)
        comments.append(candidate.comment.map { String(cString: $0) } ?? "")
      }
      let lastPage = ctx.menu.is_last_page
      _ = rimeAPI.free_context(&ctx)
      if lastPage || candidates.count >= 27 { break }
      if !rimeAPI.change_page(plAuxSession, false) { break }
      page += 1
    }
    rimeAPI.clear_composition(plAuxSession)
    let limit = min(candidates.count, 27)
    return (top, Array(candidates.prefix(limit)), Array(comments.prefix(limit)))
  }

  private func caretRect() -> NSRect {
    var rect = NSRect()
    client?.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
    return rect
  }

  private func showExpandedGrid(candidates: [String], highlighted: Int) {
    if plGridPanel == nil {
      let panel = PolylanginGridPanel()
      panel.onSelect = { [weak self] index in
        guard let self else { return }
        guard index >= 0, index < self.plComposeCandidates.count else { return }
        self.plComposeHighlight = index
        self.plGridExpanded = false
        self.plCommitReason = "click"
        self.updateComposer()
        self.commitComposer(addTrailingSpace: false)
      }
      plGridPanel = panel
    }
    plGridPanel?.update(candidates: candidates, highlighted: highlighted)
    plGridPanel?.show(near: caretRect())
  }

  /// True when the composition can be handed to Rime for multi-step selection
  /// (pure pinyin; mixed pinyin+Latin tokens are committed whole).
  private func isPurePinyinBuffer() -> Bool {
    let lower = plComposeBuffer.lowercased()
    guard !lower.isEmpty,
          lower.unicodeScalars.allSatisfy({ $0.isASCII && $0.properties.isAlphabetic }) else {
      return false
    }
    return plData.canSegmentPrefix(lower) || plData.canSegmentFull(lower)
  }

  /// Ask Rime to select a candidate and report how much pinyin is left.
  /// Returns nil when the selection failed.
  private func rimeSelectRemaining(buffer: String, page: Int, index: Int) -> String? {
    if plAuxSession == 0 {
      plAuxSession = rimeAPI.create_session()
    }
    guard plAuxSession != 0 else { return nil }
    rimeAPI.clear_composition(plAuxSession)
    for ch in buffer.lowercased() {
      guard ch.isASCII, let ascii = ch.asciiValue else { continue }
      _ = rimeAPI.process_key(plAuxSession, Int32(ascii), 0)
    }
    for _ in 0..<max(0, page) {
      if !rimeAPI.change_page(plAuxSession, false) { break }
    }
    guard rimeAPI.select_candidate_on_current_page(plAuxSession, index) else {
      rimeAPI.clear_composition(plAuxSession)
      return nil
    }
    // Rime keeps the original input in get_input(); the remaining raw pinyin is
    // the tail of the preedit starting at the current selection range.
    var remaining = ""
    var ctx = RimeContext_stdbool.rimeStructInit()
    if rimeAPI.get_context(plAuxSession, &ctx) {
      if let preeditPointer = ctx.composition.preedit {
        let preedit = String(cString: preeditPointer)
        let selStart = Int(ctx.composition.sel_start)
        let bytes = Array(preedit.utf8)
        if selStart >= 0, selStart <= bytes.count {
          let tail = String(decoding: bytes[selStart...], as: UTF8.self)
          remaining = tail.replacingOccurrences(of: " ", with: "")
        }
      }
      _ = rimeAPI.free_context(&ctx)
    }
    rimeAPI.clear_composition(plAuxSession)
    return remaining
  }

  /// Commit only the highlighted candidate's part of the buffer, keeping the
  /// rest in the composition so the user can keep choosing (woshizhende|niubi).
  private func tryPartialSelectionCommit() -> Bool {
    guard plComposerActive, !plComposeLastWasLatin, !plComposeCandidates.isEmpty,
          ["space", "digit", "click"].contains(plCommitReason),
          isPurePinyinBuffer() else { return false }
    let index = min(plComposeHighlight, plComposeCandidates.count - 1)
    let pageSize = max(1, plComposePageSize)
    let page = index / pageSize
    let local = index % pageSize
    guard let remaining = rimeSelectRemaining(buffer: plComposeBuffer, page: page, index: local),
          !remaining.isEmpty,
          plComposeBuffer.lowercased().hasSuffix(remaining.lowercased()) else { return false }
    guard let client = client else { return false }
    let selected = plComposeCandidates[index]
    let oldRaw = plComposeBuffer
    client.insertText(selected, replacementRange: .empty)
    journal("commit_partial", ["text": selected, "raw": oldRaw, "remaining": remaining,
                               "index": index, "page": page, "local": local])
    plEpisodeStart = ProcessInfo.processInfo.systemUptime
    plEpisodeKeys = 0
    plEpisodeBackspaces = 0
    plEpisodeGridUsed = false
    plEpisodeCorrection = ""
    plComposeBuffer = remaining
    plComposeHighlight = 0
    plComposeLastWasLatin = false
    updateComposer()
    return true
  }

  private func selectComposerCandidate(_ index: Int) {
    let absolute = plComposePage * 9 + index
    guard plComposerActive, absolute >= 0, absolute < plComposeCandidates.count else { return }
    plComposeHighlight = absolute
    plCommitReason = "click"
    updateComposer()
    commitComposer(addTrailingSpace: false)
  }

  private func commitComposer(addTrailingSpace: Bool) {
    if tryPartialSelectionCommit() { return }
    guard let client = client else { clearComposerState(); return }
    var text = plComposeBuffer
    if plComposerActive, !plComposeCandidates.isEmpty {
      let index = min(plComposeHighlight, plComposeCandidates.count - 1)
      text = plComposeCandidates[index]
      if index == 0, text == plComposeBuffer, plComposeLastWasLatin {
        text = autocorrectLatin(text)
      }
    }
    if addTrailingSpace, !text.hasSuffix(" ") {
      text += " "
    }
    plLog("COMMIT [\(text)] trailingSpace=\(addTrailingSpace) latinCtx=\(plComposeLastWasLatin)")
    let elapsed = Int((ProcessInfo.processInfo.systemUptime - plEpisodeStart) * 1000)
    let lang = plComposeLastWasLatin ? (plLatinLanguage == .french ? "fr" : "en") : "zh"
    journal("commit", ["text": text, "raw": plComposeBuffer, "reason": plCommitReason,
                       "lang": lang, "keys": plEpisodeKeys, "backspaces": plEpisodeBackspaces,
                       "ms": elapsed, "grid": plEpisodeGridUsed, "rank": plComposeHighlight,
                       "correction": plEpisodeCorrection])
    plEpisodeCorrection = ""
    if !text.isEmpty {
      client.insertText(text, replacementRange: .empty)
    }
    lastCommittedWasLatin = addTrailingSpace || plComposeLastWasLatin
    plGridExpanded = false
    plGridPanel?.hideGrid()
    clearComposerState()
    preedit = ""
    NSApp.squirrelAppDelegate.panel?.hide()
  }

  /// Enter: commit exactly what the user typed (raw Latin keys), like Rime's raw-input commit.
  private func commitRawComposer() {
    guard let client = client else { clearComposerState(); return }
    let text = plComposeBuffer
    plLog("COMMIT_RAW [\(text)]")
    let elapsed = Int((ProcessInfo.processInfo.systemUptime - plEpisodeStart) * 1000)
    journal("raw_commit", ["text": text, "keys": plEpisodeKeys, "ms": elapsed,
                           "backspaces": plEpisodeBackspaces])
    if !text.isEmpty {
      client.insertText(text, replacementRange: .empty)
    }
    lastCommittedWasLatin = plComposeLastWasLatin
    plGridExpanded = false
    plGridPanel?.hideGrid()
    clearComposerState()
    preedit = ""
    NSApp.squirrelAppDelegate.panel?.hide()
  }

  private func clearComposer(reason: String = "clear") {
    plLog("CLEAR buf=[\(plComposeBuffer)]")
    if plComposerActive {
      let elapsed = Int((ProcessInfo.processInfo.systemUptime - plEpisodeStart) * 1000)
      journal("abandon", ["buf": plComposeBuffer, "reason": reason, "keys": plEpisodeKeys,
                          "backspaces": plEpisodeBackspaces, "ms": elapsed])
    }
    plGridExpanded = false
    plGridPanel?.hideGrid()
    if let client = client {
      client.setMarkedText(NSAttributedString(string: ""),
                           selectionRange: NSRange(location: 0, length: 0),
                           replacementRange: .empty)
    }
    clearComposerState()
    preedit = ""
    NSApp.squirrelAppDelegate.panel?.hide()
  }

  private func clearComposerState() {
    plComposeBuffer = ""
    plComposeCandidates = []
    plComposeComments = []
    plComposeHighlight = 0
    plCircumflexPending = false
  }

  // MARK: - Polylangin helpers

  /// Insert text into the focused client directly.
  private func plInsert(_ text: String) {
    guard !text.isEmpty else { return }
    commit(string: text)
  }

  /// Clear the current Rime composition without committing anything.
  private func clearComposition() {
    rimeAPI.clear_composition(session)
    rimeUpdate()
  }

  private func resetPlState() {
    plRaw = ""
    plLower = ""
    plLatin = false
  }

  private func rimeIsComposing() -> Bool {
    var status = RimeStatus_stdbool.rimeStructInit()
    defer { _ = rimeAPI.free_status(&status) }
    if rimeAPI.get_status(session, &status) {
      return status.is_composing
    }
    return false
  }

  /// Convert a complete pinyin string to Chinese using an auxiliary Rime session.
  private func convertPinyin(_ pinyin: String) -> String {
    guard !pinyin.isEmpty else { return "" }
    let aux = rimeAPI.create_session()
    guard aux != 0 else { return pinyin }
    defer { _ = rimeAPI.destroy_session(aux) }
    for ch in pinyin {
      guard let ascii = ch.asciiValue else { continue }
      _ = rimeAPI.process_key(aux, Int32(ascii), 0)
    }
    var ctx = RimeContext_stdbool.rimeStructInit()
    var converted = pinyin
    if rimeAPI.get_context(aux, &ctx) {
      if ctx.menu.num_candidates > 0, let text = ctx.menu.candidates[0].text {
        converted = String(cString: text)
      }
      _ = rimeAPI.free_context(&ctx)
    }
    return converted
  }

  private func commitRawLatin(_ raw: String) {
    clearComposition()
    plInsert(raw)
    plLatin = true
    plRaw = raw
    plLower = raw.lowercased()
  }

  private func plAfterLetter(_ char: Character) {
    guard !plLatin else { return }
    let lower = String(char).lowercased()
    guard let scalar = lower.unicodeScalars.first, scalar.isASCII,
          CharacterSet.lowercaseLetters.contains(scalar) else { return }
    plRaw.append(char)
    plLower.append(lower)

    if plData.canSegmentPrefix(plLower) {
      return
    }

    // Not a valid pinyin prefix: Latin run, possibly after a pinyin prefix.
    if plData.isEnglishPrefix(plLower) || plData.isEnglishWord(plLower) {
      commitRawLatin(plRaw)
      return
    }
    if let (prefix, suffix) = plData.bestSplit(plLower) {
      let converted = convertPinyin(prefix)
      clearComposition()
      plInsert(converted + suffix)
      plLatin = true
      plRaw = suffix
      plLower = suffix
      return
    }
    commitRawLatin(plRaw)
  }

  private func handleNonASCII(_ chars: String) -> Bool {
    if plCircumflexPending {
      plCircumflexPending = false
      plInsert("^" + chars)
      resetPlState()
      return true
    }
    if !plLatin, !plRaw.isEmpty {
      // Finish the current run as literal Latin, then append the layout char.
      let raw = plRaw
      clearComposition()
      plInsert(raw + chars)
      plLatin = true
      plRaw = raw + chars
      plLower = plRaw.lowercased()
      return true
    }
    if plLatin {
      plInsert(chars)
      plRaw += chars
      plLower = plRaw.lowercased()
      return true
    }
    // Idle: let the client app handle the layout character natively.
    return false
  }

  private func appendLatin(_ chars: String) -> Bool {
    plInsert(chars)
    plRaw += chars
    plLower = plRaw.lowercased()
    return true
  }

  private func handleTab() -> Bool {
    if !rimeIsComposing(), plRaw.isEmpty {
      return false  // let the client app handle a plain Tab (e.g. terminal completion)
    }
    let now = ProcessInfo.processInfo.systemUptime
    if now - plLastTab < 0.35 {
      plLastTab = 0
      clearComposition()
      resetPlState()
      return true
    }
    plLastTab = now
    return true
  }

}
