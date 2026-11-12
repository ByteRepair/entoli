import SwiftUI

/// A reply's markdown as the core parsed it: blocks one under another, each
/// indented for the list items and quotes it sits in. A link goes to Dart
/// through the environment's `openURL`, which the conversation sets.
struct MarkdownView: View {
  let blocks: [TextBlockSnapshot]
  let model: TranscriptModel
  var caret = false
  var tone: Color? = nil
  /// Answers a selected passage; null where there is nothing to answer.
  var reply: ((String) -> Void)? = nil

  /// Prose as runs, one text view each so a selection crosses paragraphs,
  /// broken where a code block or a table stands apart.
  private var runs: [(index: Int, prose: Bool, blocks: [TextBlockSnapshot])] {
    var out: [(Int, Bool, [TextBlockSnapshot])] = []
    for (index, block) in blocks.enumerated() {
      let prose = block.kind != .code && block.kind != .table
      if prose, let last = out.last, last.1 {
        out[out.count - 1].2.append(block)
      } else {
        out.append((index, prose, [block]))
      }
    }
    return out
  }

  var body: some View {
    let _ = model.formulasLanded
    VStack(alignment: .leading, spacing: 8) {
      ForEach(runs, id: \.index) { run in
        if run.prose {
          ProseText(
            text: ProseBuilder.build(
              run.blocks, model: model, caret: caret && run.index + run.blocks.count == blocks.count,
              tone: tone.map { PlatformColor($0) }),
            actions: ProseActions(reply: reply, link: { model.link($0.absoluteString) }))
        } else {
          TextBlockView(block: run.blocks[0], model: model, caret: false, tone: tone)
        }
      }
    }
  }
}

private struct TextBlockView: View {
  let block: TextBlockSnapshot
  let model: TranscriptModel
  let caret: Bool
  let tone: Color?

