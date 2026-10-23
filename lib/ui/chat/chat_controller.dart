import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/log.dart";
import "../../domain/chat_log.dart";
import "../../domain/chat_repository.dart";
import "../../domain/reminder_alarms.dart";
import "../../domain/models.dart";
import "../../domain/project_settings.dart"
    show OmadaOrdering, defaultOmadaOrdering;
import "../../domain/room/chat_room.dart";
import "../../domain/room/room_state.dart";
import "../../domain/room/roster.dart";
import "../../providers.dart";

/// What a page needs of whatever is driving its turn. [ChatController] for a
/// chat on this device, `MirrorChatController` for one whose home device is a
/// paired peer — the widgets between them are the same either way, and only
/// where the work happens differs.
abstract interface class TurnDriver {
  /// While a turn runs, [text] steers it unless [queue] holds it for after.
  Future<void> send(String text, {List<Attachment> attachments, bool queue});

  /// A say still waiting for its turn to read it, sent after the turn instead.
  Future<void> queueSteer(String id);

  /// Take back a say its turn has not read yet: what it was sent with, or
  /// null where the turn already has it.
  Future<({String text, List<Attachment> attachments})?> withdrawSteer(
      String id);

  Future<void> resume();
  Future<void> abort();
  Future<void> respondApproval(String approvalId, ApprovalResponse r,
      {ToolApproval? approval});
  Future<void> answerQuestions(String requestId, List<String?> answers);
  Future<void> editAndResend(String messageId, String text);
  Future<void> regenerate(String messageId);
  Future<void> stepThread(String messageId, int step);
  Future<void> deleteThread(String messageId);

  /// Whether an approval answer may write a standing rule here. False for a
  /// mirrored chat: the banner is being answered from the other device, and
  /// the rule is the home device's to write — its banner asks the question,
  /// so offering it twice would be two answers to one call.
  bool get rulesWritable => true;
}

