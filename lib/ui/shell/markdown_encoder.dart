import "package:entoli_glass/entoli_glass.dart" as wire;

import "../../app/transcript/code.dart";
import "../../app/transcript/formula.dart";
import "../../app/transcript/markdown.dart";

/// The formulas a conversation shows, each under an id of its own and sent
/// once: a row carries the id, and the client keeps the picture. What is not
/// typeset yet is asked for, and [onReady] is told when it lands, so the row
/// is sent again with the picture to hand.
class FormulaSheet {
  FormulaSheet(this._renderer, {required this.argb, required this.onReady});

  final CachedFormulaRenderer _renderer;
  final void Function() onReady;

  /// The ink the theme draws text in; a change of theme is a new sheet.
  final int argb;

  /// Ids are the process's, not the sheet's: a client keeps every picture
  /// it is sent, whichever sheet sent it.
  static var _next = 0;

  final _ids = <(String, bool), int>{};
  final _sent = <int>{};

  /// How many times [idOf] has answered null: a parse that moved it has a
  /// formula still to land.
  int misses = 0;

  /// Asked of the renderer and not landed yet, or failed: not asked again.
  final _asked = <int>{};
  final _unsent = <wire.FormulaPicture>[];

  FormulaStyle _style(bool display) => FormulaStyle(
    display: display,
    fontSize: display ? 18 : 16,
    argb: argb,
    scale: 3,
  );

  /// [tex]'s id, null until its picture exists.
  int? idOf(String tex, {required bool display}) {
    final key = (tex, display);
    final id = _ids[key] ??= ++_next;
    if (_sent.contains(id)) return id;
    final style = _style(display);
    final ready = _renderer.ready(tex, style);
    if (ready == null) {
      misses++;
      if (_asked.add(id)) {
        _renderer.render(tex, style).then((_) {
          _asked.remove(id);
          onReady();
        }, onError: (_) {});
      }
      return null;
    }
    _sent.add(id);
    _unsent.add(
      wire.FormulaPicture(
        id: id,
        png: ready.png,
        scale: style.scale,
        width: ready.width,
        height: ready.height,
        baseline: ready.baseline,
      ),
    );
    return id;
  }

  /// Every formula in [markdown] typeset, so that encoding it after has all
  /// their ids. One that cannot be typeset is drawn as its TeX.
  Future<void> typeset(String markdown) => Future.wait([
    for (final (:tex, :display) in MarkdownDocument.parse(
      markdown,
    ).formulas.values)
      Future.sync(
        () => _renderer.render(tex, _style(display)),
      ).then((_) {}, onError: (_) {}),
  ]);

  /// The pictures made since the last call, for the client to keep.
  List<wire.FormulaPicture> take() {
    final out = _unsent.toList();
    _unsent.clear();
    return out;
  }
}

/// Markdown's wire blocks by text, as the last pass and this one used them,
/// so what a pass no longer shows is let go. A formula landing changes only
/// the blocks still waiting on one, which [landed] drops.
class MarkdownBlocks {
  var _last = <String, List<wire.TextBlockSnapshot>>{};
  var _now = <String, List<wire.TextBlockSnapshot>>{};
  final _pending = <String>{};

  /// [text]'s blocks, [parse]d where not kept; [parse] says whether a
  /// formula in it is still to land.
  List<wire.TextBlockSnapshot> of(
    String text,
    (List<wire.TextBlockSnapshot>, bool pending) Function() parse,
  ) {
    final kept = _now[text] ?? _last[text];
    if (kept != null) return _now[text] = kept;
    final (blocks, pending) = parse();
    if (pending) _pending.add(text);
    return _now[text] = blocks;
  }

  /// Ends a pass: what it did not use goes at the end of the next.
  void turn() {
    _last = _now;
    _now = {};
    _pending.retainWhere(_last.containsKey);
  }

  /// A formula landed: the texts waiting on one are parsed again.
  void landed() {
    for (final text in _pending) {
      _last.remove(text);
      _now.remove(text);
    }
    _pending.clear();
  }

  void clear() {
    _last = {};
    _now = {};
    _pending.clear();
  }
}

/// The colour text is drawn in natively, which a formula is typeset in.
int inkOf({required bool dark}) => dark ? 0xFFE3E2E6 : 0xFF1A1C1E;

