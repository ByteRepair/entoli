import "dart:io";
import "dart:typed_data";

import "package:entoli_glass/entoli_glass.dart" as wire;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;
import "package:path/path.dart" as p;

import "../../app/plan.dart" show planProvider;
import "../../app/settings/spec.dart" show SettingReader;
import "../../app/transcript/activity.dart";
import "../../app/transcript/code.dart";
import "../../app/transcript/formula.dart";
import "../../app/transcript/markdown.dart";
import "../../app/transcript/message.dart";
import "../../app/transcript/transcript.dart";
import "../../domain/models.dart";
import "../../domain/plan.dart";

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

  final _ids = <(String, bool), int>{};
  final _sent = <int>{};
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
    final id = _ids[key] ??= _ids.length + 1;
    if (_sent.contains(id)) return id;
    final style = _style(display);
    final ready = _renderer.ready(tex, style);
    if (ready == null) {
      _renderer.render(tex, style).then((_) => onReady(), onError: (_) {});
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

  /// The pictures made since the last call, for the client to keep.
  List<wire.FormulaPicture> take() {
    final out = _unsent.toList();
    _unsent.clear();
    return out;
  }
}

/// What a node id names: the node, and the source an open detail of it
/// follows.
typedef EncodedNode = ({
  ActivityNode node,
  ProviderListenable<LiveMessage>? source,
});

/// The core's transcript in the wire's terms: each row, block, node and
/// markdown block as the snapshot classes the native client draws. It holds
/// what an intent names by id — the nodes it gave ids, the rows it sent —
/// so the conversation can act on what the client says.
class TranscriptEncoder {
  TranscriptEncoder({
    required this.reader,
    required this.catalog,
    required this.formulas,
    required this.highlighter,
    required this.resources,
  });

  final SettingReader reader;
  final ActivityCatalog catalog;
  final FormulaSheet formulas;
  final CodeHighlighter highlighter;

  /// Where a chat's attachments are on this device.
  final String resources;

  final nodes = <String, EncodedNode>{};

  /// Each message's blocks as last laid out, by row key, which an intent
  /// naming a file finds it by.
  final blocks = <String, List<MessageBlock>>{};

  wire.RowSnapshot row(
    TranscriptRow row, {
    required wire.MessageSnapshot Function(MessageRow row) message,
  }) => switch (row) {
    MessageRow() => wire.RowSnapshot(key: row.key, message: message(row)),
    ModeRow() => wire.RowSnapshot(
      key: row.key,
      kind: wire.RowKind.mode,
      text: row.text,
    ),
    CompactionRow(:final summary) => wire.RowSnapshot(
      key: row.key,
      kind: wire.RowKind.compaction,
      text: CompactionRow.text,
      body: markdown(summary),
    ),
    CompactionFailedRow(:final reason) => wire.RowSnapshot(
      key: row.key,
      kind: wire.RowKind.compactionFailed,
      text: CompactionFailedRow.text,
      body: markdown(reason),
      isError: true,
    ),
    GoalRow() => wire.RowSnapshot(
      key: row.key,
      kind: wire.RowKind.goal,
      text: row.label,
      icon: icon(row.glyph),
      isError: row.isError,
    ),
  };

  /// [layout] at [moment], its nodes registered under [key] and following
  /// [source].
  wire.MessageSnapshot message(
    String key,
    MessageLayout layout,
    MessageMoment moment, {
    required wire.ActionsSnapshot actions,
    required List<String> reactions,
    ProviderListenable<LiveMessage>? source,
    Uint8List? face,
  }) {
    final laid = layout.blocks(reader, moment);
    blocks[key] = laid;
    final speaker = layout.speaker;
    return wire.MessageSnapshot(
      user: layout.message.role == MessageRole.user,
      speaker: speaker.name,
      tint: _tint(speaker.tint),
      face: face,
      blocks: [
        for (final (i, block) in laid.indexed) _block(block, "$key/$i", source),
      ],
      actions: actions,
      reactions: reactions,
    );
  }

  wire.BlockSnapshot _block(
    MessageBlock block,
    String id,
    ProviderListenable<LiveMessage>? source,
  ) => switch (block) {
    BubbleBlock() => _bubble(block),
    ActivityBlock(:final node) => wire.BlockSnapshot(
      kind: wire.BlockKind.activity,
      nodes: [_node(node, "$id/0", source)],
    ),
    ActivityRunBlock(:final start, :final nodes) => wire.BlockSnapshot(
      kind: wire.BlockKind.activityRun,
      runStart: start,
      nodes: [
        for (final (i, node) in nodes.indexed) _node(node, "$id/$i", source),
      ],
    ),
    FileBlock(:final file) => wire.BlockSnapshot(
      kind: wire.BlockKind.file,
      files: [fileSnapshot(file)],
    ),
    ShellRunBlock(:final run) => wire.BlockSnapshot(
      kind: wire.BlockKind.shellRun,
      shell: wire.ShellRunSnapshot(
        command: run.command,
        output: run.output,
        exitCode: run.returnCode,
      ),
    ),
    SteerBlock() => _bubble(
      block.bubble,
      kind: wire.BlockKind.steer,
      heading: block.heading,
    ),
  };

