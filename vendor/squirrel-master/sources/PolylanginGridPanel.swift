//
//  PolylanginGridPanel.swift
//  Polylangin
//
//  Apple-style expanded candidate list: pressing ↓ opens all candidates in a
//  multi-row grid instead of paging through them one row at a time.
//

import AppKit

final class PolylanginGridPanel: NSPanel {
  static let columns = 9
  static let font = NSFont.systemFont(ofSize: 14)

  var onSelect: ((Int) -> Void)?

  private let backdrop = NSVisualEffectView()
  private let rowStack = NSStackView()
  private var buttons: [NSButton] = []
  private var buttonTexts: [String] = []
  private var candidates: [String] = []
  private var highlighted = 0

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    collectionBehavior = [.canJoinAllSpaces, .transient]
    backdrop.material = .popover
    backdrop.blendingMode = .behindWindow
    backdrop.state = .active
    backdrop.wantsLayer = true
    backdrop.layer?.cornerRadius = 10
    backdrop.layer?.masksToBounds = true
    rowStack.orientation = .vertical
    rowStack.alignment = .leading
    rowStack.spacing = 4
    rowStack.translatesAutoresizingMaskIntoConstraints = false
    backdrop.addSubview(rowStack)
    NSLayoutConstraint.activate([
      rowStack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 10),
      rowStack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -10),
      rowStack.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 8),
      rowStack.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -8),
    ])
    contentView = backdrop
  }

  func update(candidates: [String], highlighted: Int) {
    self.highlighted = highlighted
    if candidates != self.candidates {
      self.candidates = candidates
      rebuild()
    }
    refreshHighlight()
  }

  private func rebuild() {
    for view in rowStack.arrangedSubviews {
      rowStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    buttons = []
    buttonTexts = []

    let texts = candidates.enumerated().map { index, candidate in
      "\(index % Self.columns + 1)  \(candidate)"
    }
    var maxWidth: CGFloat = 40
    for text in texts {
      let size = (text as NSString).size(withAttributes: [.font: Self.font])
      maxWidth = max(maxWidth, size.width)
    }
    maxWidth = min(maxWidth, 150)

    var currentRow: NSStackView?
    for (index, text) in texts.enumerated() {
      if index % Self.columns == 0 {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        rowStack.addArrangedSubview(row)
        currentRow = row
      }
      let button = NSButton(title: text, target: self, action: #selector(buttonClicked(_:)))
      button.tag = index
      button.isBordered = false
      button.wantsLayer = true
      button.layer?.cornerRadius = 5
      button.widthAnchor.constraint(equalToConstant: maxWidth + 18).isActive = true
      button.heightAnchor.constraint(equalToConstant: 24).isActive = true
      currentRow?.addArrangedSubview(button)
      buttons.append(button)
      buttonTexts.append(text)
    }
  }

  private func refreshHighlight() {
    for (index, button) in buttons.enumerated() {
      let color: NSColor = index == highlighted ? .white : .labelColor
      button.attributedTitle = NSAttributedString(
        string: buttonTexts[index],
        attributes: [.font: Self.font, .foregroundColor: color]
      )
      button.layer?.backgroundColor = index == highlighted
        ? NSColor.controlAccentColor.cgColor
        : NSColor.clear.cgColor
    }
  }

  @objc private func buttonClicked(_ sender: NSButton) {
    let index = sender.tag
    guard index >= 0, index < candidates.count else { return }
    onSelect?(index)
  }

  func show(near caret: NSRect) {
    layoutIfNeeded()
    rowStack.layoutSubtreeIfNeeded()
    let fitting = rowStack.fittingSize
    let size = NSSize(width: max(fitting.width + 20, 140), height: fitting.height + 16)
    let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: caret.midX, y: caret.midY)) })
      ?? NSScreen.main
    guard let screen else { return }
    var origin = NSPoint(x: caret.minX, y: caret.minY - size.height - 6)
    if origin.y < screen.visibleFrame.minY + 6 {
      origin.y = caret.maxY + 6
    }
    if origin.x + size.width > screen.visibleFrame.maxX - 6 {
      origin.x = max(screen.visibleFrame.minX + 6, screen.visibleFrame.maxX - size.width - 6)
    }
    setFrame(NSRect(origin: origin, size: size), display: true)
    orderFront(nil)
  }

  func hideGrid() {
    orderOut(nil)
  }
}
