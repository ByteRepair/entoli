import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

/// The key a formula's TeX rides under on its attachment, which a copy and a
/// reply read back in the picture's place.
private let texKey = NSAttributedString.Key("entoli.tex")

/// Runs of prose — paragraphs, headings, list items, quotes, formulas — as
/// one attributed string, so a selection runs across them as it does in the
/// Flutter app.
enum ProseBuilder {
  static func build(
    _ blocks: [TextBlockSnapshot], model: TranscriptModel, caret: Bool, tone: PlatformColor?
  ) -> NSAttributedString {
    let out = NSMutableAttributedString()
    for (index, block) in blocks.enumerated() {
      if index > 0 { out.append(NSAttributedString(string: "\n")) }
      let start = out.length
      out.append(line(block, model: model, tone: tone))
      let style = paragraph(block, first: index == 0)
      out.addAttribute(
        .paragraphStyle, value: style, range: NSRange(location: start, length: out.length - start))
    }
    if caret {
      out.append(
        NSAttributedString(
          string: " ▍", attributes: [.font: body, .foregroundColor: PlatformColor.accent]))
    }
    return out
  }

  static var body: PlatformFont {
    #if os(iOS)
      UIFont.preferredFont(forTextStyle: .body)
    #else
      NSFont.systemFont(ofSize: NSFont.systemFontSize + 1)
    #endif
  }

  private static func line(_ block: TextBlockSnapshot, model: TranscriptModel, tone: PlatformColor?)
    -> NSAttributedString
  {
    let out = NSMutableAttributedString()
    let base: PlatformFont =
      block.kind == .heading ? heading(block.level) : body
    var colour = tone ?? PlatformColor.labelColor
    if block.quotes > 0 { colour = PlatformColor.secondaryLabelColor }
    if let marker = block.items.last, marker.first {
      let text =
        marker.checked.map { $0 ? "☑︎" : "☐" } ?? (marker.ordered ? "\(marker.number)." : "•")
      out.append(
        NSAttributedString(
          string: "\(text)\t",
          attributes: [.font: base, .foregroundColor: PlatformColor.secondaryLabelColor]))
    } else if !block.items.isEmpty {
      out.append(NSAttributedString(string: "\t", attributes: [.font: base]))
    }
    switch block.kind {
    case .formula:
      out.append(formula(block.formula, written: block.written, model: model, font: base))
    default:
      for inline in block.inlines {
        out.append(piece(inline, model: model, font: base, colour: colour))
      }
    }
    return out
  }

  private static func piece(
    _ inline: InlineSnapshot, model: TranscriptModel, font: PlatformFont, colour: PlatformColor
  ) -> NSAttributedString {
    switch inline.kind {
    case .text:
      var attributes: [NSAttributedString.Key: Any] = [
        .font: marked(font, bold: inline.bold, italic: inline.italic, code: inline.code),
        .foregroundColor: colour,
      ]
      if inline.code {
        attributes[.backgroundColor] = PlatformColor.secondaryLabelColor.withAlphaComponent(0.12)
      }
      if inline.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
      if let link = inline.link, let url = URL(string: link) { attributes[.link] = url }
      return NSAttributedString(string: inline.text, attributes: attributes)
    case .formula:
      return formula(inline.formula, written: inline.text, model: model, font: font)
    case .lineBreak:
      return NSAttributedString(string: "\u{2028}", attributes: [.font: font])
    case .image:
      return NSAttributedString(
        string: inline.text,
        attributes: [.font: font, .foregroundColor: PlatformColor.secondaryLabelColor])
    }
  }

  /// A formula's picture set on the baseline, its TeX under [texKey]; the
  /// TeX itself, plainly, until the picture lands.
  private static func formula(
    _ id: Int64?, written: String, model: TranscriptModel, font: PlatformFont
  ) -> NSAttributedString {
    guard let id, let picture = model.formulas[id] else {
      return NSAttributedString(
        string: written,
        attributes: [
          .font: marked(font, bold: false, italic: false, code: true),
          .foregroundColor: PlatformColor.secondaryLabelColor,
        ])
    }
    let attachment = NSTextAttachment()
    attachment.image = picture.platform
    let size = picture.size
    let below = size.height - picture.baseline
    attachment.bounds = CGRect(x: 0, y: -below, width: size.width, height: size.height)
    let out = NSMutableAttributedString(attachment: attachment)
    out.addAttribute(texKey, value: written, range: NSRange(location: 0, length: out.length))
    return out
  }

  private static func heading(_ level: Int64) -> PlatformFont {
    let size = body.pointSize
    let scale: CGFloat = level == 1 ? 1.45 : level == 2 ? 1.25 : level == 3 ? 1.1 : 1
    return PlatformFont.systemFont(ofSize: size * scale, weight: .semibold)
  }

  private static func marked(_ font: PlatformFont, bold: Bool, italic: Bool, code: Bool)
    -> PlatformFont
  {
    if code {
      return PlatformFont.monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular)
    }
    #if os(iOS)
      var traits = font.fontDescriptor.symbolicTraits
      if bold { traits.insert(.traitBold) }
      if italic { traits.insert(.traitItalic) }
      return font.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: 0) }
        ?? font
    #else
      var traits = font.fontDescriptor.symbolicTraits
      if bold { traits.insert(.bold) }
      if italic { traits.insert(.italic) }
      return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: 0) ?? font
    #endif
  }

  private static func paragraph(_ block: TextBlockSnapshot, first: Bool) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    let indent = CGFloat(block.items.count) * 22 + CGFloat(block.quotes) * 14
    style.headIndent = indent
    style.firstLineHeadIndent = block.items.isEmpty ? indent : indent - 22
    style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
    style.defaultTabInterval = 22
    style.paragraphSpacingBefore = first ? 0 : (block.kind == .heading ? 12 : 8)
    style.lineSpacing = 2
    if block.kind == .formula { style.alignment = .center }
    return style
  }

  /// [text]'s plain words, a formula as the TeX it was written as.
  static func plain(_ text: NSAttributedString) -> String {
    var out = ""
    text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
      if let tex = attributes[texKey] as? String {
        out += tex
      } else {
        out += (text.string as NSString).substring(with: range)
          .replacingOccurrences(of: "\u{2028}", with: "\n")
      }
    }
    return out
  }
}

