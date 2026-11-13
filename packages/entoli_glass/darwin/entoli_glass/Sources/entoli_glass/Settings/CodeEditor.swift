import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

/// How the reader likes code set: the reader's rather than the file's, so it
/// outlives the page for the session, as the Flutter editor's does.
@Observable final class CodeEditorPrefs {
  static let shared = CodeEditorPrefs()
  var wrap = false
  var scale: CGFloat = 1

  func zoom(by step: CGFloat) { scale = min(2.4, max(0.6, scale + step)) }
}

/// Text in the code face, as Apple ships no code editor: line numbers in a
/// gutter, the caret's line lit, the text coloured by the core's grammar for
/// [name], wrapped and sized as the reader set. TextKit 1 on both
/// platforms, whose line fragments the gutter numbers.
struct CodeEditor: View {
  @Binding var text: String
  let name: String
  var editable = true
  var placeholder: String?

  @Environment(\.colorScheme) private var scheme
  private let prefs = CodeEditorPrefs.shared

  var body: some View {
    CodeTextHost(
      text: $text, name: name, editable: editable, dark: scheme == .dark,
      wrap: prefs.wrap, size: 13 * prefs.scale
    )
    .overlay(alignment: .topLeading) {
      if editable, text.isEmpty, let placeholder {
        Text(placeholder)
          .font(.system(size: 13 * prefs.scale, design: .monospaced))
          .foregroundStyle(.tertiary)
          .padding(.leading, CodeGutter.width(lines: 1, size: 13 * prefs.scale) + 9)
          .padding(.top, 8)
          .allowsHitTesting(false)
      }
    }
  }
}

/// The editor's menu: wrapping, and the size the code is set at.
struct CodeEditorMenu: View {
  @Bindable private var prefs = CodeEditorPrefs.shared

  var body: some View {
    Menu {
      #if os(macOS)
        // UITextView wraps, always: it scrolls one way.
        Toggle("Wrap Lines", isOn: $prefs.wrap)
          .keyboardShortcut("w", modifiers: .option)
        Divider()
      #endif
      Button("Bigger") { prefs.zoom(by: 0.1) }.keyboardShortcut("+", modifiers: .command)
      Button("Smaller") { prefs.zoom(by: -0.1) }.keyboardShortcut("-", modifiers: .command)
      Button("Actual Size") { prefs.scale = 1 }.keyboardShortcut("0", modifiers: .command)
    } label: {
      Label("Text", systemImage: "textformat.size")
    }
    .help("Text")
  }
}

/// Line starts, as offsets into the text's UTF-16: what a fragment's first
/// character is looked up in to number it.
struct LineStarts {
  private(set) var starts: [Int] = [0]

  init(_ text: NSString = "") {
    var starts = [0]
    let length = text.length
    var at = 0
    while at < length {
      let found = text.range(of: "\n", range: NSRange(location: at, length: length - at))
      guard found.location != NSNotFound else { break }
      starts.append(found.location + 1)
      at = found.location + 1
    }
    self.starts = starts
  }

  var count: Int { starts.count }

  /// The 1-based line [offset] starts, or nil where it is inside a line.
  func line(startingAt offset: Int) -> Int? {
    var low = 0
    var high = starts.count - 1
    while low <= high {
      let mid = (low + high) / 2
      if starts[mid] == offset { return mid + 1 }
      if starts[mid] < offset { low = mid + 1 } else { high = mid - 1 }
    }
    return nil
  }
}

enum CodeGutter {
  /// Wide enough for the longest number and a margin either side.
  static func width(lines: Int, size: CGFloat) -> CGFloat {
    let digits = max(2, String(lines).count)
    return CGFloat(digits) * size * 0.62 + 16
  }

  static func font(_ size: CGFloat) -> PlatformFont {
    .monospacedDigitSystemFont(ofSize: size * 0.9, weight: .regular)
  }

  /// Each line fragment in [glyphs] that starts a line, its number and its
  /// rect in the container's coordinates; the empty line after a final
  /// newline among them.
  static func numbered(
    _ layout: NSLayoutManager, glyphs: NSRange, starts: LineStarts,
    each: (Int, CGRect) -> Void
  ) {
    var index = glyphs.location
    while index < NSMaxRange(glyphs) {
      var range = NSRange()
      let rect = layout.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
      let character = layout.characterIndexForGlyph(at: range.location)
      if let line = starts.line(startingAt: character) { each(line, rect) }
      index = NSMaxRange(range)
    }
    let extra = layout.extraLineFragmentRect
    if !extra.isEmpty { each(starts.count, extra) }
  }
}

