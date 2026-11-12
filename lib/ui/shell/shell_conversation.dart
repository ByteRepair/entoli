import "dart:async";
import "dart:typed_data";

import "package:entoli_glass/entoli_glass.dart" as wire;
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

import "../../app/bot_avatar/stage.dart" show botStageProvider;
import "../../app/chat_controller.dart" show TurnDriver;
import "../../domain/bot_avatar/pose.dart" show BotMood;
import "../../app/read_aloud.dart";
import "../../app/settings/spec.dart" show SettingReader;
import "../../app/transcript/activity.dart";
import "../../app/transcript/chapters.dart";
import "../../app/transcript/code.dart";
import "../../app/transcript/formula.dart";
import "../../app/transcript/message.dart";
import "../../app/transcript/transcript.dart";
import "../../core/log.dart";
import "../../core/platform/rich_clipboard.dart";
import "../../domain/agent_face.dart";
import "../../domain/formatted_text.dart";
import "../../domain/models.dart";
import "../../domain/quote.dart";
import "../../domain/reaction.dart";
import "../../domain/room/room_state.dart" show ChatViewState;
import "../../domain/prompt_library.dart" show nameOf;
import "../../providers.dart";
import "../chat/activity/hand_off.dart";
import "../chat/plan_page.dart" as plan_page;
import "faces.dart";
import "transcript_encoder.dart";
import "../widgets/dialogs.dart" show notify;

/// The conversation drawn by the native shell, apart from any widget: the
/// core's [Transcript], sent row by row over `pigeons/transcript.dart`, a row
/// only when it changed, and what the client says the user did — a node
/// opened, a message's action, a link — run here. A detail opened from it is
/// the client's page, sent while it is up. The open chat's publisher
/// (`ShellChat`) holds one and calls [publish] whenever what it read changed.
class ConversationSurface implements wire.TranscriptIntents {
  ConversationSurface({
    required this.context,
    required this.onReply,
    required this.republish,
  });

  /// Where a page it opens is pushed.
  final BuildContext Function() context;

  /// Quotes a selected passage into the composer.
  final ValueChanged<Quote> onReply;

  /// Asks for [publish] again: a formula or a face landed, a detail opened.
  final void Function() republish;

  final _client = wire.NativeTranscript();

  /// The rows as last sent, by key, and which chat they were for.
  final _sent = <String, wire.RowSnapshot>{};
  String? _sentFor;
  wire.DetailSnapshot? _sentDetail;

  /// Each message's actions as last laid out, by row key.
  final _actions = <String, MessageActions>{};

  TranscriptEncoder? _encoder;
  FormulaSheet? _formulas;
  SettingReader? _reader;
  String? _chatId;

  /// The detail open, if any, and the node it is of.
  EncodedNode? _open;

  /// Faces by author, drawn once each.
  final _faces = <String, Uint8List?>{};

  /// [chatId] open with nothing to show yet, while it is read: keeps the
  /// conversation up rather than gone between two chats, which would bring
  /// the Flutter view back into the window for a moment.
  void loading(String chatId) {
    if (_sentFor == chatId) return;
    _sent.clear();
    _sentFor = chatId;
    _open = null;
    _send(
      () => _client.conversation(
        wire.ConversationSnapshot(chatId: chatId, loading: true),
      ),
    );
  }

  /// Takes the conversation off the client.
  void clear() {
    _sent.clear();
    _sentFor = null;
    _sentDetail = null;
    _open = null;
    _send(() => _client.conversation(wire.ConversationSnapshot()));
    _send(() => _client.detail(wire.DetailSnapshot()));
  }

