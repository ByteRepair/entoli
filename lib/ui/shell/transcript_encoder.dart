import "dart:io";
import "dart:typed_data";

import "package:entoli_glass/entoli_glass.dart" as wire;
import "package:flutter_riverpod/misc.dart" show ProviderListenable;
import "package:path/path.dart" as p;

import "../../app/settings/spec.dart" show SettingReader;
import "../../app/transcript/activity.dart";
import "../../app/transcript/message.dart";
import "../../app/transcript/transcript.dart";
import "../../domain/models.dart";
import "../../domain/plan.dart";
import "markdown_encoder.dart";

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
    required this.prose,
    required this.resources,
    Set<String>? present,
  }) : _present = present ?? {};

  final SettingReader reader;
  final ActivityCatalog catalog;

  /// The markdown half: blocks, code and formulas.
  final MarkdownEncoder prose;

  /// Where a chat's attachments are on this device.
  final String resources;

  /// The attachments found on disk, kept across passes: one is written once
  /// and locked, so it is not looked for again on every streamed event.
  final Set<String> _present;

  final nodes = <String, EncodedNode>{};

  /// Each message's blocks as last laid out, by row key, which an intent
  /// naming a file finds it by.
  final blocks = <String, List<MessageBlock>>{};

  /// A row that is not a message — a mode line, a compaction, a goal — as
  /// the client draws it; null for a message, which [message] encodes.
  wire.RowSnapshot? row(TranscriptRow row) => switch (row) {
    MessageRow() => null,
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
    ({String key, int colour, int mood, bool live})? bot,
  }) {
    final laid = layout.blocks(reader, moment);
    blocks[key] = laid;
    final speaker = layout.speaker;
    return wire.MessageSnapshot(
      user: layout.message.role == MessageRole.user,
      speaker: speaker.name,
      tint: _tint(speaker.tint),
      face: face,
      bot: bot?.key,
      botColour: bot?.colour,
      botMood: bot?.mood ?? 0,
      botLive: bot?.live ?? false,
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
      path:
          _present.contains(path) ||
              File(path).existsSync() && _present.add(path)
          ? path
          : null,
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
        output: wire.OutputKind.values.byName(node.kind.name),
        caption: node.kind.caption,
      ),
    };
  }

  wire.NodeSnapshot _plan(PlanNode node, String id) => wire.NodeSnapshot(
    id: id,
    kind: wire.NodeKind.plan,
    icon: wire.TranscriptIcon.plan,
    text: node.title,
    progress: node.progress,
    tasks: [
      for (final section in node.sections ?? const <PlanSection>[])
        for (final task in section.tasks)
          wire.PlanTaskSnapshot(
            title: task.text,
            done: task.status == PlanTaskStatus.done,
          ),
    ],
  );

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
  List<wire.TextBlockSnapshot> markdown(String text) => prose.markdown(text);

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
