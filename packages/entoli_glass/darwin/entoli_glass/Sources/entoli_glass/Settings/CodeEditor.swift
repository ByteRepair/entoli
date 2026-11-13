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
      size: 13 * prefs.scale, wrap: prefs.wrap
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

  /// The index of the last start at or before [offset].
  private func floor(_ offset: Int) -> Int {
    var low = 0
    var high = starts.count - 1
    while low < high {
      let mid = (low + high + 1) / 2
      if starts[mid] <= offset { low = mid } else { high = mid - 1 }
    }
    return low
  }

  /// The 1-based line [offset] starts, or nil where it is inside a line.
  func line(startingAt offset: Int) -> Int? {
    let at = floor(offset)
    return starts[at] == offset ? at + 1 : nil
  }

  /// The 1-based line [offset] is on.
  func line(containing offset: Int) -> Int { floor(offset) + 1 }
}

enum CodeGutter {
  /// Wide enough for the longest number and a margin either side.
  static func width(lines: Int, size: CGFloat) -> CGFloat {
    let digits = max(2, String(lines).count)
    return CGFloat(digits) * size * 0.62 + 16
  }

  /// The fragment the caret is on, in the container's coordinates: the
  /// empty line after a final newline where it is past the end.
  static func caretFragment(_ layout: NSLayoutManager, caret: Int, length: Int) -> CGRect? {
    if caret >= length {
      let extra = layout.extraLineFragmentRect
      if !extra.isEmpty { return extra }
      guard length > 0 else { return nil }
    }
    let glyph = layout.glyphIndexForCharacter(at: min(caret, length - 1))
    return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
  }

  /// Each line's number beside its first fragment among [glyphs], right
  /// aligned to [right]; [top] is where the container's origin falls in the
  /// gutter, and [current] the line lit as the caret's.
  static func draw(
    _ layout: NSLayoutManager, glyphs: NSRange, starts: LineStarts, size: CGFloat,
    current: Int?, right: CGFloat, top: CGFloat
  ) {
    let font = PlatformFont.monospacedDigitSystemFont(ofSize: size * 0.9, weight: .regular)
    func label(_ line: Int, _ rect: CGRect) {
      let label = "\(line)" as NSString
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: line == current
          ? PlatformColor.labelColor : PlatformColor.tertiaryLabelColor,
      ]
      let measured = label.size(withAttributes: attributes)
      label.draw(
        at: CGPoint(
          x: right - measured.width - 8,
          y: top + rect.minY + (rect.height - measured.height) / 2),
        withAttributes: attributes)
    }
    var index = glyphs.location
    while index < NSMaxRange(glyphs) {
      var range = NSRange()
      let rect = layout.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
      let character = layout.characterIndexForGlyph(at: range.location)
      if let line = starts.line(startingAt: character) { label(line, rect) }
      index = NSMaxRange(range)
    }
    let extra = layout.extraLineFragmentRect
    if !extra.isEmpty { label(starts.count, extra) }
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
      .foregroundColor: PlatformColor.labelColor,
    ]
  }

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

/// What both platforms' hosts share: the binding and how the text is set,
/// the line table, and asking the core for the tokens once typing pauses.
@MainActor final class CodeEditorState {
  var text: Binding<String>
  private(set) var name: String
  private(set) var size: CGFloat
  private(set) var dark: Bool
  private(set) var starts = LineStarts()
  private var colouring: Task<Void, Never>?

  init(text: Binding<String>, name: String, size: CGFloat, dark: Bool) {
    self.text = text
    self.name = name
    self.size = size
    self.dark = dark
  }

  /// Takes what SwiftUI passed: [storage] set to the text where it differs,
  /// and styled again where that or how it is set changed. Whether the view
  /// was refitted to it is [refit]'s.
  func sync(
    _ storage: NSTextStorage, text: String, name: String, size: CGFloat, dark: Bool,
    typing: inout [NSAttributedString.Key: Any], refit: @escaping () -> Void
  ) {
    let restyle = self.size != size || self.dark != dark || self.name != name
    self.size = size
    self.dark = dark
    self.name = name
    if storage.string != text {
      load(storage, text: text, typing: &typing, refit: refit)
    } else if restyle {
      style(storage, typing: &typing, refit: refit)
    }
  }

  /// [text] in place of what [storage] holds, counted and styled.
  func load(
    _ storage: NSTextStorage, text: String, typing: inout [NSAttributedString.Key: Any],
    refit: @escaping () -> Void
  ) {
    storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
    starts = LineStarts(text as NSString)
    style(storage, typing: &typing, refit: refit)
  }

  /// The base face at once, then the core's colours.
  func style(
    _ storage: NSTextStorage, typing: inout [NSAttributedString.Key: Any],
    refit: @escaping () -> Void
  ) {
    typing = CodeStyling.base(size: size)
    CodeStyling.apply(nil, to: storage, size: size, dark: dark)
    colour(storage, typed: false, done: refit)
    refit()
  }

  /// A keystroke: said back, counted, and coloured once the typing pauses.
  func edited(_ storage: NSTextStorage) {
    let string = storage.string
    text.wrappedValue = string
    starts = LineStarts(string as NSString)
    colour(storage, typed: true) {}
  }

