import "package:markdown/markdown.dart" as md;

import "../../domain/formatted_text.dart" show parseReply;
import "../../domain/math_syntax.dart";

/// A reply's markdown as a frontend draws it: a flat list of blocks, each
/// carrying where it is nested — inside which quotes and list items — rather
/// than a tree, so a frontend lays them out in one pass and a wire has no
/// recursive type to carry. Read with the reply's grammar (`parseReply`), the
/// one the copy and the Flutter renderer read, so the three agree about what
/// a fence or a formula is.
class MarkdownDocument {
  const MarkdownDocument(this.blocks);

  factory MarkdownDocument.parse(String markdown) =>
      MarkdownDocument(_BlockReader().read(parseReply(markdown)));

  static const empty = MarkdownDocument([]);

  final List<MarkdownBlock> blocks;

  /// Every formula in it, by its TeX as written, once each: a block on a
  /// line of its own, or one inside a sentence or a table's cell.
  Map<String, ({String tex, bool display})> get formulas {
    final found = <String, ({String tex, bool display})>{};
    void inline(List<Inline> inlines) {
      for (final i in inlines) {
        if (i is FormulaInline) {
          found[i.written] = (tex: i.tex, display: i.display);
        }
      }
    }

    for (final block in blocks) {
      switch (block) {
        case FormulaBlock(:final tex, :final written):
          found[written] = (tex: tex, display: true);
        case ParagraphBlock(:final inlines) || HeadingBlock(:final inlines):
          inline(inlines);
        case TableBlock(:final header, :final rows):
          [...header, ...rows.expand((r) => r)].forEach(inline);
        case _:
      }
    }
    return found;
  }
}

/// Where a block sits: [quotes] block quotes deep, inside the list items of
/// [items], outermost first.
class BlockNesting {
  const BlockNesting({this.quotes = 0, this.items = const []});

  static const top = BlockNesting();

  final int quotes;
  final List<ListMarker> items;

  BlockNesting quoted() => BlockNesting(quotes: quotes + 1, items: items);

  BlockNesting inItem(ListMarker marker) =>
      BlockNesting(quotes: quotes, items: [...items, marker]);
}

/// The list item a block is in. [first] is the item's first block, the one
/// that wears the bullet; the blocks after it sit under the same indent with
/// none.
class ListMarker {
  const ListMarker({
    required this.ordered,
    required this.number,
    required this.first,
    this.checked,
  });

  final bool ordered;
  final int number;
  final bool first;

  /// A task item's box, ticked or not; null on an ordinary item.
  final bool? checked;

  ListMarker get continued =>
      ListMarker(ordered: ordered, number: number, first: false, checked: null);
}

sealed class MarkdownBlock {
  const MarkdownBlock(this.nesting);

  final BlockNesting nesting;
}

final class ParagraphBlock extends MarkdownBlock {
  const ParagraphBlock(super.nesting, this.inlines);

  final List<Inline> inlines;
}

final class HeadingBlock extends MarkdownBlock {
  const HeadingBlock(super.nesting, this.level, this.inlines);

  final int level;
  final List<Inline> inlines;
}

/// A fenced or indented block of code, [language] as the fence named it.
final class CodeBlock extends MarkdownBlock {
  const CodeBlock(super.nesting, this.code, {this.language});

  final String code;
  final String? language;
}

/// A display formula, `$$…$$` or `\[…\]`: [written] with its delimiters, as
/// a copy has it, and [tex] as it is typeset.
final class FormulaBlock extends MarkdownBlock {
  const FormulaBlock(super.nesting, {required this.tex, required this.written});

  final String tex;
  final String written;
}

final class RuleBlock extends MarkdownBlock {
  const RuleBlock(super.nesting);
}

enum CellAlign { start, center, end }

final class TableBlock extends MarkdownBlock {
  const TableBlock(
    super.nesting, {
    required this.header,
    required this.rows,
    required this.align,
  });

  final List<List<Inline>> header;
  final List<List<List<Inline>>> rows;
  final List<CellAlign> align;
}

