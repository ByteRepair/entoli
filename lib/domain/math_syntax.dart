/// TeX in a reply: the delimiters models write it in, read into the markdown
/// tree as elements of their own so that nothing inside them is taken for
/// emphasis, an escape or a line break. Here rather than beside the renderer
/// because the copy reads the same tree: `$a_b_c$` copied is still that, not
/// `$abc$` with the underscores eaten as italics.
library;

import "package:markdown/markdown.dart" as md;

/// A formula set in the text's line, `$…$` or `\(…\)`.
const mathInlineTag = "math-inline";

/// A formula set on a line of its own, `$$…$$` or `\[…\]`.
const mathDisplayTag = "math-display";

/// The element's only child is the source as it was written, delimiters and
/// all, so whatever reads text out of the tree — the copy — reads that; the
/// TeX alone is this attribute.
const mathTexAttribute = "tex";

const mathTags = {mathInlineTag, mathDisplayTag};

/// Set on a display formula that is a paragraph to itself, which is drawn
/// across the column; one written mid-sentence stays in the sentence.
const mathBlockAttribute = "block";

/// What a document is parsed with, ahead of GitHub's extensions, wherever the
/// markdown of a reply is read — `replyExtensionSet` is the one place that
/// puts the two together.
final mathBlockSyntaxes = <md.BlockSyntax>[const _DisplayMathBlockSyntax()];
final mathInlineSyntaxes = <md.InlineSyntax>[
  _MathSyntax(r"\$\$([\s\S]+?)\$\$", startCharacter: _dollar, display: true),
  _MathSyntax(r"\\\[([\s\S]+?)\\\]", startCharacter: _backslash, display: true),
  _MathSyntax(
    r"\\\(([\s\S]+?)\\\)",
    startCharacter: _backslash,
    display: false,
  ),
  // Pandoc's rule, which is what keeps money from being maths: the opening
  // `$` is followed by something other than a space, the closing one is
  // preceded by one and not followed by a digit — so "$5 and $10" is prose.
  // One line only, since a stray `$` would otherwise reach down the reply.
  _MathSyntax(
    r"\$(?![\s$])((?:\\.|[^\\$\n])+?)(?<!\s)\$(?!\d)",
    startCharacter: _dollar,
    display: false,
  ),
];

const _dollar = 0x24;
const _backslash = 0x5C;

md.Element _element(String source, String tex, {required bool display}) =>
    md.Element(display ? mathDisplayTag : mathInlineTag, [md.Text(source)])
      ..attributes[mathTexAttribute] = tex.trim();

class _MathSyntax extends md.InlineSyntax {
  /// The character a rule opens on is named, which is what lets the parser
  /// skip the regex at every other character of every paragraph.
  _MathSyntax(
    super.pattern, {
    required super.startCharacter,
    required this.display,
  });

  final bool display;

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(_element(match[0]!, match[1]!, display: display));
    return true;
  }
}

/// `$$` or `\[` opening a line, through the line that closes it. A block
/// rather than only the inline rule, because a formula spread over lines is
/// otherwise read as markdown first: a line of it starting `- ` is a list, and
/// one indented four spaces is code.
class _DisplayMathBlockSyntax extends md.BlockSyntax {
  const _DisplayMathBlockSyntax();

  static final _open = RegExp(r"^ {0,3}(\$\$|\\\[)(.*)$");

  static String _closeOf(Match open) => open[1] == r"$$" ? r"$$" : r"\]";

  @override
  RegExp get pattern => _open;

  @override
  bool canParse(md.BlockParser parser) {
    final match = _open.firstMatch(parser.current.content);
    if (match == null) return false;
    // A line that closes the formula and then goes on is a sentence with a
    // formula in it, which the inline rule sets.
    final close = _closeOf(match);
    final rest = match[2]!;
    final end = rest.indexOf(close);
    return end == -1 || rest.substring(end + close.length).trim().isEmpty;
  }

  @override
  bool canEndBlock(md.BlockParser parser) => true;

  @override
  md.Node? parse(md.BlockParser parser) {
    final first = parser.current.content;
    final match = _open.firstMatch(first)!;
    final close = _closeOf(match);
    // Where the TeX starts, in the first line and so in the whole source.
    final texStart = first.length - match[2]!.length;
    final lines = <String>[];
    var from = texStart;
    while (!parser.isDone) {
      final line = parser.current.content;
      lines.add(line);
      parser.advance();
      if (line.contains(close, from)) break;
      from = 0;
    }
    final source = lines.join("\n");
    final end = source.indexOf(close, texStart);
    // Never closed: the formula is the rest of the reply, which is what a
    // reply cut off mid-formula is.
    final tex = source.substring(texStart, end == -1 ? null : end);
    return md.Element("p", [
      _element(source.trim(), tex, display: true)
        ..attributes[mathBlockAttribute] = "true",
    ]);
  }
}
