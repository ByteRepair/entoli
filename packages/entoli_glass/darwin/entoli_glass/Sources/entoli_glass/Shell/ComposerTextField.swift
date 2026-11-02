import SwiftUI

#if os(iOS)
  import UIKit
  typealias PlatformFont = UIFont
  typealias PlatformColor = UIColor
  typealias PlatformImage = UIImage
#else
  import AppKit
  typealias PlatformFont = NSFont
  typealias PlatformColor = NSColor
  typealias PlatformImage = NSImage
#endif

/// Where an embed's character is in the field: the attachment character
/// TextKit draws a card for, carrying the code Dart knows it by. Dart's text
/// holds that code in its place, one UTF-16 unit for one, so offsets on
/// either side are the same numbers.
private let embedKey = NSAttributedString.Key("entoliEmbed")
private let attachmentUnit: UInt16 = 0xFFFC

/// The text as Dart reads it out of what the field holds: each card's
/// attachment character back to its code.
private func dartText(of storage: NSAttributedString) -> String {
  var units = Array(storage.string.utf16)
  for (i, unit) in units.enumerated() where unit == attachmentUnit {
    if let code = storage.attribute(embedKey, at: i, effectiveRange: nil) as? NSNumber {
      units[i] = code.uint16Value
    }
  }
  return String(utf16CodeUnits: units, count: units.count)
}

/// How the field's text is set, as the mode asks: the body face for a
/// message, the system's monospaced one for a command.
private func fieldFont(_ mode: ComposerMode) -> PlatformFont {
  #if os(iOS)
    let size = PlatformFont.preferredFont(forTextStyle: .body).pointSize
  #else
    let size = PlatformFont.systemFontSize + 1
  #endif
  return mode == .shell
    ? .monospacedSystemFont(ofSize: size, weight: .regular)
    : .systemFont(ofSize: size)
}

private func fieldAttributes(_ mode: ComposerMode) -> [NSAttributedString.Key: Any] {
  #if os(iOS)
    [.font: fieldFont(mode), .foregroundColor: PlatformColor.label]
  #else
    [.font: fieldFont(mode), .foregroundColor: PlatformColor.labelColor]
  #endif
}

/// A card as the field draws it, rendered once to an image: TextKit lays an
/// image out as one character, so the caret steps over it and Backspace takes
/// it, as it does a letter.
private struct CardFace: View {
  var card: ComposerCard
  var width: CGFloat
  var accent: Color

  /// How far in from the card's trailing edge a click is on its cross: the
  /// symbol and the padding around it, with room for a finger's error.
  static let crossWidth: CGFloat = 36

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Capsule().fill(accent).frame(width: 3)
      VStack(alignment: .leading, spacing: 2) {
        if let title = card.title {
          Text(title).font(.caption.weight(.semibold)).foregroundStyle(accent)
        }
        Text(card.body).font(.callout).foregroundStyle(.secondary).lineLimit(3)
      }
      Spacer(minLength: 8)
      Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
    }
    .padding(8)
    .frame(width: width, alignment: .leading)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

@MainActor
private func cardImage(
  _ card: ComposerCard, width: CGFloat, accent: Color, dark: Bool, scale: CGFloat
) -> PlatformImage? {
  let renderer = ImageRenderer(
    content: CardFace(card: card, width: max(width, 120), accent: accent)
      .environment(\.colorScheme, dark ? .dark : .light))
  renderer.scale = scale
  #if os(iOS)
    return renderer.uiImage
  #else
    return renderer.nsImage
  #endif
}

/// Dart's text as the field draws it: typed runs in the mode's face, each
/// embed's code as a card.
@MainActor
private func displayed(_ text: String, model: ComposerModel, width: CGFloat, scale: CGFloat)
  -> NSAttributedString
{
  let attributes = fieldAttributes(model.mode)
  let out = NSMutableAttributedString()
  var run: [UInt16] = []
  func flush() {
    guard !run.isEmpty else { return }
    out.append(
      NSAttributedString(
        string: String(utf16CodeUnits: run, count: run.count), attributes: attributes))
    run.removeAll()
  }
  for unit in text.utf16 {
    guard let card = model.cards[unit] else {
      run.append(unit)
      continue
    }
    flush()
    let attachment = NSTextAttachment()
    if let image = cardImage(
      card, width: width, accent: model.accent, dark: model.dark, scale: scale)
    {
      attachment.image = image
      attachment.bounds = CGRect(origin: .zero, size: image.size)
    }
    let piece = NSMutableAttributedString(attachment: attachment)
    piece.addAttributes(attributes, range: NSRange(location: 0, length: piece.length))
    piece.addAttribute(
      embedKey, value: NSNumber(value: unit), range: NSRange(location: 0, length: piece.length))
    out.append(piece)
  }
  flush()
  return out
}