  wire.BlockSnapshot _bubble(
    BubbleBlock block, {
    wire.BlockKind kind = wire.BlockKind.bubble,
    String? heading,
  }) => wire.BlockSnapshot(
    kind: kind,
    tint: _tint(block.tint),
    heading: heading,
    files: [for (final f in block.files) fileSnapshot(f)],
    said: [for (final said in block.said) _said(said)],
    trailing: [
      for (final t in block.trailing)
        switch (t) {
          WaitingTrailing() => wire.TrailingSnapshot(
            line: t.line,
            isError: t.notice != null,
          ),
          LiveOutputTrailing(:final output) => wire.TrailingSnapshot(
            kind: wire.TrailingKind.liveOutput,
            line: output,
          ),
          RetryTrailing() => wire.TrailingSnapshot(
            kind: wire.TrailingKind.retry,
          ),
        },
    ],
  );

  wire.SaidSnapshot _said(Said said) => switch (said) {
    ProseSaid(:final markdown, :final caret) => wire.SaidSnapshot(
      blocks: this.markdown(markdown),
      text: markdown,
      caret: caret,
    ),
    ErrorSaid() => wire.SaidSnapshot(
      kind: wire.SaidKind.error,
      text: said.text,
    ),
    CommandSaid(:final command) => wire.SaidSnapshot(
      kind: wire.SaidKind.command,
      text: command,
    ),
  };

  wire.FileSnapshot fileSnapshot(FilePart file) {
    final path = p.join(resources, file.resource);
    return wire.FileSnapshot(
      name: file.filename,
      mime: file.mimeType,
      path: File(path).existsSync() ? path : null,
    );
  }

  wire.NodeSnapshot _node(
    ActivityNode node,
    String id,
    ProviderListenable<LiveMessage>? source,
  ) {
    nodes[id] = (node: node, source: source);
    return switch (node) {
      LabelNode() => wire.NodeSnapshot(
        id: id,
        icon: icon(node.shownGlyph),
        text: node.text,
        isError: node.isError,
        busy: node.busy,
        tail: node.tail,
      ),
      DiffNode() => wire.NodeSnapshot(
        id: id,
        kind: wire.NodeKind.diff,
        icon: wire.TranscriptIcon.file,
        text: node.title,
        removed: node.removed,
        added: node.added,
      ),
      PlanNode() => _plan(node, id),
      OutputNode() => wire.NodeSnapshot(
        id: id,
        kind: wire.NodeKind.output,
        icon: node.kind == OutputKind.artifact
            ? wire.TranscriptIcon.artifact
            : wire.TranscriptIcon.skill,
        text: node.label,
        output: node.kind == OutputKind.artifact
            ? wire.OutputKind.artifact
            : wire.OutputKind.skill,
      ),
    };
  }

  /// Read through the reader as the Flutter card reads it, so the row is
  /// sent again as the plan moves.
  wire.NodeSnapshot _plan(PlanNode node, String id) {
    final plan = reader.watch(planProvider(node.run.chatId));
    final sections = plan.value;
    final (done, total) = sections == null
        ? (0, 0)
        : sectionsProgress(sections);
    return wire.NodeSnapshot(
      id: id,
      kind: wire.NodeKind.plan,
      icon: wire.TranscriptIcon.plan,
      text: node.title,
      progress: sections != null
          ? "$done of $total tasks done"
          : plan.isLoading
          ? "Reading the plan…"
          : "The plan could not be read.",
      tasks: [
        for (final section in sections ?? const <PlanSection>[])
          for (final task in section.tasks)
            wire.PlanTaskSnapshot(
              title: task.text,
              done: task.status == PlanTaskStatus.done,
            ),
      ],
    );
  }

  /// A detail as the client draws it, a nested transcript's nodes under
  /// ids of their own.
  wire.DetailSnapshot detail(
    ActivityDetail detail, {
    required wire.MessageSnapshot Function(NestedTranscript) nested,
  }) => wire.DetailSnapshot(
    present: true,
    title: detail.title,
    icon: detail.glyph == null ? null : icon(detail.glyph!),
    command: detail.command,
    status: detail.status?.text,
    statusError: detail.status?.isError ?? false,
    sections: [
      for (final s in detail.filled)
        wire.SectionSnapshot(label: s.label, body: s.body!, isError: s.isError),
    ],
    actions: [
      for (final a in detail.actions)
        wire.DetailActionSnapshot(
          label: a.label,
          enabled: a.run != null,
          why: a.why,
        ),
    ],
    mono: detail.mono,
    live: detail.live,
    transcript: detail.transcript == null ? null : nested(detail.transcript!),
  );

  /// Markdown as blocks, its code tokenised and its formulas by id.
  List<wire.TextBlockSnapshot> markdown(String text) => [
    for (final block in MarkdownDocument.parse(text).blocks) _text(block),
  ];

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

  static wire.Tint _tint(BubbleTint tint) => switch (tint) {
    BubbleTint.none => wire.Tint.none,
    BubbleTint.prompt => wire.Tint.prompt,
    BubbleTint.command => wire.Tint.command,
    BubbleTint.notice => wire.Tint.notice,
    BubbleTint.tool => wire.Tint.tool,
    BubbleTint.system => wire.Tint.system,
  };

  /// Name for name: the wire's enum is the core's.
  static wire.TranscriptIcon icon(TranscriptGlyph glyph) =>
      wire.TranscriptIcon.values.byName(glyph.name);
}
