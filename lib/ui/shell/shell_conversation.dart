import "dart:async";
import "dart:math" as math;
import "dart:typed_data";

import "package:entoli_glass/entoli_glass.dart" as wire;
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

import "../../app/chat_controller.dart" show TurnDriver;
import "../../app/read_aloud.dart";
import "../../app/settings/spec.dart" show WidgetReader;
import "../../app/transcript/activity.dart";
import "../../app/transcript/code.dart";
import "../../app/transcript/formula.dart";
import "../../app/transcript/message.dart";
import "../../app/transcript/transcript.dart";
import "../../core/log.dart";
import "../../core/platform/rich_clipboard.dart";
import "../../domain/agent_face.dart";
import "../../domain/formatted_text.dart";
import "../../domain/models.dart";
import "../../domain/reaction.dart";
import "../../domain/room/room_state.dart" show ChatViewState;
import "../../domain/prompt_library.dart" show nameOf;
import "../../providers.dart";
import "../chat/activity/hand_off.dart";
import "../chat/plan_page.dart" as plan_page;
import "../voice/read_aloud.dart" show readAloud;
import "faces.dart";
import "shell_answers.dart";
import "shell_window.dart" show shellInsets;
import "transcript_encoder.dart";

/// The conversation drawn by the native shell: the core's [Transcript],
/// sent row by row over `pigeons/transcript.dart`, a row only when it
/// changed. It draws nothing itself — the list is the Swift's — and answers
/// what the client says the user did: a node opened, a message's action, a
/// link. A detail opened from it is the client's page, sent while it is up.
class ShellConversation extends ConsumerStatefulWidget {
  const ShellConversation({
    super.key,
    required this.chatId,
    required this.transcript,
    required this.view,
    required this.source,
    this.driver,
  });

  final String chatId;
  final Transcript transcript;
  final ChatViewState view;
  final ProviderListenable<ChatViewState> source;

  /// What the message rows act through; null for a mirror this device does
  /// not hold.
  final TurnDriver? driver;

  @override
  ConsumerState<ShellConversation> createState() => _ShellConversationState();
}