/// A selection Dart sent, held to [length]: what the field holds may be
/// behind it by an input method's marked text.
private func clamped(start: Int, end: Int, length: Int) -> NSRange {
  let from = min(max(start, 0), length)
  return NSRange(location: from, length: min(max(end, from), length) - from)
}

/// The embed code a card at [index] of [storage] stands for, if it is one.
private func embedCode(in storage: NSAttributedString, at index: Int) -> UInt16? {
  guard index >= 0, index < storage.length else { return nil }
  return (storage.attribute(embedKey, at: index, effectiveRange: nil) as? NSNumber)?.uint16Value
}

#if os(iOS)

  /// The field: a `UITextView`, the system's own editing, keyboard, IME,
  /// dictation, selection and context menu.
  struct ComposerTextField: UIViewRepresentable {
    static let inset: CGFloat = 6

    @ObservedObject var model: ComposerModel

    func makeUIView(context: Context) -> FieldView {
      let view = FieldView(usingTextLayoutManager: false)
      view.model = model
      view.delegate = view
      view.backgroundColor = .clear
      view.textContainerInset = UIEdgeInsets(
        top: Self.inset, left: 0, bottom: Self.inset, right: 0)
      view.textContainer.lineFragmentPadding = 0
      view.typingAttributes = fieldAttributes(model.mode)
      view.adjustsFontForContentSizeCategory = true
      view.isScrollEnabled = false
      view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      model.editor = view
      return view
    }

    func updateUIView(_ view: FieldView, context: Context) {
      view.model = model
      view.measure()
    }

    /// The width offered, and the height measured: an empty text view with
    /// no scrolling would otherwise answer the width of its text, nothing,
    /// and be laid out too narrow to tap.
    func sizeThatFits(
      _ proposal: ProposedViewSize, uiView: FieldView, context: Context
    ) -> CGSize? {
      CGSize(width: proposal.width ?? uiView.bounds.width, height: model.fieldHeight)
    }
  }

  final class FieldView: UITextView, UITextViewDelegate, ComposerEditor {
    weak var model: ComposerModel?

    /// Set while a value from Dart is being put in, so the change is not
    /// reported back as the user's.
    private var applying = false
    private var laidOutWidth: CGFloat = 0

    func apply(text: String, start: Int, end: Int) {
      guard let model, markedTextRange == nil else { return }
      applying = true
      defer { applying = false }
      attributedText = displayed(text, model: model, width: cardWidth, scale: traitCollection.displayScale)
      typingAttributes = fieldAttributes(model.mode)
      let length = attributedText.length
      selectedRange = clamped(start: start, end: end, length: length)
      model.shown(text: text)
      measure()
    }

    func focus() {
      becomeFirstResponder()
    }

    func restyle() {
      guard model != nil else { return }
      let range = selectedRange
      let text = dartText(of: attributedText)
      apply(text: text, start: range.location, end: range.location + range.length)
    }

    private var cardWidth: CGFloat { max(bounds.width - 4, 0) }

    override func layoutSubviews() {
      super.layoutSubviews()
      if bounds.width != laidOutWidth {
        laidOutWidth = bounds.width
        if model?.cards.isEmpty == false { restyle() } else { measure() }
      }
    }

    /// Tell the model the field's height, held to its lines: past them it
    /// scrolls.
    func measure() {
      guard let model, bounds.width > 0 else { return }
      let fit = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
      let line = fieldFont(model.mode).lineHeight
      let cap = line * CGFloat(model.maxLines) + textContainerInset.top + textContainerInset.bottom
      let height = min(fit, cap)
      isScrollEnabled = fit > cap
      model.measured(height: height)
    }

    private func report() {
      guard !applying, let model else { return }
      let range = selectedRange
      model.edited(
        text: dartText(of: attributedText), start: range.location,
        end: range.location + range.length)
    }

    func textViewDidChange(_ textView: UITextView) {
      report()
      measure()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
      report()
    }

    /// A tap on a card takes it out, which the card's own cross says it does.
    func textView(
      _ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction
    ) -> UIAction? {
      guard case .textAttachment = textItem.content,
        let code = embedCode(in: attributedText, at: textItem.range.location)
      else { return defaultAction }
      return UIAction { [weak self] _ in
        self?.model?.say("unembed", ["code": Int(code)])
      }
    }

    // MARK: Keys

    override var keyCommands: [UIKeyCommand]? {
      var commands = [
        UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(sendKey)),
        UIKeyCommand(input: "\r", modifierFlags: .alternate, action: #selector(queueKey)),
      ]
      if model?.menu.isEmpty == false {
        commands += [
          UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(upKey)),
          UIKeyCommand(
            input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(downKey)),
          UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(pickKey)),
          UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(pickKey)),
          UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(dismissKey)),
        ]
      } else {
        // Tab indents rather than leaving the field; Shift+Tab still leaves.
        commands.append(UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(indentKey)))
      }
      for command in commands { command.wantsPriorityOverSystemBehavior = true }
      return commands
    }

    @objc private func sendKey() { model?.say("send") }
    @objc private func queueKey() { model?.say("queue") }
    @objc private func upKey() { model?.move(-1) }
    @objc private func downKey() { model?.move(1) }
    @objc private func pickKey() { model?.pickHighlighted() }
    @objc private func dismissKey() { model?.say("dismiss") }
    @objc private func indentKey() { insertText("  ") }

    // MARK: Paste

    /// Files and images on the clipboard are attachments, which Dart takes;
    /// text is the field's own paste.
    override func paste(_ sender: Any?) {
      let board = UIPasteboard.general
      guard board.hasImages && !board.hasStrings, let model else {
        super.paste(sender)
        return
      }
      model.paste { [weak self] took in
        if !took { self?.pasteText(sender) }
      }
    }

    private func pasteText(_ sender: Any?) {
      super.paste(sender)
    }
  }

