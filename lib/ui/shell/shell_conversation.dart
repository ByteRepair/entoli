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
import "../../app/transcript/copy.dart";
import "../../app/transcript/formula.dart";
import "../../app/transcript/message.dart";
import "../../app/transcript/transcript.dart";
import "../../core/log.dart";
import "../../core/platform/rich_clipboard.dart";
import "../../domain/agent_face.dart";
import "../../domain/models.dart";
import "../../domain/quote.dart";
import "../../domain/reaction.dart";
import "../../domain/room/room_state.dart" show ChatViewState;
import "../../domain/prompt_library.dart" show nameOf;
import "../../providers.dart";
import "../chat/activity/card.dart" show ContextHandOff;
import "faces.dart";
import "markdown_encoder.dart";
import "message_rows.dart";
import "transcript_encoder.dart";
import "../widgets/dialogs.dart" show notify;

/// The conversation drawn by the native shell, apart from any widget: the
/// core's [Transcript], sent row by row over `pigeons/transcript.dart`, a row
/// only when it changed, and what the client says the user did — a node
/// opened, a message's action, a link — run here. A detail opened from it is
/// the client's page, sent while it is up. The open chat's publisher
/// (`ShellChat`) holds one and calls [publish] whenever what it read changed.
class ConversationSurface implements wire.TranscriptIntents {
  ConversationSurface(
    ProviderContainer container, {
    required this.context,
    required this.onReply,
    required this.republish,
  }) : _rows = MessageRows(container, republish: republish);

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

  /// The detail open, if any, and the node it is of.
  OpensDetail? _open;

  final _parsed = MarkdownBlocks();

  /// The message rows as last encoded, kept while what they read holds.
  final MessageRows _rows;

  /// The open chat's attachments found on disk.
  final _present = <String>{};

