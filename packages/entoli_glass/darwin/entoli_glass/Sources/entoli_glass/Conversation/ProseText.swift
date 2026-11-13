import SwiftUI
import CoreText

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

/// What a run of characters reads as in a copy or a reply, in place of the
/// characters: a formula's TeX, nothing for a code block's language line, a
/// table's pipes.
private let swapKey = NSAttributedString.Key("entoli.swap")
/// A code block's lines, by the fence's language ("" for none), which a copy
/// reads back as the fence.
private let languageKey = NSAttributedString.Key("entoli.language")
/// A code block, header and lines, by an id of its own: the box drawn
/// behind it.
private let boxKey = NSAttributedString.Key("entoli.box")
/// A table by its id, each row by its index, and its column edges.
private let tableKey = NSAttributedString.Key("entoli.table")
private let rowKey = NSAttributedString.Key("entoli.row")
private let columnsKey = NSAttributedString.Key("entoli.columns")
/// How many quotes deep a paragraph is: the bars drawn beside it.
private let quoteKey = NSAttributedString.Key("entoli.quote")
/// A horizontal rule: a line of its own the view draws across.
private let ruleKey = NSAttributedString.Key("entoli.rule")

/// A reply's markdown as one attributed string — paragraphs, headings, list
/// items, quotes, formulas, code and tables — so a selection runs across all
/// of it as it does in the Flutter app. What the text cannot draw — a code
/// block's box, a table's grid, a quote's bar, a rule — is marked on it, and the view
/// draws it behind (`ProseDecorations`).
enum ProseBuilder {
  /// Room inside a code box and a table cell.
  static let pad: CGFloat = 12
  static let cellPad: CGFloat = 8