/// What a run of text is marked as.
enum InlineMark { bold, italic, code, strike }

sealed class Inline {
  const Inline();
}

/// Words, with their marks and the link they are part of.
final class TextInline extends Inline {
  const TextInline(this.text, {this.marks = const {}, this.link});

  final String text;
  final Set<InlineMark> marks;
  final String? link;
}

/// A formula inside a sentence.
final class FormulaInline extends Inline {
  const FormulaInline({
    required this.tex,
    required this.written,
    this.display = false,
  });

  final String tex;
  final String written;

  /// Written `$$…$$` mid-sentence: set at display size, still in the line.
  final bool display;
}

final class BreakInline extends Inline {
  const BreakInline();
}

final class ImageInline extends Inline {
  const ImageInline({required this.source, required this.alt});

  final String source;
  final String alt;
}

/// The markdown package's tree, walked into [MarkdownBlock]s.
class _BlockReader {
  final _out = <MarkdownBlock>[];

  List<MarkdownBlock> read(List<md.Node> nodes) {
    _blocks(nodes, BlockNesting.top);
    return _out;
  }

  void _blocks(List<md.Node> nodes, BlockNesting at) {
    // Loose text at block level — a tight list item's words — is a paragraph.
    final loose = <md.Node>[];
    void flush() {
      if (loose.isEmpty) return;
      final inlines = _InlineReader().read(loose);
      loose.clear();
      if (inlines.isEmpty) return;
      _out.add(ParagraphBlock(at, inlines));
      at = _after(at);
    }

    for (final node in nodes) {
      if (node is md.Element && _blockTags.contains(node.tag)) {
        flush();
        final before = _out.length;
        _block(node, at);
        if (_out.length > before) at = _after(at);
      } else {
        loose.add(node);
      }
    }
    flush();
  }

  /// The first block of a list item wears its marker; every block after it
  /// in the same item is a continuation.
  BlockNesting _after(BlockNesting at) {
    if (at.items.isEmpty || !at.items.last.first) return at;
    return BlockNesting(
      quotes: at.quotes,
      items: [...at.items.take(at.items.length - 1), at.items.last.continued],
    );
  }

  void _block(md.Element e, BlockNesting at) {
    final children = e.children ?? const <md.Node>[];
    switch (e.tag) {
      // The grammar sets a formula on a line of its own as a paragraph
      // holding nothing but it.
      case "p"
          when children.length == 1 &&
              children.single is md.Element &&
              (children.single as md.Element).tag == mathDisplayTag:
        _block(children.single as md.Element, at);
      case "p":
        final inlines = _InlineReader().read(children);
        if (inlines.isNotEmpty) _out.add(ParagraphBlock(at, inlines));
      case "h1" || "h2" || "h3" || "h4" || "h5" || "h6":
        _out.add(
          HeadingBlock(
            at,
            int.parse(e.tag.substring(1)),
            _InlineReader().read(children),
          ),
        );
      case "pre":
        final code = children.whereType<md.Element>().firstOrNull;
        final cls = code?.attributes["class"];
        _out.add(
          CodeBlock(
            at,
            _trimFinalNewline(code?.textContent ?? e.textContent),
            language: cls != null && cls.startsWith("language-")
                ? cls.substring("language-".length)
                : null,
          ),
        );
      case mathDisplayTag:
        _out.add(
          FormulaBlock(
            at,
            tex: e.attributes[mathTexAttribute] ?? e.textContent,
            written: e.textContent,
          ),
        );
      case "hr":
        _out.add(RuleBlock(at));
      case "blockquote":
        _blocks(children, at.quoted());
      case "ul" || "ol":
        final ordered = e.tag == "ol";
        var number = int.tryParse(e.attributes["start"] ?? "") ?? 1;
        for (final item in children.whereType<md.Element>()) {
          final box = _taskBox(item);
          _blocks(
            item.children ?? const [],
            at.inItem(
              ListMarker(
                ordered: ordered,
                number: number++,
                first: true,
                checked: box,
              ),
            ),
          );
        }
      case "table":
        _out.add(_table(e, at));
      default:
        _blocks(children, at);
    }
  }