/// What the prose's menu offers: copy, and answering the passage.
struct ProseActions {
  /// Null where there is nothing to answer: a summary, a sub-agent's reply.
  var reply: ((String) -> Void)?
  var link: (URL) -> Void
}

#if os(iOS)
  extension UIColor {
    static var labelColor: UIColor { .label }
    static var secondaryLabelColor: UIColor { .secondaryLabel }
    static var accent: UIColor { .tintColor }
  }
#else
  extension NSColor {
    static var accent: NSColor { .controlAccentColor }
  }
#endif

#if os(macOS)
  /// Prose in a text view of AppKit's own, selectable, sized to its text,
  /// and with the app's menu: Copy and Reply in place of the system's
  /// spelling, fonts and services, which say nothing about a reply.
  struct ProseText: NSViewRepresentable {
    let text: NSAttributedString
    let actions: ProseActions

    func makeNSView(context: Context) -> ProseTextView {
      let view = ProseTextView()
      view.isEditable = false
      view.isSelectable = true
      view.drawsBackground = false
      view.textContainerInset = .zero
      view.textContainer?.lineFragmentPadding = 0
      view.textContainer?.widthTracksTextView = true
      view.isVerticallyResizable = false
      view.linkTextAttributes = [
        .foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand,
      ]
      view.delegate = context.coordinator
      return view
    }

    func updateNSView(_ view: ProseTextView, context: Context) {
      view.actions = actions
      context.coordinator.actions = actions
      if view.textStorage?.isEqual(to: text) != true {
        view.textStorage?.setAttributedString(text)
      }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ProseTextView, context: Context)
      -> CGSize?
    {
      let width = proposal.width ?? 600
      guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
      container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
      layout.ensureLayout(for: container)
      return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(actions: actions) }

    final class Coordinator: NSObject, NSTextViewDelegate {
      var actions: ProseActions
      init(actions: ProseActions) { self.actions = actions }

      func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL { actions.link(url) }
        return true
      }
    }
  }

  final class ProseTextView: NSTextView {
    var actions: ProseActions?

    private var selected: NSAttributedString? {
      let range = selectedRange()
      guard range.length > 0, let storage = textStorage else { return nil }
      return storage.attributedSubstring(from: range)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
      let menu = NSMenu()
      let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
      copy.target = self
      let reply = NSMenuItem(title: "Reply", action: #selector(replyToSelection), keyEquivalent: "")
      reply.target = self
      reply.image = NSImage(systemSymbolName: "arrowshape.turn.up.left", accessibilityDescription: nil)
      menu.items = actions?.reply == nil ? [copy] : [copy, reply]
      return menu
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
      if item.action == #selector(copy(_:)) || item.action == #selector(replyToSelection) {
        return selected != nil
      }
      return super.validateMenuItem(item)
    }

    /// The words, a formula as its TeX: a picture's character pastes as
    /// nothing anywhere else.
    override func copy(_ sender: Any?) {
      guard let selected else { return }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(ProseBuilder.plain(selected), forType: .string)
    }

    @objc func replyToSelection() {
      guard let selected else { return }
      actions?.reply?(ProseBuilder.plain(selected))
      setSelectedRange(NSRange(location: 0, length: 0))
    }
  }
#else
  /// Prose in UIKit's text view, selectable, sized to its text, its edit
  /// menu the app's: Copy and Reply in place of the system's look-up and
  /// translate, which say nothing about a reply.
  struct ProseText: UIViewRepresentable {
    let text: NSAttributedString
    let actions: ProseActions

    func makeUIView(context: Context) -> UITextView {
      let view = UITextView()
      view.isEditable = false
      view.isSelectable = true
      view.isScrollEnabled = false
      view.backgroundColor = .clear
      view.textContainerInset = .zero
      view.textContainer.lineFragmentPadding = 0
      view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      view.delegate = context.coordinator
      return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
      context.coordinator.actions = actions
      if !view.attributedText.isEqual(to: text) { view.attributedText = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context)
      -> CGSize?
    {
      let width = proposal.width ?? 320
      let size = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
      return CGSize(width: width, height: ceil(size.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(actions: actions) }

    final class Coordinator: NSObject, UITextViewDelegate {
      var actions: ProseActions
      init(actions: ProseActions) { self.actions = actions }

      func textView(
        _ textView: UITextView, primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
      ) -> UIAction? {
        guard case .link(let url) = textItem.content else { return defaultAction }
        return UIAction { [actions] _ in actions.link(url) }
      }

      func textView(
        _ textView: UITextView, editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
      ) -> UIMenu? {
        guard range.length > 0 else { return nil }
        let selected = textView.attributedText.attributedSubstring(from: range)
        let plain = ProseBuilder.plain(selected)
        var children: [UIMenuElement] = [
          UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
            UIPasteboard.general.string = plain
          }
        ]
        if let reply = actions.reply {
          children.append(
            UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { _ in
              reply(plain)
              textView.selectedRange = NSRange(location: 0, length: 0)
            })
        }
        return UIMenu(children: children)
      }
    }
  }
#endif