  /// [width] is what the text is laid out in, which a table's columns fit;
  /// nil leaves each column as wide as its widest cell.
  static func build(
    _ blocks: [TextBlockSnapshot], model: TranscriptModel, caret: Bool, tone: PlatformColor?,
    dark: Bool, width: CGFloat? = nil
  ) -> NSAttributedString {
    let out = NSMutableAttributedString()
    for (index, block) in blocks.enumerated() {
      if index > 0 { out.append(NSAttributedString(string: "\n")) }
      let first = index == 0
      switch block.kind {
      case .code: out.append(code(block, id: index, dark: dark, first: first))
      case .table:
        out.append(
          table(block, id: index, model: model, tone: tone, first: first, width: width))
      case .rule:
        // A space to hold the line, copied as the markdown it was.
        out.append(
          NSAttributedString(
            string: " ",
            attributes: [
              .font: body, ruleKey: true, swapKey: "---",
              .paragraphStyle: paragraph(block, first: first),
            ]))
      default:
        let start = out.length
        out.append(line(block, model: model, tone: tone))
        let range = NSRange(location: start, length: out.length - start)
        out.addAttribute(.paragraphStyle, value: paragraph(block, first: first), range: range)
        if block.quotes > 0 { out.addAttribute(quoteKey, value: Int(block.quotes), range: range) }
      }
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

  private static func indent(_ block: TextBlockSnapshot) -> CGFloat {
    CGFloat(block.items.count) * 22 + CGFloat(block.quotes) * 14
  }

  private static func line(_ block: TextBlockSnapshot, model: TranscriptModel, tone: PlatformColor?)
    -> NSAttributedString
  {
    let out = NSMutableAttributedString()
    let base: PlatformFont = block.kind == .heading ? heading(block.level) : body
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
    if block.kind == .formula {
      out.append(formula(block.formula, written: block.written, model: model, font: base))
    } else {
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

  /// A formula's picture set on the baseline, reading as its TeX; the TeX
  /// itself, plainly, until the picture lands.
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
    attachment.bounds = CGRect(
      x: 0, y: -(size.height - picture.baseline), width: size.width, height: size.height)
    let out = NSMutableAttributedString(attachment: attachment)
    out.addAttribute(swapKey, value: written, range: NSRange(location: 0, length: out.length))
    return out
  }

  /// A fenced block: a line naming its language, then its lines in the mono
  /// face coloured by their tokens' scopes, inset in a box the view draws.
  /// Lines wrap rather than scroll, a scroll being a selection of its own.
  /// [id] tells one box from the next; the block's index, so the same text
  /// builds equal and a view is not laid out again for nothing.
  private static func code(_ block: TextBlockSnapshot, id: Int, dark: Bool, first: Bool)
    -> NSAttributedString
  {
    let inset = indent(block) + pad
    let out = NSMutableAttributedString()

    let header = NSMutableParagraphStyle()
    header.headIndent = inset
    header.firstLineHeadIndent = inset
    header.tailIndent = -pad
    header.paragraphSpacingBefore = (first ? 0 : 8) + 8
    header.paragraphSpacing = 2
    out.append(
      NSAttributedString(
        string: block.language ?? "",
        attributes: [
          .font: PlatformFont.systemFont(ofSize: body.pointSize * 0.8),
          .foregroundColor: PlatformColor.secondaryLabelColor,
          .paragraphStyle: header, swapKey: "",
        ]))
    out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: header, swapKey: ""]))

    let font = PlatformFont.monospacedSystemFont(ofSize: body.pointSize * 0.9, weight: .regular)
    let lines = NSMutableAttributedString()
    let tokens = block.tokens.isEmpty ? [CodeTokenSnapshot(text: block.code)] : block.tokens
    for token in tokens {
      var colour = PlatformColor.labelColor
      if let scope = token.scope, let tint = CodeColours.of(scope, dark: dark) {
        colour = PlatformColor(tint)
      }
      lines.append(
        NSAttributedString(string: token.text, attributes: [.font: font, .foregroundColor: colour]))
    }
    let style = NSMutableParagraphStyle()
    style.headIndent = inset
    style.firstLineHeadIndent = inset
    style.tailIndent = -pad
    style.lineBreakMode = .byCharWrapping
    let all = NSRange(location: 0, length: lines.length)
    lines.addAttribute(.paragraphStyle, value: style, range: all)
    lines.addAttribute(languageKey, value: block.language ?? "", range: all)
    // The last line keeps the box's room under it.
    let last = (lines.string as NSString).range(of: "\n", options: .backwards)
    let tail = NSMutableParagraphStyle()
    tail.setParagraphStyle(style)
    tail.paragraphSpacing = pad
    let from = last.location == NSNotFound ? 0 : last.location + 1
    lines.addAttribute(
      .paragraphStyle, value: tail, range: NSRange(location: from, length: lines.length - from))
    out.append(lines)
    out.addAttribute(boxKey, value: id, range: NSRange(location: 0, length: out.length))
    return out
  }