/// The core's markdown in the wire's terms, as the native client draws it
/// wherever markdown is shown: a reply, a summary, a document. Parsed blocks
/// are kept across passes in [parsed], so what did not change is not parsed
/// or highlighted again.
class MarkdownEncoder {
  MarkdownEncoder({
    required this.formulas,
    required this.highlighter,
    MarkdownBlocks? parsed,
  }) : _parsed = parsed ?? MarkdownBlocks();

  final FormulaSheet formulas;
  final CodeHighlighter highlighter;
  final MarkdownBlocks _parsed;

  /// Markdown as blocks, its code tokenised and its formulas by id.
  List<wire.TextBlockSnapshot> markdown(String text) => _parsed.of(text, () {
    final misses = formulas.misses;
    final blocks = [
      for (final block in MarkdownDocument.parse(text).blocks) _text(block),
    ];
    return (blocks, formulas.misses != misses);
  });

  wire.TextBlockSnapshot _text(MarkdownBlock block) {
    final nesting = block.nesting;
    final items = [
      for (final m in nesting.items)
        wire.MarkerSnapshot(
          ordered: m.ordered,
          number: m.number,
          first: m.first,
          checked: m.checked,
        ),
    ];
    return switch (block) {
      ParagraphBlock(:final inlines) => wire.TextBlockSnapshot(
        quotes: nesting.quotes,
        items: items,
        inlines: _inlines(inlines),
      ),
      HeadingBlock(:final level, :final inlines) => wire.TextBlockSnapshot(
        kind: wire.TextKind.heading,
        quotes: nesting.quotes,
        items: items,
        level: level,
        inlines: _inlines(inlines),
      ),
      CodeBlock(:final code, :final language) => wire.TextBlockSnapshot(
        kind: wire.TextKind.code,
        quotes: nesting.quotes,
        items: items,
        code: code,
        language: language,
        tokens: [
          for (final t in highlighter.tokens(code, language))
            wire.CodeTokenSnapshot(text: t.text, scope: t.scope),
        ],
      ),
      FormulaBlock(:final tex, :final written) => wire.TextBlockSnapshot(
        kind: wire.TextKind.formula,
        quotes: nesting.quotes,
        items: items,
        formula: formulas.idOf(tex, display: true),
        written: written,
      ),
      RuleBlock() => wire.TextBlockSnapshot(
        kind: wire.TextKind.rule,
        quotes: nesting.quotes,
        items: items,
      ),
      TableBlock(:final header, :final rows, :final align) =>
        wire.TextBlockSnapshot(
          kind: wire.TextKind.table,
          quotes: nesting.quotes,
          items: items,
          columns: align.length,
          align: [
            for (final a in align)
              switch (a) {
                CellAlign.start => wire.CellAlign.start,
                CellAlign.center => wire.CellAlign.center,
                CellAlign.end => wire.CellAlign.end,
              },
          ],
          cells: [
            for (final (c, cell) in header.indexed)
              wire.CellSnapshot(
                row: 0,
                column: c,
                header: true,
                inlines: _inlines(cell),
              ),
            for (final (r, row) in rows.indexed)
              for (final (c, cell) in row.indexed)
                wire.CellSnapshot(
                  row: r + 1,
                  column: c,
                  inlines: _inlines(cell),
                ),
          ],
        ),
    };
  }

  List<wire.InlineSnapshot> _inlines(List<Inline> inlines) => [
    for (final inline in inlines)
      switch (inline) {
        TextInline(:final text, :final marks, :final link) =>
          wire.InlineSnapshot(
            text: text,
            bold: marks.contains(InlineMark.bold),
            italic: marks.contains(InlineMark.italic),
            code: marks.contains(InlineMark.code),
            strike: marks.contains(InlineMark.strike),
            link: link,
          ),
        FormulaInline(:final tex, :final written, :final display) =>
          wire.InlineSnapshot(
            kind: wire.InlineKind.formula,
            text: written,
            formula: formulas.idOf(tex, display: display),
          ),
        BreakInline() => wire.InlineSnapshot(kind: wire.InlineKind.lineBreak),
        ImageInline(:final source, :final alt) => wire.InlineSnapshot(
          kind: wire.InlineKind.image,
          text: alt,
          link: source,
        ),
      },
  ];
}