  /// A list's indent, the marker's column.
  private static let indent: CGFloat = 22

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      ForEach(0..<Int(block.quotes), id: \.self) { _ in
        Rectangle().fill(.quaternary).frame(width: 3).padding(.trailing, 9)
      }
      ForEach(Array(block.items.enumerated()), id: \.offset) { index, marker in
        let shown = index == block.items.count - 1 && marker.first
        Group {
          if shown { Self.marker(marker) } else { Color.clear }
        }
        .frame(width: Self.indent, alignment: .leading)
      }
      content.frame(maxWidth: .infinity, alignment: .leading)
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private static func marker(_ marker: MarkerSnapshot) -> some View {
    if let checked = marker.checked {
      Image(systemName: checked ? "checkmark.square" : "square").foregroundStyle(.secondary)
    } else {
      Text(marker.ordered ? "\(marker.number)." : "•").foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var content: some View {
    switch block.kind {
    case .paragraph:
      InlineText.of(block.inlines, model: model, caret: caret)
        .foregroundStyle(tone ?? .primary)
        .textSelection(.enabled)
    case .heading:
      InlineText.of(block.inlines, model: model, caret: caret)
        .font(Self.headingFont(block.level))
        .padding(.top, 6)
        .textSelection(.enabled)
    case .code:
      CodeBlockView(code: block.code, language: block.language, tokens: block.tokens)
    case .formula:
      FormulaView(block: block, model: model)
    case .rule:
      Divider().padding(.vertical, 4)
    case .table:
      TableBlockView(block: block, model: model)
    }
  }

  private static func headingFont(_ level: Int64) -> Font {
    switch level {
    case 1: .title2.weight(.semibold)
    case 2: .title3.weight(.semibold)
    case 3: .headline
    default: .body.weight(.semibold)
    }
  }
}

/// Inline runs as one `Text`, so a sentence wraps as one: marks as the
/// attributed string's, a formula as its picture set on the baseline.
enum InlineText {
  static func of(_ inlines: [InlineSnapshot], model: TranscriptModel, caret: Bool = false) -> Text
  {
    // Read so a row waiting on a picture redraws when it lands.
    _ = model.formulasLanded
    var text = Text("")
    for inline in inlines {
      text = text + piece(inline, model: model)
    }
    if caret { text = text + Text(" ▍").foregroundStyle(.tint) }
    return text
  }

  private static func piece(_ inline: InlineSnapshot, model: TranscriptModel) -> Text {
    switch inline.kind {
    case .text:
      var run = AttributedString(inline.text)
      if inline.code {
        run.font = .system(.callout, design: .monospaced)
        run.backgroundColor = Color.secondary.opacity(0.15)
      }
      if let link = inline.link, let url = URL(string: link) {
        run.link = url
      }
      var text = Text(run)
      if inline.bold { text = text.bold() }
      if inline.italic { text = text.italic() }
      if inline.strike { text = text.strikethrough() }
      return text
    case .formula:
      if let id = inline.formula, let formula = model.formulas[id] {
        return Text(formula.image).baselineOffset(-(formula.size.height - formula.baseline))
      }
      return Text(inline.text).font(.system(.body, design: .monospaced))
    case .lineBreak:
      return Text("\n")
    case .image:
      return Text(inline.text).italic().foregroundStyle(.secondary)
    }
  }
}

/// A display formula, its picture centred; the TeX where it is not drawn yet.
private struct FormulaView: View {
  let block: TextBlockSnapshot
  let model: TranscriptModel

  var body: some View {
    let _ = model.formulasLanded
    ScrollView(.horizontal, showsIndicators: false) {
      if let id = block.formula, let formula = model.formulas[id] {
        formula.image
          .accessibilityLabel(block.written)
          .padding(.vertical, 4)
      } else {
        Text(block.written).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity)
  }
}

/// A fenced block: what it was fenced as, a copy button, and the code
/// coloured by its tokens' scopes, scrolling sideways rather than wrapping.
struct CodeBlockView: View {
  let code: String
  let language: String?
  let tokens: [CodeTokenSnapshot]
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(language ?? "").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button {
          Pasteboard.copy(code)
        } label: {
          Image(systemName: "doc.on.doc").font(.caption)
        }
        .buttonStyle(.borderless)
        .help("Copy code")
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      ScrollView(.horizontal) {
        coloured
          .font(.system(size: 13, design: .monospaced))
          .textSelection(.enabled)
          .padding(.horizontal, 10)
          .padding(.bottom, 10)
      }
    }
    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
  }

  private var coloured: Text {
    if tokens.isEmpty { return Text(code) }
    var all = AttributedString()
    for token in tokens {
      var run = AttributedString(token.text)
      if let scope = token.scope, let colour = CodeColours.of(scope, dark: scheme == .dark) {
        run.foregroundColor = colour
      }
      all.append(run)
    }
    return Text(all)
  }
}

/// GitHub's token colours, light and dark, by a scope's first part.
enum CodeColours {
  static func of(_ scope: String, dark: Bool) -> Color? {
    let root = scope.split(separator: ".").first.map(String.init) ?? scope
    let hex: (UInt32, UInt32)? =
      switch root {
      case "keyword", "selector-tag", "doctag", "template-tag": (0xCF222E, 0xFF7B72)
      case "string", "regexp", "meta-string", "char": (0x0A3069, 0xA5D6FF)
      case "comment", "quote": (0x6E7781, 0x8B949E)
      case "number", "literal", "variable", "attr", "attribute", "symbol", "meta", "operator":
        (0x0550AE, 0x79C0FF)
      case "title", "section": (0x8250DF, 0xD2A8FF)
      case "built_in", "type", "class", "params": (0x953800, 0xFFA657)
      case "name", "tag", "selector-id", "selector-class", "addition": (0x116329, 0x7EE787)
      case "deletion": (0x82071E, 0xFFDCD7)
      default: nil
      }
    guard let hex else { return nil }
    let value = dark ? hex.1 : hex.0
    return Color(
      red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255)
  }
}

private struct TableBlockView: View {
  let block: TextBlockSnapshot
  let model: TranscriptModel

  var body: some View {
    let rows = Dictionary(grouping: block.cells, by: \.row).sorted { $0.key < $1.key }
    ScrollView(.horizontal) {
      Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
        ForEach(rows, id: \.key) { _, cells in
          GridRow {
            ForEach(cells.sorted { $0.column < $1.column }, id: \.column) { cell in
              InlineText.of(cell.inlines, model: model)
                .fontWeight(cell.header ? .semibold : nil)
                .frame(maxWidth: .infinity, alignment: alignment(of: cell))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .border(.quaternary)
            }
          }
        }
      }
      .textSelection(.enabled)
    }
  }

  private func alignment(of cell: CellSnapshot) -> Alignment {
    let index = Int(cell.column)
    guard index < block.align.count else { return .leading }
    switch block.align[index] {
    case .start: return .leading
    case .center: return .center
    case .end: return .trailing
    }
  }
}