  /// A table fitted to [width] as the Flutter app's is: each column as wide
  /// as its widest cell where they all fit, and where they do not, no
  /// narrower than its longest word, the rest of the room shared by how much
  /// more each wants. A cell wraps onto as many lines as it needs, a row a
  /// paragraph whose lines are line separators, a cell a tab stop placed and
  /// aligned as its column says, the grid drawn by the view. A row reads as
  /// a markdown row in a copy, whatever part of it was selected.
  private static func table(
    _ block: TextBlockSnapshot, id: Int, model: TranscriptModel, tone: PlatformColor?, first: Bool,
    width: CGFloat?
  ) -> NSAttributedString {
    let colour = tone ?? PlatformColor.labelColor
    let rows = Dictionary(grouping: block.cells, by: \.row).sorted { $0.key < $1.key }
    let columns = max(1, Int(block.columns))
    func cell(_ cell: CellSnapshot) -> NSAttributedString {
      let font = cell.header ? marked(body, bold: true, italic: false, code: false) : body
      let out = NSMutableAttributedString()
      for inline in cell.inlines { out.append(piece(inline, model: model, font: font, colour: colour)) }
      return out
    }
    func measure(_ text: NSAttributedString) -> CGFloat {
      ceil(
        text.boundingRect(
          with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin],
          context: nil
        ).width)
    }
    let built = rows.map { ($0.key, $0.value.sorted { $0.column < $1.column }.map { ($0, cell($0)) }) }
    var wants = [CGFloat](repeating: 2 * cellPad, count: columns)
    var floors = [CGFloat](repeating: 2 * cellPad, count: columns)
    for (_, cells) in built {
      for (c, text) in cells where Int(c.column) < columns {
        let at = Int(c.column)
        wants[at] = max(wants[at], measure(text) + 2 * cellPad)
        (text.string as NSString).enumerateSubstrings(
          in: NSRange(location: 0, length: text.length), options: .byWords
        ) { _, word, _, _ in
          floors[at] = max(floors[at], measure(text.attributedSubstring(from: word)) + 2 * cellPad)
        }
      }
    }
    let left = indent(block)
    var widths = wants
    if let width, width > 0 {
      let room = width - left - 1
      let wanted = wants.reduce(0, +)
      let least = floors.reduce(0, +)
      if wanted > room {
        if least >= room {
          widths = floors
        } else {
          let more = wanted - least
          widths = (0..<columns).map { floors[$0] + (wants[$0] - floors[$0]) * (room - least) / more }
        }
      }
    }
    var edges = [left]
    for w in widths { edges.append(edges.last! + w) }
    let stops = (0..<columns).map { c -> NSTextTab in
      let align = c < block.align.count ? block.align[c] : .start
      switch align {
      case .start: return NSTextTab(textAlignment: .left, location: edges[c] + cellPad)
      case .center: return NSTextTab(textAlignment: .center, location: (edges[c] + edges[c + 1]) / 2)
      case .end: return NSTextTab(textAlignment: .right, location: edges[c + 1] - cellPad)
      }
    }
    let rule = "|" + String(repeating: "---|", count: columns)
    let out = NSMutableAttributedString()
    for (r, (_, cells)) in built.enumerated() {
      if r > 0 { out.append(NSAttributedString(string: "\n")) }
      let start = out.length
      let wrapped = cells.map { c, text in
        wrap(text, in: widths[min(Int(c.column), columns - 1)] - 2 * cellPad)
      }
      let height = wrapped.map(\.count).max() ?? 1
      for line in 0..<height {
        if line > 0 { out.append(NSAttributedString(string: "\u{2028}", attributes: [.font: body])) }
        for pieces in wrapped {
          out.append(NSAttributedString(string: "\t", attributes: [.font: body]))
          if line < pieces.count { out.append(pieces[line]) }
        }
      }
      // Ends the row where its last cell is short of the last column.
      out.append(NSAttributedString(string: "\u{200B}", attributes: [.font: body]))
      let style = NSMutableParagraphStyle()
      style.tabStops = stops
      style.headIndent = left
      style.firstLineHeadIndent = left
      style.lineBreakMode = .byClipping
      style.paragraphSpacingBefore = (r == 0 && !first ? 8 : 0) + 6
      style.paragraphSpacing = 6
      let range = NSRange(location: start, length: out.length - start)
      out.addAttribute(.paragraphStyle, value: style, range: range)
      out.addAttribute(rowKey, value: r, range: range)
      let written = "| " + cells.map { plain($0.1) }.joined(separator: " | ") + " |"
      out.addAttribute(swapKey, value: r == 0 ? written + "\n" + rule : written, range: range)
    }
    let all = NSRange(location: 0, length: out.length)
    out.addAttribute(tableKey, value: id, range: all)
    out.addAttribute(columnsKey, value: edges.map { NSNumber(value: Double($0)) }, range: all)
    return out
  }

  /// [text] broken into lines no wider than [width]: at a word where one
  /// fits, inside a word too long for the line.
  private static func wrap(_ text: NSAttributedString, in width: CGFloat) -> [NSAttributedString] {
    guard text.length > 0 else { return [] }
    let typesetter = CTTypesetterCreateWithAttributedString(text as CFAttributedString)
    let room = Double(max(1, width))
    var lines: [NSAttributedString] = []
    var at = 0
    while at < text.length {
      var count = CTTypesetterSuggestLineBreak(typesetter, at, room)
      let line = CTTypesetterCreateLine(typesetter, CFRange(location: at, length: max(1, count)))
      if CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
        > room
      {
        count = CTTypesetterSuggestClusterBreak(typesetter, at, room)
      }
      count = max(1, count)
      var range = NSRange(location: at, length: count)
      let string = text.string as NSString
      while range.length > 0,
        let scalar = Unicode.Scalar(string.character(at: NSMaxRange(range) - 1)),
        CharacterSet.whitespacesAndNewlines.contains(scalar)
      {
        range.length -= 1
      }
      lines.append(text.attributedSubstring(from: range))
      at += count
    }
    return lines
  }

  private static func heading(_ level: Int64) -> PlatformFont {
    let scale: CGFloat = level == 1 ? 1.45 : level == 2 ? 1.25 : level == 3 ? 1.1 : 1
    return PlatformFont.systemFont(ofSize: body.pointSize * scale, weight: .semibold)
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
    let indent = indent(block)
    style.headIndent = indent
    style.firstLineHeadIndent = block.items.isEmpty ? indent : indent - 22
    style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
    style.defaultTabInterval = 22
    style.paragraphSpacingBefore = first ? 0 : (block.kind == .heading ? 12 : 8)
    style.lineSpacing = 2
    if block.kind == .formula { style.alignment = .center }
    return style
  }

  /// [text] as a reader would paste it where markdown is read: a formula as
  /// its TeX, code inside its fence, a table with its pipes.
  static func plain(_ text: NSAttributedString) -> String {
    var out = ""
    var fence: String?
    // A swap spans runs where the text under it changes face, a table's row:
    // it is read once for all of them.
    var swapped: (value: String, end: Int)?
    text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
      let language = attributes[languageKey] as? String
      if language != fence {
        if fence != nil { out += out.hasSuffix("\n") ? "```\n" : "\n```\n" }
        if let language { out += "```\(language)\n" }
        fence = language
      }
      if let swap = attributes[swapKey] as? String {
        if let last = swapped, last.value == swap, last.end == range.location {
          swapped = (swap, NSMaxRange(range))
          return
        }
        out += swap
        swapped = (swap, NSMaxRange(range))
      } else {
        swapped = nil
        out += (text.string as NSString).substring(with: range)
          .replacingOccurrences(of: "\u{2028}", with: "\n")
      }
    }
    if fence != nil { out += out.hasSuffix("\n") ? "```" : "\n```" }
    return out
  }
}