class _ShellConversationState extends ConsumerState<ShellConversation>
    implements wire.TranscriptIntents {
  final _client = wire.NativeTranscript();
  late final ShellAnswers _answers = ref.read(shellAnswersProvider);

  /// The rows as last sent, by key, and which chat they were for.
  final _sent = <String, wire.RowSnapshot>{};
  String? _sentFor;
  wire.DetailSnapshot? _sentDetail;

  /// Each message's actions as last laid out, by row key.
  final _actions = <String, MessageActions>{};

  late TranscriptEncoder _encoder;
  FormulaSheet? _formulas;

  /// The detail open, if any, and the node it is of.
  EncodedNode? _open;

  /// Faces by author, drawn once each.
  final _faces = <String, Uint8List?>{};

  @override
  void initState() {
    super.initState();
    _answers.transcript.take(this);
  }

  @override
  void dispose() {
    if (_answers.transcript.release(this)) {
      _send(() => _client.conversation(wire.ConversationSnapshot()));
      _send(() => _client.detail(wire.DetailSnapshot()));
    }
    super.dispose();
  }

  void _republish() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    _answers.transcript.take(this);
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface.toARGB32();
    if (_formulas?.argb != ink) {
      // Another ink is another picture of every formula.
      _formulas = FormulaSheet(
        ref.read(formulaRendererProvider),
        argb: ink,
        onReady: _republish,
      );
      _sent.clear();
    }
    final reader = WidgetReader(ref);
    final project = widget.view.chat?.state.project;
    _encoder = TranscriptEncoder(
      reader: reader,
      catalog: ref.watch(activityCatalogProvider),
      formulas: _formulas!,
      highlighter: ref.watch(codeHighlighterProvider),
      resources: ref
          .watch(appConfigProvider)
          .resourcesDir(widget.chatId, project: project),
    );
    final speechReady = ref.watch(speechReadyProvider);
    final reading = ref.watch(readAloudProvider);
    _actions.clear();

    wire.MessageSnapshot message(MessageRow row) {
      final id = row.message.id;
      final view = widget.view;
      final actions = MessageActions.of(row, view, widget.driver);
      _actions[row.key] = actions;
      return _encoder.message(
        row.key,
        MessageLayout(
          row.message,
          chatId: widget.chatId,
          catalog: _encoder.catalog,
        ),
        MessageMoment(
          waiting: view.isRunning && row.last,
          status: view.status,
          notice: view.retry,
          shellOutput: view.shellOutput[id],
          canRetry: actions.canRegenerate,
        ),
        actions: _actionsOf(
          actions,
          speak: speechReady && row.message.hasText,
          speaking: reading == id,
        ),
        reactions: row.reactions,
        source: widget.source.select((v) => liveMessageOf(v, id)),
        face: _faceOf(row.message, project),
      );
    }

    if (_sentFor != widget.chatId) {
      _sent.clear();
      _sentFor = widget.chatId;
    }
    final order = <String>[];
    final changed = <wire.RowSnapshot>[];
    for (final row in widget.transcript.rows) {
      final snapshot = _encoder.row(row, message: message);
      order.add(row.key);
      if (_sent[row.key] != snapshot) {
        _sent[row.key] = snapshot;
        changed.add(snapshot);
      }
    }
    _sent.removeWhere((key, _) => !order.contains(key));
    final pictures = _formulas!.take();
    if (pictures.isNotEmpty) _send(() => _client.formulas(pictures));
    _send(
      () => _client.conversation(
        wire.ConversationSnapshot(
          chatId: widget.chatId,
          order: order,
          changed: changed,
          running: widget.view.isRunning,
          flutterBottom: _flutterBottom(context),
          reactions: [for (final r in Reaction.values) r.emoji],
        ),
      ),
    );
    _publishDetail(reader);
    return const SizedBox.expand();
  }

  /// What Flutter still draws at the foot, over the shell's own insets.
  double _flutterBottom(BuildContext context) {
    final media = MediaQuery.of(context);
    final shell = math.max(
      0,
      shellInsets.value.bottom - media.viewInsets.bottom,
    );
    return math.max(0, media.padding.bottom - shell);
  }

  void _publishDetail(WidgetReader reader) {
    final open = _open;
    final detail = open?.node.detail(reader, source: open.source);
    final snapshot = detail == null
        ? wire.DetailSnapshot()
        : _encoder.detail(
            detail,
            nested: (nested) => _encoder.message(
              "detail",
              MessageLayout(
                nested.message,
                chatId: nested.chatId,
                catalog: _encoder.catalog,
              ),
              MessageMoment(waiting: nested.running),
              actions: wire.ActionsSnapshot(copy: nested.message.hasText),
              reactions: const [],
              source: nested.source,
            ),
          );
    if (snapshot == _sentDetail) return;
    _sentDetail = snapshot;
    _send(() => _client.detail(snapshot));
  }

  wire.ActionsSnapshot _actionsOf(
    MessageActions actions, {
    required bool speak,
    required bool speaking,
  }) => wire.ActionsSnapshot(
    copy: actions.canCopy,
    threads: actions.showsThreads ? actions.threadLabel : null,
    previous: actions.canStep(-1),
    next: actions.canStep(1),
    delete: actions.canDelete,
    deleteQuestion: actions.deleteQuestion.message,
    edit: actions.canEdit,
    editText: actions.markdown,
    regenerate: actions.canRegenerate,
    react: actions.canReact,
    speak: speak,
    speaking: speaking,
  );

  /// The author's face as a picture, where the message names a member.
  Uint8List? _faceOf(Message message, String? project) {
    final member = nameOf(message.author);
    if (member == null) return null;
    final face = ref
        .watch(agentPictureProvider((project: project, name: member)))
        .value;
    if (face == null) return null;
    final key = "${project ?? ""}/$member/${identityHashCode(face)}";
    if (_faces.containsKey(key)) return _faces[key];
    _faces[key] = null;
    unawaited(_draw(key, face));
    return null;
  }

  Future<void> _draw(String key, AgentFace face) async {
    final png = await agentFacePng(
      face,
      size: 28,
      pixelRatio: 3,
      outline: Theme.of(context).colorScheme.outlineVariant,
    );
    _faces[key] = png;
    _republish();
  }

  static void _send(Future<void> Function() sending) => sending().catchError(
    (Object e) => logFailure("shell", "transcript snapshot", e),
  );

  ContextHandOff get _handOff => ContextHandOff(context);

  @override
  Future<void> open(String node) async {
    final found = _encoder.nodes[node];
    if (found == null || !mounted) return;
    switch (found.node) {
      case OutputNode(:final open):
        await open(_handOff);
      case PlanNode(:final run):
        plan_page.openPlan(context, run.chatId);
      case _:
        setState(() => _open = found);
    }
  }

  @override
  Future<void> closeDetail() async {
    if (_open != null) setState(() => _open = null);
  }

  @override
  Future<void> detailAction(int index) async {
    final open = _open;
    if (open == null) return;
    final detail = open.node.detail(WidgetReader(ref), source: open.source);
    final run = detail?.actions.elementAtOrNull(index)?.run;
    if (run != null) await run(_handOff);
  }

  @override
  Future<void> link(String href) => _handOff.openLink(href);

  @override
  Future<void> act(String row, wire.MessageAction action) async {
    final actions = _actions[row];
    if (actions == null) return;
    final markdown = actions.markdown;
    switch (action) {
      case wire.MessageAction.copy:
        await writeClipboard(
          ClipboardContent(
            plain: formattedTextOf(markdown),
            html: formattedHtmlOf(markdown),
          ),
        );
      case wire.MessageAction.copyRaw:
        await writeClipboard(ClipboardContent(plain: markdown));
      case wire.MessageAction.previous:
        await _handOff.attempt(() => actions.step(-1));
      case wire.MessageAction.next:
        await _handOff.attempt(() => actions.step(1));
      case wire.MessageAction.delete:
        await _handOff.attempt(actions.delete);
      case wire.MessageAction.regenerate:
        await _handOff.attempt(actions.regenerate);
      case wire.MessageAction.speak:
        if (mounted) {
          await readAloud(context, ref, actions.message.id, markdown);
        }
    }
  }

  @override
  Future<void> edit(String row, String text) async =>
      _handOff.attempt(() async => _actions[row]?.edit(text));

  @override
  Future<void> react(String row, String emoji) async {
    final reaction = Reaction.values.where((r) => r.emoji == emoji).firstOrNull;
    final actions = _actions[row];
    if (reaction == null || actions == null) return;
    await _handOff.attempt(() => actions.react(reaction));
  }

  @override
  Future<void> retry(String row) async =>
      _handOff.attempt(() async => _actions[row]?.regenerate());

  @override
  Future<void> openPlan() async {
    if (mounted) plan_page.openPlan(context, widget.chatId);
  }

  @override
  Future<void> openFile(String row, int block, int file) async {
    final blocks = _encoder.blocks[row];
    final at = blocks?.elementAtOrNull(block);
    final files = switch (at) {
      BubbleBlock(:final files) => files,
      FileBlock(:final file) => [file],
      SteerBlock() => at.bubble.files,
      _ => const <FilePart>[],
    };
    final part = files.elementAtOrNull(file);
    if (part == null) return;
    final path = _encoder.fileSnapshot(part).path;
    if (path != null) await _handOff.openFile(path);
  }
}