/// The text's attributes from the core's tokens: the code face at the
/// reader's size, each scope in GitHub's colour, emphasis and strength in
/// their own faces.
enum CodeStyling {
  static let maxHighlighted = 200_000

  static func base(size: CGFloat) -> [NSAttributedString.Key: Any] {
    [
      .font: PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular),
      .foregroundColor: labelColour,
    ]
  }

  #if os(iOS)
    static let labelColour = UIColor.label
  #else
    static let labelColour = NSColor.textColor
  #endif

  static func apply(
    _ tokens: [CodeTokenSnapshot]?, to storage: NSTextStorage, size: CGFloat, dark: Bool
  ) {
    let whole = NSRange(location: 0, length: storage.length)
    storage.beginEditing()
    storage.setAttributes(base(size: size), range: whole)
    var at = 0
    for token in tokens ?? [] {
      let length = (token.text as NSString).length
      defer { at += length }
      guard let scope = token.scope, at + length <= storage.length else { continue }
      let range = NSRange(location: at, length: length)
      if let colour = CodeColours.of(scope, dark: dark) {
        storage.addAttribute(.foregroundColor, value: PlatformColor(colour), range: range)
      }
      let root = scope.split(separator: ".").first.map(String.init) ?? scope
      if root == "strong" || root == "section" {
        storage.addAttribute(
          .font, value: PlatformFont.monospacedSystemFont(ofSize: size, weight: .bold), range: range)
      } else if root == "emphasis" {
        storage.addAttribute(.font, value: italic(size), range: range)
      }
    }
    storage.endEditing()
  }

  private static func italic(_ size: CGFloat) -> PlatformFont {
    let font = PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular)
    #if os(iOS)
      return font.fontDescriptor.withSymbolicTraits(.traitItalic).map {
        UIFont(descriptor: $0, size: size)
      } ?? font
    #else
      return NSFont(
        descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? font
    #endif
  }
}

/// What both platforms' views share: the binding, the highlight pass, and
/// asking the core for the tokens once the typing pauses.
@MainActor final class CodeEditorState {
  var text: Binding<String>
  var name: String
  var size: CGFloat
  var dark: Bool
  var starts = LineStarts()
  private var colouring: Task<Void, Never>?

  init(text: Binding<String>, name: String, size: CGFloat, dark: Bool) {
    self.text = text
    self.name = name
    self.size = size
    self.dark = dark
  }

  /// Coloured again, at once where nothing was typed, after a pause where
  /// something was.
  func colour(_ storage: NSTextStorage, typed: Bool, done: @escaping () -> Void) {
    colouring?.cancel()
    let code = storage.string
    let size = size
    let dark = dark
    let name = name
    colouring = Task { @MainActor in
      if typed { try? await Task.sleep(for: .milliseconds(250)) }
      guard !Task.isCancelled else { return }
      let tokens =
        (code as NSString).length > CodeStyling.maxHighlighted
        ? nil : await TranscriptModel.shared?.highlight(code, name: name)
      // Typed over while the core answered: the next pass colours it.
      guard !Task.isCancelled, storage.string == code else { return }
      CodeStyling.apply(tokens, to: storage, size: size, dark: dark)
      done()
    }
  }

  func recount(_ string: String) { starts = LineStarts(string as NSString) }
}