/// What the text view draws behind its text, read off the marks the builder
/// left and the layout: a code block's box and what its copy button copies,
/// a table's rows and column edges, a quote's bars. TextKit 1's geometry,
/// which both platforms' text views share, in the view's own flipped
/// coordinates.
struct ProseDecorations {
  struct Box {
    let rect: CGRect
    let code: String
  }
  struct Grid {
    let rows: [CGRect]
    let columns: [CGFloat]
  }

  var boxes: [Box] = []
  var grids: [Grid] = []
  var bars: [CGRect] = []
  var rules: [CGRect] = []

  init() {}

  init(_ storage: NSTextStorage, layout: NSLayoutManager, container: NSTextContainer, origin: CGPoint)
  {
    let all = NSRange(location: 0, length: storage.length)
    guard all.length > 0 else { return }
    layout.ensureLayout(for: container)
    let width = container.size.width

    func used(_ range: NSRange) -> CGRect? {
      let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      var union: CGRect?
      layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
        union = union.map { $0.union(used) } ?? used
      }
      return union?.offsetBy(dx: origin.x, dy: origin.y)
    }

    storage.enumerateAttribute(boxKey, in: all) { value, range, _ in
      guard value != nil, let rect = used(range) else { return }
      let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
        as? NSParagraphStyle
      let left = max(0, (style?.headIndent ?? ProseBuilder.pad) - ProseBuilder.pad)
      var code = ""
      storage.enumerateAttribute(languageKey, in: range) { language, part, _ in
        if language != nil { code += (storage.string as NSString).substring(with: part) }
      }
      boxes.append(
        Box(
          rect: CGRect(
            x: origin.x + left, y: rect.minY - 8, width: width - left,
            height: rect.height + 8 + ProseBuilder.pad - 2),
          code: code))
    }