#else

  /// The field: an `NSTextView`, the system's own editing, input methods,
  /// spelling, services and context menu.
  struct ComposerTextField: NSViewRepresentable {
    static let inset: CGFloat = 4

    @ObservedObject var model: ComposerModel

    func makeNSView(context: Context) -> NSScrollView {
      let field = FieldView(usingTextLayoutManager: false)
      field.model = model
      field.delegate = field
      field.drawsBackground = false
      field.isRichText = true
      field.importsGraphics = false
      field.allowsUndo = true
      field.focusRingType = .none
      field.isVerticallyResizable = true
      field.isHorizontallyResizable = false
      field.autoresizingMask = [.width]
      field.textContainerInset = NSSize(width: 0, height: Self.inset)
      field.textContainer?.lineFragmentPadding = 0
      field.textContainer?.widthTracksTextView = true
      field.typingAttributes = fieldAttributes(model.mode)
      field.isAutomaticQuoteSubstitutionEnabled = false
      field.isAutomaticDashSubstitutionEnabled = false
      let scroll = NSScrollView()
      scroll.drawsBackground = false
      scroll.borderType = .noBorder
      scroll.hasVerticalScroller = false
      scroll.autohidesScrollers = true
      scroll.documentView = field
      model.editor = field
      return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
      (scroll.documentView as? FieldView)?.model = model
      (scroll.documentView as? FieldView)?.measure()
    }
  }

  final class FieldView: NSTextView, NSTextViewDelegate, ComposerEditor {
    weak var model: ComposerModel?

    /// Set while a value from Dart is being put in, so the change is not
    /// reported back as the user's.
    private var applying = false
    private var laidOutWidth: CGFloat = 0

    func apply(text: String, start: Int, end: Int) {
      guard let model, let storage = textStorage, !hasMarkedText() else { return }
      applying = true
      defer { applying = false }
      storage.setAttributedString(
        displayed(
          text, model: model, width: cardWidth,
          scale: window?.backingScaleFactor ?? 2))
      typingAttributes = fieldAttributes(model.mode)
      let length = storage.length
      setSelectedRange(clamped(start: start, end: end, length: length))
      model.shown(text: text)
      measure()
    }

    func focus() {
      window?.makeFirstResponder(self)
    }

    func restyle() {
      guard model != nil, let storage = textStorage else { return }
      let range = selectedRange()
      apply(
        text: dartText(of: storage), start: range.location, end: range.location + range.length)
    }

    private var cardWidth: CGFloat { max(bounds.width - 4, 0) }

    /// A width change re-lays the text — a line that wrapped beside the voice
    /// button fits once it is gone — so the height is asked again, and the
    /// cards are drawn again at the new width.
    override func setFrameSize(_ newSize: NSSize) {
      super.setFrameSize(newSize)
      if newSize.width != laidOutWidth {
        laidOutWidth = newSize.width
        if model?.cards.isEmpty == false { restyle() } else { measure() }
      }
    }

    /// Tell the model the field's height, held to its lines: past them it
    /// scrolls.
    func measure() {
      guard let model, let layout = layoutManager, let container = textContainer else { return }
      layout.ensureLayout(for: container)
      let font = fieldFont(model.mode)
      let line = layout.defaultLineHeight(for: font)
      let used = max(layout.usedRect(for: container).height, line)
      let insets = textContainerInset.height * 2
      let fit = used + insets
      let cap = line * CGFloat(model.maxLines) + insets
      let height = min(fit, cap)
      enclosingScrollView?.hasVerticalScroller = fit > cap
      model.measured(height: height)
    }

    private func report() {
      guard !applying, let model, let storage = textStorage else { return }
      let range = selectedRange()
      model.edited(
        text: dartText(of: storage), start: range.location, end: range.location + range.length)
    }

    func textDidChange(_ notification: Notification) {
      report()
      measure()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      report()
    }

    /// A click on a card's cross takes the card out; anywhere else on it is
    /// the field's, as a click on a letter is. Hit here rather than through
    /// the delegate's attachment click, which AppKit never sends for an
    /// attachment that is an image with no cell to be clicked.
    override func mouseDown(with event: NSEvent) {
      if let code = cross(at: convert(event.locationInWindow, from: nil)) {
        model?.say("unembed", ["code": Int(code)])
        return
      }
      super.mouseDown(with: event)
    }

    /// The embed whose card's cross is under [point], in the view's own
    /// coordinates.
    private func cross(at point: NSPoint) -> UInt16? {
      guard let layout = layoutManager, let container = textContainer,
        let storage = textStorage, storage.length > 0
      else { return nil }
      let origin = textContainerOrigin
      let glyph = layout.glyphIndex(
        for: NSPoint(x: point.x - origin.x, y: point.y - origin.y), in: container)
      guard let code = embedCode(in: storage, at: layout.characterIndexForGlyph(at: glyph))
      else { return nil }
      let card = layout.boundingRect(
        forGlyphRange: NSRange(location: glyph, length: 1), in: container
      ).offsetBy(dx: origin.x, dy: origin.y)
      guard card.contains(point), point.x >= card.maxX - CardFace.crossWidth else { return nil }
      return code
    }

    // MARK: Keys

    /// A text view's editing shortcuts — cut, copy, paste, select all, undo —
    /// are the Edit menu's, sent to the first responder, and the menu bar is
    /// Flutter's, which has no Edit menu. The window offers a key equivalent
    /// to its views before the menu bar, so the field takes its own here,
    /// and Return's send, while it has focus; the rest go on to the menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
      if window?.firstResponder === self, handle(event) { return true }
      return super.performKeyEquivalent(with: event)
    }

    /// Option+Return, which is not a key equivalent, queues.
    override func keyDown(with event: NSEvent) {
      if handle(event) { return }
      super.keyDown(with: event)
    }

    /// Whether [event] was one of the field's own shortcuts, now done.
    private func handle(_ event: NSEvent) -> Bool {
      let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
      // Return and the keypad's Enter.
      if event.keyCode == 36 || event.keyCode == 76 {
        if flags == .command {
          model?.say("send")
          return true
        }
        if flags == .option {
          model?.say("queue")
          return true
        }
        return false
      }
      guard flags == .command || flags == [.command, .shift] else { return false }
      switch (event.charactersIgnoringModifiers?.lowercased(), flags.contains(.shift)) {
      case ("x", false): cut(nil)
      case ("c", false): copy(nil)
      case ("v", false): paste(nil)
      case ("a", false): selectAll(nil)
      case ("z", false): undoManager?.undo()
      case ("z", true): undoManager?.redo()
      default: return false
      }
      return true
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      guard let model else { return false }
      if !model.menu.isEmpty {
        switch selector {
        case #selector(moveUp(_:)):
          model.move(-1)
          return true
        case #selector(moveDown(_:)):
          model.move(1)
          return true
        case #selector(insertNewline(_:)), #selector(insertTab(_:)):
          model.pickHighlighted()
          return true
        case #selector(cancelOperation(_:)):
          model.say("dismiss")
          return true
        default:
          return false
        }
      }
      // Tab indents rather than leaving the field; Shift+Tab still leaves.
      if selector == #selector(insertTab(_:)) {
        insertText("  ", replacementRange: selectedRange())
        return true
      }
      return false
    }

    // MARK: Paste

    /// Files on the clipboard are attachments, which Dart takes, and so is an
    /// image with no text beside it; text is the field's own paste, plain.
    override func paste(_ sender: Any?) {
      let board = NSPasteboard.general
      let files =
        board.canReadObject(
          forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      let image = board.string(forType: .string) == nil && board.canReadItem(withDataConformingToTypes: ["public.image"])
      guard files || image, let model else {
        pasteAsPlainText(sender)
        return
      }
      model.paste { [weak self] took in
        if !took { self?.pasteAsPlainText(sender) }
      }
    }
  }

#endif