  private func colour(_ storage: NSTextStorage, typed: Bool, done: @escaping () -> Void) {
    colouring?.cancel()
    let code = storage.string
    let (size, dark, name) = (size, dark, name)
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
}

#if os(macOS)
  private struct CodeTextHost: NSViewRepresentable {
    @Binding var text: String
    let name: String
    let editable: Bool
    let dark: Bool
    let size: CGFloat
    let wrap: Bool

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
      if let storage = view.textStorage {
        context.coordinator.state.load(
          storage, text: text, typing: &view.typingAttributes, refit: context.coordinator.refit)
      }
      setWrap(view, in: scroll)
      view.isEditable = editable
      if editable {
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
      }
      return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
      let coordinator = context.coordinator
      coordinator.state.text = $text
      guard let view = coordinator.view, let storage = view.textStorage else { return }
      view.isEditable = editable
      coordinator.state.sync(
        storage, text: text, name: name, size: size, dark: dark,
        typing: &view.typingAttributes, refit: coordinator.refit)
      setWrap(view, in: scroll)
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

      func refit() {
        ruler?.fit()
        ruler?.needsDisplay = true
      }

      func textDidChange(_ notification: Notification) {
        guard let storage = view?.textStorage else { return }
        state.edited(storage)
        refit()
      }

      func textViewDidChangeSelection(_ notification: Notification) {
        view?.caretMoved()
        ruler?.needsDisplay = true
      }

      @objc func scrolled() { ruler?.needsDisplay = true }
    }
  }

  /// The text view, lighting the line the caret is on while it is edited.
  final class CodeNSTextView: NSTextView {
    /// Where the light was last drawn, redrawn as the caret leaves it.
    private var lit: NSRect?

    private var caretLine: NSRect? {
      guard isEditable, window?.firstResponder === self, let layout = layoutManager,
        var line = CodeGutter.caretFragment(
          layout, caret: selectedRange().location, length: (string as NSString).length)
      else { return nil }
      line.origin.x = 0
      line.size.width = bounds.width
      line.origin.y += textContainerOrigin.y
      return line
    }

    /// Only the line it left and the one it is on drawn again.
    func caretMoved() {
      let now = caretLine
      if let lit { setNeedsDisplay(lit) }
      if let now { setNeedsDisplay(now) }
      lit = now
    }

    override func drawBackground(in rect: NSRect) {
      super.drawBackground(in: rect)
      guard let line = caretLine else { return }
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
      CodeGutter.draw(
        layout, glyphs: layout.glyphRange(forBoundingRect: text.visibleRect, in: container),
        starts: state.starts, size: state.size,
        current: text.isEditable
          ? state.starts.line(containing: text.selectedRange().location) : nil,
        right: ruleThickness,
        top: convert(NSPoint.zero, from: text).y + text.textContainerOrigin.y)
    }
  }
#else
  private struct CodeTextHost: UIViewRepresentable {
    @Binding var text: String
    let name: String
    let editable: Bool
    let dark: Bool
    let size: CGFloat
    /// UITextView scrolls one way, so it always wraps.
    let wrap: Bool

    func makeCoordinator() -> Coordinator {
      Coordinator(state: CodeEditorState(text: $text, name: name, size: size, dark: dark))
    }

    func makeUIView(context: Context) -> CodeUITextView {
      let view = CodeUITextView()
      view.state = context.coordinator.state
      view.delegate = context.coordinator
      context.coordinator.view = view
      context.coordinator.state.load(
        view.textStorage, text: text, typing: &view.typingAttributes, refit: view.refit)
      view.isEditable = editable
      if editable { DispatchQueue.main.async { view.becomeFirstResponder() } }
      return view
    }

    func updateUIView(_ view: CodeUITextView, context: Context) {
      context.coordinator.state.text = $text
      view.isEditable = editable
      context.coordinator.state.sync(
        view.textStorage, text: text, name: name, size: size, dark: dark,
        typing: &view.typingAttributes, refit: view.refit)
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
      let state: CodeEditorState
      weak var view: CodeUITextView?

      init(state: CodeEditorState) { self.state = state }

      func textViewDidChange(_ textView: UITextView) {
        guard let view else { return }
        state.edited(view.textStorage)
        view.refit()
      }

      func textViewDidChangeSelection(_ textView: UITextView) { view?.refreshGutter() }
    }
  }

  /// The text view with its gutter and the caret's line lit, both drawn over
  /// the visible part alone, so a long file costs only a screenful. A
  /// scroll lays the view out, which is where they follow it.
  final class CodeUITextView: TextKit1View {
    weak var state: CodeEditorState?
    private let gutter = CodeUIGutter()
    private let light = UIView()

    override init() {
      super.init()
      backgroundColor = .clear
      autocorrectionType = .no
      autocapitalizationType = .none
      smartQuotesType = .no
      smartDashesType = .no
      smartInsertDeleteType = .no
      spellCheckingType = .no
      alwaysBounceVertical = true
      keyboardDismissMode = .interactive
      isFindInteractionEnabled = true
      light.backgroundColor = UIColor.label.withAlphaComponent(0.06)
      light.isUserInteractionEnabled = false
      insertSubview(light, at: 0)
      gutter.text = self
      gutter.isUserInteractionEnabled = false
      gutter.backgroundColor = .systemBackground
      addSubview(gutter)
    }

    required init?(coder: NSCoder) { nil }

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
      let line =
        CodeGutter.caretFragment(
          layoutManager, caret: selectedRange.location, length: (text as NSString).length)
        ?? CGRect(x: 0, y: 0, width: 0, height: (state?.size ?? 13) * 1.2)
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
      let visible = CGRect(
        x: 0, y: text.contentOffset.y - text.textContainerInset.top,
        width: text.bounds.width, height: text.bounds.height)
      let lit = text.isEditable && text.isFirstResponder
      CodeGutter.draw(
        text.layoutManager,
        glyphs: text.layoutManager.glyphRange(forBoundingRect: visible, in: text.textContainer),
        starts: state.starts, size: state.size,
        current: lit ? state.starts.line(containing: text.selectedRange.location) : nil,
        right: bounds.width,
        top: text.textContainerInset.top - text.contentOffset.y)
    }
  }
#endif