    storage.enumerateAttribute(tableKey, in: all) { value, range, _ in
      guard value != nil else { return }
      let edges = (storage.attribute(columnsKey, at: range.location, effectiveRange: nil)
        as? [NSNumber])?.map { CGFloat($0.doubleValue) + origin.x } ?? []
      var rows: [CGRect] = []
      storage.enumerateAttribute(rowKey, in: range) { row, part, _ in
        guard row != nil, let rect = used(part) else { return }
        rows.append(
          CGRect(
            x: edges.first ?? rect.minX, y: rect.minY - 6,
            width: (edges.last ?? rect.maxX) - (edges.first ?? rect.minX), height: rect.height + 12))
      }
      grids.append(Grid(rows: rows, columns: edges))
    }

    storage.enumerateAttribute(ruleKey, in: all) { value, range, _ in
      guard value != nil, let rect = used(range) else { return }
      rules.append(CGRect(x: origin.x, y: rect.midY.rounded(), width: width, height: 1))
    }

    storage.enumerateAttribute(quoteKey, in: all) { value, range, _ in
      guard let depth = value as? Int, let rect = used(range) else { return }
      for level in 0..<depth {
        bars.append(
          CGRect(x: origin.x + CGFloat(level) * 14 + 2, y: rect.minY, width: 3, height: rect.height))
      }
    }
  }

  /// Draws them in the current context, the platform's colours resolved
  /// for the view being drawn.
  func draw() {
    #if os(iOS)
      typealias Path = UIBezierPath
    #else
      typealias Path = NSBezierPath
    #endif
    PlatformColor.labelColor.withAlphaComponent(0.06).setFill()
    for box in boxes {
      rounded(box.rect, 10).fill()
    }
    for grid in grids {
      guard let top = grid.rows.first, let bottom = grid.rows.last else { continue }
      let frame = CGRect(
        x: top.minX, y: top.minY, width: top.width, height: bottom.maxY - top.minY)
      PlatformColor.labelColor.withAlphaComponent(0.04).setFill()
      Path(rect: top).fill()
      PlatformColor.separatorColor.setStroke()
      let lines = Path()
      lines.lineWidth = 1
      lines.append(Path(rect: frame.insetBy(dx: 0.5, dy: 0.5)))
      for row in grid.rows.dropFirst() {
        lines.move(to: CGPoint(x: frame.minX, y: row.minY))
        stroke(lines, to: CGPoint(x: frame.maxX, y: row.minY))
      }
      for x in grid.columns.dropFirst().dropLast() {
        lines.move(to: CGPoint(x: x, y: frame.minY))
        stroke(lines, to: CGPoint(x: x, y: frame.maxY))
      }
      lines.stroke()
    }
    PlatformColor.tertiaryLabelColor.setFill()
    for bar in bars {
      rounded(bar, 1.5).fill()
    }
    PlatformColor.separatorColor.setFill()
    for rule in rules {
      Path(rect: rule).fill()
    }
  }
}