  /// Sends [transcript] of [chatId] as [view] has it, what it reads watched
  /// through [reader]: the rows that changed, the formulas typeset since, and
  /// the open detail. [ink] is the text's colour, which a formula is drawn
  /// in; [outline] is a face's.
  void publish(
    SettingReader reader, {
    required String chatId,
    required Transcript transcript,
    required ChatViewState view,
    required ProviderListenable<ChatViewState> source,
    required TurnDriver? driver,
    required int ink,
    required Color outline,
    List<Chapter> chapters = const [],
  }) {
    _reader = reader;
    _chatId = chatId;
    if (_formulas?.argb != ink) {
      // Another ink is another picture of every formula.
      _formulas = FormulaSheet(
        reader.read(formulaRendererProvider),
        argb: ink,
        onReady: republish,
      );
      _sent.clear();
    }
    final project = view.chat?.state.project;
    final encoder = _encoder = TranscriptEncoder(
      reader: reader,
      catalog: reader.watch(activityCatalogProvider),
      formulas: _formulas!,
      highlighter: reader.watch(codeHighlighterProvider),
      resources: reader
          .watch(appConfigProvider)
          .resourcesDir(chatId, project: project),
    );
    final speechReady = reader.watch(speechReadyProvider);
    final reading = reader.watch(readAloudProvider);
    _actions.clear();

    wire.MessageSnapshot message(MessageRow row) {
      final id = row.message.id;
      final actions = MessageActions.of(row, view, driver);
      _actions[row.key] = actions;
      return encoder.message(
        row.key,
        MessageLayout(row.message, chatId: chatId, catalog: encoder.catalog),
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
        source: source.select((v) => liveMessageOf(v, id)),
        face: _photoOf(reader, row.message, project, outline),
        bot: _botOf(
          reader,
          row.message,
          project,
          thinking: view.isRunning && row.last,
          live: row.last,
        ),
      );
    }

    if (_sentFor != chatId) {
      _sent.clear();
      _sentFor = chatId;
      _open = null;
    }
    final order = <String>[];
    final changed = <wire.RowSnapshot>[];
    for (final row in transcript.rows) {
      final snapshot = encoder.row(row, message: message);
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
          chatId: chatId,
          order: order,
          changed: changed,
          running: view.isRunning,
          reactions: [
            for (final r in Reaction.values)
              wire.ReactionChoice(emoji: r.emoji, name: r.name),
          ],
          chapters: [
            for (final c in chapters)
              wire.ChapterSnapshot(
                row: "message:${c.row}",
                preview: c.preview,
                threads: c.threads,
              ),
          ],
        ),
      ),
    );
    _publishDetail(reader, encoder);
  }

  void _publishDetail(SettingReader reader, TranscriptEncoder encoder) {
    final open = _open;
    final detail = open?.node.detail(reader, source: open.source);
    final snapshot = detail == null
        ? wire.DetailSnapshot()
        : encoder.detail(
            detail,
            nested: (nested) => encoder.message(
              "detail",
              MessageLayout(
                nested.message,
                chatId: nested.chatId,
                catalog: encoder.catalog,
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

  static AgentFace? _faceOf(
    SettingReader reader,
    Message message,
    String? project,
  ) {
    final member = nameOf(message.author);
    if (member == null) return null;
    return reader
        .watch(agentPictureProvider((project: project, name: member)))
        .value;
  }

  /// The author's Bot Avatar as the stage's key: the client draws it live,
  /// asking the core for each frame, as the settings' faces are drawn. It
  /// thinks while the reply is being written and idles once it is done.
  ({String key, int colour, int mood, bool live})? _botOf(
    SettingReader reader,
    Message message,
    String? project, {
    required bool thinking,
    required bool live,
  }) {
    if (_faceOf(reader, message, project) case AgentBot(:final spec)) {
      return (
        key: reader.read(botStageProvider).keyOf(spec.definition),
        colour: spec.colour,
        mood: (thinking ? BotMood.thinking : BotMood.idle).index,
        live: live,
      );
    }
    return null;
  }

  /// The author's photo as a picture, where the message names a member who
  /// has one.
  Uint8List? _photoOf(
    SettingReader reader,
    Message message,
    String? project,
    Color outline,
  ) {
    final face = _faceOf(reader, message, project);
    if (face is! AgentPhoto) return null;
    final key = "${project ?? ""}/${message.author}/${identityHashCode(face)}";
    if (_faces.containsKey(key)) return _faces[key];
    _faces[key] = null;
    unawaited(_draw(key, face, outline));
    return null;
  }

  Future<void> _draw(String key, AgentFace face, Color outline) async {
    final png = await agentFacePng(
      face,
      size: 28,
      pixelRatio: 3,
      outline: outline,
    );
    _faces[key] = png;
    republish();
  }

  static void _send(Future<void> Function() sending) => sending().catchError(
    (Object e) => logFailure("shell", "transcript snapshot", e),
  );

  ContextHandOff get _handOff => ContextHandOff(context());

  @override
  Future<void> open(String node) async {
    final found = _encoder?.nodes[node];
    final at = context();
    if (found == null || !at.mounted) return;
    switch (found.node) {
      case OutputNode(:final open):
        await open(_handOff);
      case PlanNode(:final run):
        plan_page.openPlan(at, run.chatId);
      case _:
        _open = found;
        republish();
    }
  }

  /// Opens [activity]'s detail for [run], following [source]: a running
  /// pill's job or sub-agent, which has no node in the conversation.
  void openRun(
    Activity activity,
    Run run, {
    ProviderListenable<LiveMessage>? source,
  }) {
    _open = (
      node: LabelNode(activity, run, glyph: TranscriptGlyph.terminal, text: ""),
      source: source,
    );
    republish();
  }

  @override
  Future<void> closeDetail() async {
    if (_open == null) return;
    _open = null;
    republish();
  }

  @override
  Future<void> detailAction(int index) async {
    final open = _open;
    final reader = _reader;
    if (open == null || reader == null) return;
    final detail = open.node.detail(reader, source: open.source);
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
        final failed = await _reader
            ?.read(readAloudProvider.notifier)
            .toggle(actions.message.id, markdown);
        final at = context();
        if (failed != null && at.mounted) {
          notify(at, failed);
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
    final at = context();
    final chatId = _chatId;
    if (at.mounted && chatId != null) plan_page.openPlan(at, chatId);
  }

  /// A reply's quote carries its author's handle, so the answer is
  /// addressed to them; the user's own carries none.
  @override
  Future<void> reply(String row, String text) async {
    final message = _actions[row]?.message;
    if (message == null || text.trim().isEmpty) return;
    onReply(Quote(text, handle: message.author));
  }

  @override
  Future<void> openFile(String row, int block, int file) async {
    final encoder = _encoder;
    if (encoder == null) return;
    final blocks = encoder.blocks[row];
    final at = blocks?.elementAtOrNull(block);
    final files = switch (at) {
      BubbleBlock(:final files) => files,
      FileBlock(:final file) => [file],
      SteerBlock() => at.bubble.files,
      _ => const <FilePart>[],
    };
    final part = files.elementAtOrNull(file);
    if (part == null) return;
    final path = encoder.fileSnapshot(part).path;
    if (path != null) await _handOff.openFile(path);
  }
}