#if os(macOS)
  private struct CodeTextHost: NSViewRepresentable {
    @Binding var text: String
    let name: String
    let editable: Bool
    let dark: Bool
    let wrap: Bool
    let size: CGFloat

    func makeCoordinator() -> Coordinator {
      Coordinator(state: CodeEditorState(text: $text, name: name, size: size, dark: dark))
    }

    func makeNSView(context: Context) -> NSScrollView {
      let scroll = NSScrollView()
      scroll.hasVerticalScroller = true
      scroll.hasHorizontalScroller = true
      scroll.autohidesScrollers = true
      scroll.drawsBackground = false
      let storage = NSTextStorage()
      let layout = NSLayoutManager()
      storage.addLayoutManager(layout)
      let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
      layout.addTextContainer(container)
      let view = CodeNSTextView(frame: .zero, textContainer: container)
      view.minSize = .zero
      view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      view.isVerticallyResizable = true
      view.autoresizingMask = [.width]
      view.drawsBackground = false
      view.isRichText = false
      view.allowsUndo = true
      view.usesFindBar = true
      view.isIncrementalSearchingEnabled = true
      view.isAutomaticQuoteSubstitutionEnabled = false
      view.isAutomaticDashSubstitutionEnabled = false
      view.isAutomaticTextReplacementEnabled = false
      view.isAutomaticSpellingCorrectionEnabled = false
      view.isContinuousSpellCheckingEnabled = false
      view.smartInsertDeleteEnabled = false
      view.textContainerInset = NSSize(width: 4, height: 8)
      view.delegate = context.coordinator
      scroll.documentView = view
      let ruler = CodeRuler(textView: view, state: context.coordinator.state)
      scroll.verticalRulerView = ruler
      scroll.hasVerticalRuler = true
      scroll.rulersVisible = true
      context.coordinator.view = view
      context.coordinator.ruler = ruler
      NotificationCenter.default.addObserver(
        context.coordinator, selector: #selector(Coordinator.scrolled),
        name: NSView.boundsDidChangeNotification, object: scroll.contentView)
      scroll.contentView.postsBoundsChangedNotifications = true
      view.string = text
      context.coordinator.state.recount(text)
      context.coordinator.restyle()
      setWrap(view, in: scroll)
      view.isEditable = editable
      if editable {
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
      }
      return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
      let coordinator = context.coordinator
      let state = coordinator.state
      state.text = $text
      guard let view = coordinator.view else { return }
      view.isEditable = editable
      view.lit = editable
      let restyle = state.size != size || state.dark != dark || state.name != name
      state.size = size
      state.dark = dark
      state.name = name
      if view.string != text {
        view.string = text
        state.recount(text)
        coordinator.restyle()
      } else if restyle {
        coordinator.restyle()
      }
      setWrap(view, in: scroll)
      coordinator.ruler?.fit()
    }

    private func setWrap(_ view: NSTextView, in scroll: NSScrollView) {
      guard let container = view.textContainer else { return }
      if wrap {
        guard !container.widthTracksTextView else { return }
        view.isHorizontallyResizable = false
        container.widthTracksTextView = true
        view.frame.size.width = scroll.contentSize.width
        container.containerSize = NSSize(
          width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
      } else {
        guard container.widthTracksTextView || container.containerSize.width == 0 else { return }
        container.widthTracksTextView = false
        container.containerSize = NSSize(
          width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isHorizontallyResizable = true
      }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
      let state: CodeEditorState
      weak var view: CodeNSTextView?
      weak var ruler: CodeRuler?

      init(state: CodeEditorState) { self.state = state }

      func restyle() {
        guard let view, let storage = view.textStorage else { return }
        view.typingAttributes = CodeStyling.base(size: state.size)
        CodeStyling.apply(nil, to: storage, size: state.size, dark: state.dark)
        state.colour(storage, typed: false) { [weak self] in self?.ruler?.needsDisplay = true }
        ruler?.fit()
      }

      func textDidChange(_ notification: Notification) {
        guard let view, let storage = view.textStorage else { return }
        state.text.wrappedValue = view.string
        state.recount(view.string)
        state.colour(storage, typed: true) {}
        ruler?.fit()
        ruler?.needsDisplay = true
      }

      func textViewDidChangeSelection(_ notification: Notification) {
        view?.needsDisplay = true
      }

      @objc func scrolled() { ruler?.needsDisplay = true }
    }
  }

  /// The text view, lighting the line the caret is on while it is edited.
  final class CodeNSTextView: NSTextView {
    var lit = true

    override func drawBackground(in rect: NSRect) {
      super.drawBackground(in: rect)
      guard lit, window?.firstResponder === self, let layout = layoutManager else { return }
      let caret = selectedRange().location
      var line: NSRect
      if caret >= (string as NSString).length, !layout.extraLineFragmentRect.isEmpty {
        line = layout.extraLineFragmentRect
      } else {
        let length = (string as NSString).length
        guard length > 0 else { return }
        let glyph = layout.glyphIndexForCharacter(at: min(caret, length - 1))
        line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      }
      line.origin.x = 0
      line.size.width = bounds.width
      line.origin.y += textContainerOrigin.y
      NSColor.labelColor.withAlphaComponent(0.06).setFill()
      line.fill()
    }
  }

  /// The gutter: each line's number beside its first fragment.
  final class CodeRuler: NSRulerView {
    private weak var text: NSTextView?
    private let state: CodeEditorState

    init(textView: NSTextView, state: CodeEditorState) {
      self.text = textView
      self.state = state
      super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
      clientView = textView
      fit()
    }

    required init(coder: NSCoder) { fatalError("not from a coder") }

    func fit() {
      let width = CodeGutter.width(lines: state.starts.count, size: state.size)
      if abs(ruleThickness - width) > 0.5 { ruleThickness = width }
    }

    override var isFlipped: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
      guard let text, let layout = text.layoutManager, let container = text.textContainer
      else { return }
      NSColor.windowBackgroundColor.setFill()
      bounds.fill()
      let visible = text.visibleRect
      let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
      let offset = convert(NSPoint.zero, from: text).y + text.textContainerOrigin.y
      let caret = text.selectedRange().location
      let caretLine = state.starts.starts.lastIndex { $0 <= caret }.map { $0 + 1 }
      let font = CodeGutter.font(state.size)
      CodeGutter.numbered(layout, glyphs: glyphs, starts: state.starts) { line, rect in
        let label = "\(line)" as NSString
        let current = line == caretLine && text.isEditable
        let attributes: [NSAttributedString.Key: Any] = [
          .font: font,
          .foregroundColor: current ? NSColor.labelColor : NSColor.tertiaryLabelColor,
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(
          at: NSPoint(
            x: ruleThickness - size.width - 8,
            y: offset + rect.minY + (rect.height - size.height) / 2),
          withAttributes: attributes)
      }
    }
  }
#else
  private struct CodeTextHost: UIViewRepresentable {
    @Binding var text: String
    let name: String
    let editable: Bool
    let dark: Bool
    let wrap: Bool
    let size: CGFloat

    func makeCoordinator() -> Coordinator {
      Coordinator(state: CodeEditorState(text: $text, name: name, size: size, dark: dark))
    }

    func makeUIView(context: Context) -> CodeUITextView {
      // A stack of its own, so the view is TextKit 1 from the start.
      let storage = NSTextStorage()
      let layout = NSLayoutManager()
      storage.addLayoutManager(layout)
      let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
      container.widthTracksTextView = true
      layout.addTextContainer(container)
      let view = CodeUITextView(frame: .zero, textContainer: container)
      view.state = context.coordinator.state
      view.backgroundColor = .clear
      view.autocorrectionType = .no
      view.autocapitalizationType = .none
      view.smartQuotesType = .no
      view.smartDashesType = .no
      view.smartInsertDeleteType = .no
      view.spellCheckingType = .no
      view.alwaysBounceVertical = true
      view.keyboardDismissMode = .interactive
      view.isFindInteractionEnabled = true
      view.delegate = context.coordinator
      context.coordinator.view = view
      view.text = text
      context.coordinator.state.recount(text)
      context.coordinator.restyle()
      view.isEditable = editable
      if editable { DispatchQueue.main.async { view.becomeFirstResponder() } }
      return view
    }

    func updateUIView(_ view: CodeUITextView, context: Context) {
      let coordinator = context.coordinator
      let state = coordinator.state
      state.text = $text
      view.isEditable = editable
      let restyle = state.size != size || state.dark != dark || state.name != name
      state.size = size
      state.dark = dark
      state.name = name
      if view.text != text {
        view.text = text
        state.recount(text)
        coordinator.restyle()
      } else if restyle {
        coordinator.restyle()
      }
      view.refit()
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
      let state: CodeEditorState
      weak var view: CodeUITextView?

      init(state: CodeEditorState) { self.state = state }

      func restyle() {
        guard let view else { return }
        view.typingAttributes = CodeStyling.base(size: state.size)
        CodeStyling.apply(nil, to: view.textStorage, size: state.size, dark: state.dark)
        state.colour(view.textStorage, typed: false) { [weak view] in view?.refreshGutter() }
        view.refit()
      }

      func textViewDidChange(_ textView: UITextView) {
        guard let view else { return }
        state.text.wrappedValue = view.text
        state.recount(view.text)
        state.colour(view.textStorage, typed: true) {}
        view.refit()
      }

      func textViewDidChangeSelection(_ textView: UITextView) { view?.refreshGutter() }

      func scrollViewDidScroll(_ scrollView: UIScrollView) { view?.refreshGutter() }
    }
  }

  /// The text view with its gutter and the caret's line lit, both drawn over
  /// the visible part alone, so a long file costs only a screenful.
  final class CodeUITextView: UITextView {
    weak var state: CodeEditorState?
    private let gutter = CodeUIGutter()
    private let light = UIView()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
      super.init(frame: frame, textContainer: textContainer)
      setUp()
    }

    required init?(coder: NSCoder) { fatalError("not from a coder") }

    private func setUp() {
      light.backgroundColor = UIColor.label.withAlphaComponent(0.06)
      light.isUserInteractionEnabled = false
      insertSubview(light, at: 0)
      gutter.text = self
      gutter.isUserInteractionEnabled = false
      gutter.backgroundColor = .systemBackground
      addSubview(gutter)
    }

    func refit() {
      guard let state else { return }
      let width = CodeGutter.width(lines: state.starts.count, size: state.size)
      if abs(textContainerInset.left - width - 4) > 0.5 {
        textContainerInset = UIEdgeInsets(top: 8, left: width + 4, bottom: 8, right: 8)
      }
      refreshGutter()
    }

    func refreshGutter() {
      guard let state else { return }
      let width = CodeGutter.width(lines: state.starts.count, size: state.size)
      gutter.frame = CGRect(x: contentOffset.x, y: contentOffset.y, width: width, height: bounds.height)
      gutter.state = state
      gutter.setNeedsDisplay()
      bringSubviewToFront(gutter)
      placeLight()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      refreshGutter()
    }

    private func placeLight() {
      guard isEditable, isFirstResponder else {
        light.isHidden = true
        return
      }
      let caret = selectedRange.location
      let length = (text as NSString).length
      var line: CGRect
      if caret >= length, !layoutManager.extraLineFragmentRect.isEmpty || length == 0 {
        line = layoutManager.extraLineFragmentRect
        if line.isEmpty {
          line = CGRect(x: 0, y: 0, width: 0, height: font?.lineHeight ?? 16)
        }
      } else {
        let glyph = layoutManager.glyphIndexForCharacter(at: min(caret, max(0, length - 1)))
        line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      }
      light.isHidden = false
      light.frame = CGRect(
        x: 0, y: line.minY + textContainerInset.top,
        width: max(bounds.width, contentSize.width), height: line.height)
    }
  }

  final class CodeUIGutter: UIView {
    weak var text: CodeUITextView?
    weak var state: CodeEditorState?

    override func draw(_ rect: CGRect) {
      guard let text, let state else { return }
      let layout = text.layoutManager
      let visible = CGRect(
        x: 0, y: text.contentOffset.y - text.textContainerInset.top,
        width: text.bounds.width, height: text.bounds.height)
      let glyphs = layout.glyphRange(forBoundingRect: visible, in: text.textContainer)
      let caret = text.selectedRange.location
      let caretLine = state.starts.starts.lastIndex { $0 <= caret }.map { $0 + 1 }
      let font = CodeGutter.font(state.size)
      let top = text.textContainerInset.top - text.contentOffset.y
      CodeGutter.numbered(layout, glyphs: glyphs, starts: state.starts) { line, fragment in
        let label = "\(line)" as NSString
        let current = line == caretLine && text.isEditable && text.isFirstResponder
        let attributes: [NSAttributedString.Key: Any] = [
          .font: font,
          .foregroundColor: current ? UIColor.label : UIColor.tertiaryLabel,
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(
          at: CGPoint(
            x: bounds.width - size.width - 8,
            y: top + fragment.minY + (fragment.height - size.height) / 2),
          withAttributes: attributes)
      }
    }
  }
#endif