#if os(iOS)
  private func stroke(_ path: UIBezierPath, to point: CGPoint) { path.addLine(to: point) }
  private func rounded(_ rect: CGRect, _ radius: CGFloat) -> UIBezierPath {
    UIBezierPath(roundedRect: rect, cornerRadius: radius)
  }
#else
  private func stroke(_ path: NSBezierPath, to point: CGPoint) { path.line(to: point) }
  private func rounded(_ rect: CGRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
  }
#endif

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
    static var tertiaryLabelColor: UIColor { .tertiaryLabel }
    static var separatorColor: UIColor { .separator }
    static var accent: UIColor { .tintColor }
  }
#else
  extension NSColor {
    static var accent: NSColor { .controlAccentColor }
  }
#endif

/// The copy button at a code box's top right, as the Flutter code block has.
private let copySymbol = "doc.on.doc"

#if os(macOS)
  /// Prose in a text view of AppKit's own, selectable, sized to its text,
  /// drawing what the builder marked behind it, with the app's menu: Copy
  /// and Reply in place of the system's spelling, fonts and services.
  struct ProseText: NSViewRepresentable {
    let text: NSAttributedString
    let actions: ProseActions
    var hugs = false

    func makeNSView(context: Context) -> ProseTextView {
      let view = ProseTextView(usingTextLayoutManager: false)
      view.isEditable = false
      view.isSelectable = true
      view.drawsBackground = false
      view.textContainerInset = .zero
      view.textContainer?.lineFragmentPadding = 0
      view.textContainer?.widthTracksTextView = true
      view.isVerticallyResizable = false
      view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
      view.delegate = context.coordinator
      return view
    }

    func updateNSView(_ view: ProseTextView, context: Context) {
      view.actions = actions
      context.coordinator.actions = actions
      if view.textStorage?.isEqual(to: text) != true {
        view.textStorage?.setAttributedString(text)
        view.decorate()
      }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ProseTextView, context: Context)
      -> CGSize?
    {
      let width = proposal.width ?? 600
      guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
      container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
      layout.ensureLayout(for: container)
      let used = layout.usedRect(for: container)
      return CGSize(width: hugs ? min(width, ceil(used.width)) : width, height: ceil(used.height))
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
    private var decorations = ProseDecorations()
    private var buttons: [NSButton] = []

    override func setFrameSize(_ size: NSSize) {
      super.setFrameSize(size)
      decorate()
    }

    /// Reads the decorations off the layout again, and puts a copy button
    /// on each box.
    func decorate() {
      guard let storage = textStorage, let layout = layoutManager, let container = textContainer
      else { return }
      decorations = ProseDecorations(
        storage, layout: layout, container: container, origin: textContainerOrigin)
      while buttons.count < decorations.boxes.count {
        let button = NSButton(
          image: NSImage(systemSymbolName: copySymbol, accessibilityDescription: "Copy code")!,
          target: self, action: #selector(copyCode(_:)))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Copy code"
        addSubview(button)
        buttons.append(button)
      }
      for (index, button) in buttons.enumerated() {
        button.isHidden = index >= decorations.boxes.count
        button.tag = index
        guard index < decorations.boxes.count else { continue }
        let box = decorations.boxes[index].rect
        button.frame = CGRect(x: box.maxX - 30, y: box.minY + 4, width: 24, height: 22)
      }
      needsDisplay = true
    }

    @objc private func copyCode(_ sender: NSButton) {
      guard sender.tag < decorations.boxes.count else { return }
      copyToPasteboard(decorations.boxes[sender.tag].code)
    }

    override func drawBackground(in rect: NSRect) {
      super.drawBackground(in: rect)
      decorations.draw()
    }

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
      reply.image = NSImage(
        systemSymbolName: "arrowshape.turn.up.left", accessibilityDescription: nil)
      menu.items = actions?.reply == nil ? [copy] : [copy, reply]
      return menu
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
      if item.action == #selector(copy(_:)) || item.action == #selector(replyToSelection) {
        return selected != nil
      }
      return super.validateMenuItem(item)
    }

    /// As a reader would paste it: a picture's character pastes as nothing.
    override func copy(_ sender: Any?) {
      guard let selected else { return }
      copyToPasteboard(ProseBuilder.plain(selected))
    }

    @objc func replyToSelection() {
      guard let selected else { return }
      actions?.reply?(ProseBuilder.plain(selected))
      setSelectedRange(NSRange(location: 0, length: 0))
    }
  }