  /// GitHub's task item: a disabled checkbox heading the item, which is
  /// taken out of it and said as the marker's box.
  bool? _taskBox(md.Element item) {
    final kids = item.children;
    if (kids == null || kids.isEmpty) return null;
    md.Node? first = kids.first;
    List<md.Node>? owner = kids;
    if (first is md.Element && first.tag == "p") {
      owner = first.children;
      first = owner?.firstOrNull;
    }
    if (first is md.Element &&
        first.tag == "input" &&
        first.attributes["type"] == "checkbox") {
      owner!.removeAt(0);
      return first.attributes.containsKey("checked");
    }
    return null;
  }

  TableBlock _table(md.Element e, BlockNesting at) {
    final header = <List<Inline>>[];
    final rows = <List<List<Inline>>>[];
    final align = <CellAlign>[];
    for (final section in e.children!.whereType<md.Element>()) {
      for (final row in section.children!.whereType<md.Element>()) {
        final cells = <List<Inline>>[];
        for (final cell in row.children!.whereType<md.Element>()) {
          cells.add(_InlineReader().read(cell.children ?? const []));
          if (section.tag == "thead") {
            align.add(switch (cell.attributes["align"]) {
              "center" => CellAlign.center,
              "right" => CellAlign.end,
              _ => CellAlign.start,
            });
          }
        }
        section.tag == "thead" ? header.addAll(cells) : rows.add(cells);
      }
    }
    return TableBlock(at, header: header, rows: rows, align: align);
  }

  static String _trimFinalNewline(String code) =>
      code.endsWith("\n") ? code.substring(0, code.length - 1) : code;

  static const _blockTags = {
    "p",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "pre",
    "hr",
    "blockquote",
    "ul",
    "ol",
    "table",
    mathDisplayTag,
  };
}

/// Inline nodes walked into runs, marks carried down from the elements they
/// sit in and adjacent runs of the same marks joined.
class _InlineReader {
  final _out = <Inline>[];

  List<Inline> read(List<md.Node> nodes) {
    for (final node in nodes) {
      _node(node, const {}, null);
    }
    return _out;
  }

  void _node(md.Node node, Set<InlineMark> marks, String? link) {
    switch (node) {
      case md.Text(:final text):
        _text(text, marks, link);
      case md.Element(tag: mathInlineTag || mathDisplayTag):
        _out.add(
          FormulaInline(
            tex: node.attributes[mathTexAttribute] ?? node.textContent,
            written: node.textContent,
            display: node.tag == mathDisplayTag,
          ),
        );
      case md.Element(tag: "br"):
        _out.add(const BreakInline());
      case md.Element(tag: "img"):
        _out.add(
          ImageInline(
            source: node.attributes["src"] ?? "",
            alt: node.attributes["alt"] ?? "",
          ),
        );
      case md.Element(tag: "code"):
        _text(node.textContent, {...marks, InlineMark.code}, link);
      case md.Element():
        final mark = switch (node.tag) {
          "strong" => InlineMark.bold,
          "em" => InlineMark.italic,
          "del" => InlineMark.strike,
          _ => null,
        };
        final inner = mark == null ? marks : {...marks, mark};
        final href = node.tag == "a" ? node.attributes["href"] : link;
        for (final child in node.children ?? const <md.Node>[]) {
          _node(child, inner, href);
        }
    }
  }

  void _text(String text, Set<InlineMark> marks, String? link) {
    if (text.isEmpty) return;
    final last = _out.lastOrNull;
    if (last is TextInline &&
        last.link == link &&
        last.marks.length == marks.length &&
        last.marks.containsAll(marks)) {
      _out[_out.length - 1] = TextInline(
        last.text + text,
        marks: marks,
        link: link,
      );
      return;
    }
    _out.add(TextInline(text, marks: marks, link: link));
  }
}