/// A chat on this device: the [ChatRoom] that drives it, held by Riverpod.
/// What is here is what the room is not — the settings it reads, and the
/// services around a turn: naming the chat, saying a failure out loud,
/// compacting a session that has grown.
class ChatController extends Notifier<ChatViewState>
    implements TurnDriver, RoomHost {
  ChatController(this.chatId);

  @override
  bool get rulesWritable => true;

  final String chatId;

  late ChatRoom _room;

  @override
  ChatViewState build() {
    _room = ChatRoom(chatId, ref.read(chatRepositoryProvider), this);
    final room = _room;
    // The provider is not auto-disposed: clear a controller that outlived its page, or its id re-opens the deleted chat from memory.
    final deletionSub = ref.read(chatRepositoryProvider).changes.listen((event) {
      if (event is Deleted && event.chatId == chatId) room.reset();
    });
    ref.onDispose(() {
      room.dispose();
      deletionSub.cancel();
    });
    return room.state;
  }

  // The room's host.

  @override
  Roster roster(String? project) => Roster(
      omada: ref.read(omadaOnProvider(project)),
      library: ref.read(promptLibraryProvider(project)));

  /// The project's pick, else the app default, else relay.
  @override
  OmadaOrdering ordering(String? project) =>
      ref.read(projectSettingsProvider(project)).omadaOrdering ??
      ref.read(appSettingsProvider).omadaOrdering ??
      defaultOmadaOrdering;

  /// Dispatch waves, not turns — a three-member fan-out is one generation
  /// whatever it fans out to. The project's override wins over the app
  /// default, and the user speaking resets the count: the cap is about agents
  /// talking to each other without end, not about how long a conversation
  /// may run.
  @override
  int maxGenerations(String? project) =>
      ref.read(projectSettingsProvider(project)).omadaMaxGenerations ??
      ref.read(appSettingsProvider).omadaMaxGenerations;

  /// Resolved at the round the same way the approve mode is, so an edit
  /// reaches the next failure rather than the next launch.
  @override
  int get turnRetries => ref.read(appSettingsProvider).turnRetries;

  @override
  void stateChanged(ChatViewState next) {
    if (ref.mounted) state = next;
  }

  @override
  void firstSaid(String text) => unawaited(_maybeNameChat(text));

  @override
  Future<void> turnEnded(TurnEnd? reason, String errorLine) =>
      _notifyFailure(reason, errorLine);

  @override
  void settledDone() => unawaited(_maybeAutoCompact());

  // What the page drives.

  /// Completes with the last [TurnEnd] when every turn in flight now is over.
  /// Null where nothing is running. See [ChatRoom.turnDone].
  Future<TurnEnd?>? get turnDone => _room.turnDone;

  String get replyText => _room.replyText;

  void applyState(ChatState written) => _room.applyState(written);

  void applyTitle(String title) => _room.applyTitle(title);

  @override
  Future<void> send(String text,
          {List<Attachment> attachments = const [], bool queue = false}) =>
      _room.send(text, attachments: attachments, queue: queue);

  @override
  Future<void> queueSteer(String id) => _room.queueSteer(id);

  @override
  Future<({String text, List<Attachment> attachments})?> withdrawSteer(
          String id) =>
      _room.withdrawSteer(id);

  @override
  Future<void> resume() => _room.resume();

  @override
  Future<void> editAndResend(String messageId, String text) =>
      _room.editAndResend(messageId, text);

  @override
  Future<void> regenerate(String messageId) => _room.regenerate(messageId);

  @override
  Future<void> stepThread(String messageId, int step) =>
      _room.stepThread(messageId, step);

  @override
  Future<void> deleteThread(String messageId) => _room.deleteThread(messageId);

  @override
  Future<void> abort() => _room.abort();

  /// See [ChatRoom.interrupt].
  Future<void> interrupt() => _room.interrupt();

  @override
  Future<void> respondApproval(
    String approvalId,
    ApprovalResponse r, {
    ToolApproval? approval,
  }) async {
    await _room.respondApproval(approvalId, r, approval: approval);
    if (!ref.mounted) return;
    // A project-tier answer (always in project) wrote `project.json` behind
    // the settings page's back: the provider loaded once at startup and its
    // state is stale until told. Same for the chat's `meta.json`, whose
    // change the repository already streams.
    ref.invalidate(projectSettingsProvider(null));
    ref.invalidate(projectSettingsProvider(state.chat?.state.project));
  }

  @override
  Future<void> answerQuestions(String requestId, List<String?> answers) =>
      _room.answerQuestions(requestId, answers);

  // The services around a turn.

  /// Name the chat after what started it, unless it is headless — a reminder's
  /// chat is already named. Nothing waits on this: it is a model call of its
  /// own, and the turn it belongs to is already under way.
  ///
  /// Guards after each await, before any read of [state]: an invalidated
  /// controller (a chat moved while a turn was starting) keeps its in-flight
  /// futures, and a read through the disposed notifier throws.
  Future<void> _maybeNameChat(String prompt) async {
    if (!ref.mounted) return;
    final repo = ref.read(chatRepositoryProvider);
    if (await _isHeadless()) return;
    final title = await repo.suggestTitle(prompt);
    if (!ref.mounted) return;
    final chat = state.chat;
    if (title == null || chat == null) return;
    applyTitle(title);
    await repo.retitle(chatId, title);
    if (!ref.mounted) return;
    ref.invalidate(chatListProvider);
  }

  /// Compacts when the session has grown past the configured share of the
  /// model's window. Runs unawaited — the room has settled, and the next
  /// turn does not wait on it — and refuses while anything else is running,
  /// which the compact callback also guards.
  ///
  /// Skipped where nothing has reported a usage: a provider that says
  /// nothing and a chat with no turn yet are both "unknown", and compacting
  /// on a guess is not this feature's business — the estimate lives in the
  /// summarizer's own budget, where a too-big ask is halved, not here.
  Future<void> _maybeAutoCompact() async {
    if (!ref.mounted) return;
    final settings = ref.read(appSettingsProvider);
    if (!settings.autoCompact) return;
    // The usage is the backend's one per-chat fact — the newest request's
    // reading of the session — and the window is answered from the same
    // maps: the chat's model's own where the registry knows it, the
    // app-wide guess where it does not. One read, no meta on the settle path.
    final backend = ref.read(agentBackendProvider);
    final used = backend.usageFor(chatId);
    if (used == null) return;
    final window = backend.contextWindowFor(chatId) ?? settings.totalContext;
    if (used < settings.autoCompactPercent * window ~/ 100) {
      return;
    }
    // Not twice without a turn below the threshold between: the log is the
    // record — a marker covering the last thing said is the same fact, which
    // a reload reads the same way and a failed attempt leaves unset (it wrote
    // no marker, so the next settle may retry).
    final chat = state.chat;
    if (chat == null || state.isRunning) return;
    if (chat.compactions.lastOrNull?.upToMessageId == chat.messages.lastOrNull?.id) {
      return;
    }
    try {
      await _room.compact(instructions: null, recheck: true);
    } catch (e) {
      logFailure("compact", "auto-compact failed", e);
    }
  }

  /// The notification. A failure the user cannot see is a failure the app has
  /// to say — the turn is over, the chat is on disk, and the tap opens it.
  /// [line] is what the failing turn reported. Gated on the app being hidden
  /// and the chat not headless: a reminder's completion is the scheduler's,
  /// and a second would be a double. Where the platform has no notification
  /// route the port is the no-op it always was.
  Future<void> _notifyFailure(TurnEnd? reason, String line) async {
    if (reason != TurnEnd.error) return;
    if (!ref.read(appHiddenProvider)) return;
    if (await _isHeadless()) return;
    final alarms = ref.read(reminderAlarmsProvider);
    final title = state.chat?.state.title ?? "Chat failed";
    await alarms.notify(
      title: title,
      body: line.isEmpty ? "The turn failed." : line,
      chatId: chatId,
      channel: ReminderAlarms.turnFailureChannel,
    );
  }

  /// A chat nobody watches — a reminder's — is the scheduler's to notify.
  Future<bool> _isHeadless() async =>
      (await ref.read(chatRepositoryProvider).loadMeta(chatId)).headless == true;
}

final chatControllerProvider =
    NotifierProvider.family<ChatController, ChatViewState, String>(ChatController.new);

/// Stop whatever turns are running the way the app going away stops them:
/// **interrupted rather than aborted**. See "Carrying on an interrupted turn"
/// for why, and for what this does not reach.
Future<void> interruptLiveTurns(ProviderContainer container) async {
  await Future.wait([
    for (final id in container.read(agentBackendProvider).runningTurns.value)
      if (container.exists(chatControllerProvider(id)))
        container.read(chatControllerProvider(id).notifier).interrupt(),
  ]);
}