#else
  /// Prose in UIKit's text view, selectable, sized to its text, drawing what
  /// the builder marked behind it, its edit menu the app's: Copy and Reply
  /// in place of the system's look-up and translate.
  struct ProseText: UIViewRepresentable {
    let text: NSAttributedString
    let actions: ProseActions
    var hugs = false

    func makeUIView(context: Context) -> ProseUITextView {
      let view = ProseUITextView()
      view.isEditable = false
      view.isSelectable = true
      view.isScrollEnabled = false
      view.backgroundColor = .clear
      view.contentMode = .redraw
      view.textContainerInset = .zero
      view.textContainer.lineFragmentPadding = 0
      view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      view.delegate = context.coordinator
      return view
    }

    func updateUIView(_ view: ProseUITextView, context: Context) {
      context.coordinator.actions = actions
      if !view.attributedText.isEqual(to: text) {
        view.attributedText = text
        view.setNeedsLayout()
      }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: ProseUITextView, context: Context)
      -> CGSize?
    {
      let width = proposal.width ?? 320
      let size = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
      var used = width
      if hugs {
        view.textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        view.layoutManager.ensureLayout(for: view.textContainer)
        used = min(width, ceil(view.layoutManager.usedRect(for: view.textContainer).width))
      }
      return CGSize(width: used, height: ceil(size.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(actions: actions) }

    final class Coordinator: NSObject, UITextViewDelegate {
      var actions: ProseActions
      init(actions: ProseActions) { self.actions = actions }

      func textView(
        _ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction
      ) -> UIAction? {
        guard case .link(let url) = textItem.content else { return defaultAction }
        return UIAction { [actions] _ in actions.link(url) }
      }

      func textView(
        _ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]
      ) -> UIMenu? {
        guard range.length > 0 else { return nil }
        let plain = ProseBuilder.plain(textView.attributedText.attributedSubstring(from: range))
        var children: [UIMenuElement] = [
          UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
            copyToPasteboard(plain)
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

  /// On TextKit 1, which the decorations measure with.
  final class ProseUITextView: TextKit1View {
    private var decorations = ProseDecorations()
    private var buttons: [UIButton] = []

    override func layoutSubviews() {
      super.layoutSubviews()
      decorations = ProseDecorations(
        textStorage, layout: layoutManager, container: textContainer,
        origin: CGPoint(x: textContainerInset.left, y: textContainerInset.top))
      while buttons.count < decorations.boxes.count {
        let index = buttons.count
        let button = UIButton(
          type: .system,
          primaryAction: UIAction(image: UIImage(systemName: copySymbol)) { [weak self] _ in
            guard let self, index < self.decorations.boxes.count else { return }
            copyToPasteboard(self.decorations.boxes[index].code)
          })
        button.tintColor = .secondaryLabel
        button.accessibilityLabel = "Copy code"
        addSubview(button)
        buttons.append(button)
      }
      for (index, button) in buttons.enumerated() {
        button.isHidden = index >= decorations.boxes.count
        guard index < decorations.boxes.count else { continue }
        let box = decorations.boxes[index].rect
        button.frame = CGRect(x: box.maxX - 36, y: box.minY + 2, width: 32, height: 28)
      }
      setNeedsDisplay()
    }

    /// Behind the text, which UIKit draws in a view of its own above this.
    override func draw(_ rect: CGRect) {
      decorations.draw()
    }
  }
#endif