  /// [chatId] open with nothing to show yet, while it is read: keeps the
  /// conversation up rather than gone between two chats, which would bring
  /// the Flutter view back into the window for a moment.
  void loading(String chatId) {
    if (_sentFor == chatId) return;
    _sent.clear();
    _rows.clear();
    _present.clear();
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
    _rows.clear();
    _present.clear();
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
    if (_formulas?.argb != ink) {
      // Another ink is another picture of every formula.
      _formulas = FormulaSheet(
        reader.read(formulaRendererProvider),
        argb: ink,
        onReady: () {
          _parsed.landed();
          _rows.formulaLanded();
          republish();
        },
      );
      _parsed.clear();
      _sent.clear();
      _rows.clear();
    }
    final project = view.chat?.state.project;
    final catalog = reader.watch(activityCatalogProvider);
    final prose = MarkdownEncoder(
      formulas: _formulas!,
      highlighter: reader.watch(codeHighlighterProvider),
      parsed: _parsed,
    );
    final resources = reader
        .watch(appConfigProvider)
        .resourcesDir(chatId, project: project);
    TranscriptEncoder encoderOver(SettingReader reader) => TranscriptEncoder(
      reader: reader,
      catalog: catalog,
      prose: prose,
      resources: resources,
      present: _present,
    );
    final encoder = _encoder = encoderOver(reader);
    final speechReady = reader.watch(speechReadyProvider);
    final reading = reader.watch(readAloudProvider);
    _actions.clear();

    /// [row], encoded again only where it changed: its own reader watches
    /// what its layout and face read.
    wire.RowSnapshot? message(MessageRow row) {
      final id = row.message.id;
      final actions = MessageActions.of(row, view, driver);
      _actions[row.key] = actions;
      final moment = row.moment(view, driver);
      final wireActions = _actionsOf(
        actions,
        speak: speechReady && row.message.hasText,
        speaking: reading == id,
      );
      return _rows.encode(
        row,
        (
          last: row.last,
          reactions: row.reactions.join("\n"),
          waiting: moment.waiting,
          // Said only beside the spinner, so a row not waiting ignores them.
          status: moment.waiting ? moment.status : null,
          notice: moment.waiting ? moment.notice : null,
          shellOutput: moment.shellOutput,
          canRetry: moment.canRetry,
          actions: wireActions,
          outline: outline,
          catalog: catalog,
          prose: prose.highlighter,
          resources: resources,
        ),
        formulas: _formulas!,
        encoder: encoderOver,
        build: (encoder, reader) {
          final face = row.face(reader, project: project);
          return encoder.message(
            row.key,
            MessageLayout(row.message, chatId: chatId, catalog: catalog),
            moment,
            actions: wireActions,
            reactions: row.reactions,
            source: source.select((v) => liveMessageOf(v, id)),
            face: face is AgentPhoto
                ? _photoOf(reader, row.message, project, outline)
                : null,
            bot: face is AgentBot
                ? _botOf(reader, face, mood: moment.mood, live: row.last)
                : null,
          );
        },
      );
    }

    if (_sentFor != chatId) {
      _sent.clear();
      _rows.clear();
      _present.clear();
      _sentFor = chatId;
      _open = null;
    }
    final order = <String>[];
    final changed = <wire.RowSnapshot>[];
    for (final row in transcript.rows) {
      order.add(row.key);
      final snapshot = row is MessageRow ? message(row) : encoder.row(row);
      // Null is a message row kept as it was last sent.
      if (snapshot != null && _sent[row.key] != snapshot) {
        _sent[row.key] = snapshot;
        changed.add(snapshot);
      }
    }
    _parsed.turn();
    final kept = order.toSet();
    _sent.removeWhere((key, _) => !kept.contains(key));
    _rows.keep(kept);
    final pictures = _formulas!.take();
    if (pictures.isNotEmpty) _send(() => _client.formulas(pictures));
    _send(
      () => _client.conversation(
        wire.ConversationSnapshot(
          chatId: chatId,
          order: order,
          changed: changed,
          reactions: [
            for (final r in Reaction.values)
              wire.ReactionChoice(emoji: r.emoji, name: r.name),
          ],
          chapters: [
            for (final c in chapters)
              wire.ChapterSnapshot(
                row: MessageRow.keyOf(c.row),
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
    final detail = _open?.detail(reader);
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
    // Only what can be edited needs its text: a user's message.
    editText: actions.canEdit ? actions.markdown : "",
    regenerate: actions.canRegenerate,
    react: actions.canReact,
    speak: speak,
    speaking: speaking,
  );

  /// The author's Bot Avatar as the stage's key: the client draws it live,
  /// asking the core for each frame, as the settings' faces are drawn. It
  /// thinks while the reply is being written and idles once it is done.
  ({String key, int colour, int mood, bool live}) _botOf(
    SettingReader reader,
    AgentBot face, {
    required BotMood mood,
    required bool live,
  }) => (
    key: reader.read(botStageProvider).keyOf(face.spec.definition),
    colour: face.spec.colour,
    mood: mood.index,
    live: live,
  );

  /// The author's photo as a picture, null until it is drawn.
  static Uint8List? _photoOf(
    SettingReader reader,
    Message message,
    String? project,
    Color outline,
  ) => reader
      .watch(
        agentFacePngProvider((
          project: project,
          name: nameOf(message.author)!,
          size: 28,
          pixelRatio: 3,
          outline: outline,
        )),
      )
      .value;

  static void _send(Future<void> Function() sending) => sending().catchError(
    (Object e) => logFailure("shell", "transcript snapshot", e),
  );

  /// The hand-off this conversation's presses go through: Flutter's, but
  /// with a detail opened as the client's own page.
  TranscriptHandOff get handOff => _ShellHandOff(context(), this);

  @override
  Future<void> open(String node) async {
    final found = _rows.node(node) ?? _encoder?.nodes[node];
    if (found == null || !context().mounted) return;
    await found.node.open(handOff, source: found.source);
  }

  /// Opens [detail] as the client's page, sent while it is up.
  void _openDetail(OpensDetail detail) {
    _open = detail;
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
    final detail = open.detail(reader);
    final run = detail?.actions.elementAtOrNull(index)?.run;
    if (run != null) await run(handOff);
  }

  @override
  Future<void> link(String href) => handOff.openLink(href);

  @override
  Future<void> act(String row, wire.MessageAction action) async {
    final actions = _actions[row];
    if (actions == null) return;
    final markdown = actions.markdown;
    switch (action) {
      case wire.MessageAction.copy:
        final renderer = _reader?.read(formulaRendererProvider);
        await writeClipboard(
          replyClipboard(
            markdown,
            renderer == null
                ? const {}
                : await formulaPicturesOf(markdown, renderer),
          ),
        );
      case wire.MessageAction.copyRaw:
        await writeClipboard(ClipboardContent(plain: markdown));
      case wire.MessageAction.previous:
        await handOff.attempt(() => actions.step(-1));
      case wire.MessageAction.next:
        await handOff.attempt(() => actions.step(1));
      case wire.MessageAction.delete:
        await handOff.attempt(actions.delete);
      case wire.MessageAction.regenerate:
        await handOff.attempt(actions.regenerate);
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
      handOff.attempt(() async => _actions[row]?.edit(text));

  @override
  Future<void> react(String row, String emoji) async {
    final reaction = Reaction.values.where((r) => r.emoji == emoji).firstOrNull;
    final actions = _actions[row];
    if (reaction == null || actions == null) return;
    await handOff.attempt(() => actions.react(reaction));
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
    final blocks = _rows.blocks(row);
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
    if (path != null) await handOff.openFile(path);
  }
}

class _ShellHandOff extends ContextHandOff {
  const _ShellHandOff(super.context, this._surface);

  final ConversationSurface _surface;

  @override
  Future<void> openDetail(OpensDetail detail) async =>
      _surface._openDetail(detail);
}
