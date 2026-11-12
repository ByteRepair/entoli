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
  /// As wide as its words rather than the whole width offered: in a bubble.
  var hugs = false
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let _ = model.formulasLanded
    ProseText(
      text: ProseBuilder.build(
        blocks, model: model, caret: caret, tone: tone.map { PlatformColor($0) },
        dark: scheme == .dark),
      actions: ProseActions(reply: reply, link: { model.link($0.absoluteString) }),
      hugs: hugs)
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
