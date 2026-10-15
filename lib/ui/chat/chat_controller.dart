import "dart:async";

import "package:collection/collection.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:uuid/uuid.dart";

import "../../core/log.dart";
import "../../domain/agent_backend.dart";
import "../../domain/ask.dart";
import "../../domain/chat_log.dart";
import "../../domain/chat_repository.dart";
import "../../domain/reminder_alarms.dart";
import "../../domain/turn_recorder.dart";
import "../../domain/models.dart";
import "../../domain/prompt_library.dart"
    show authorFrom, authorKeys, nameOf, singleAgentMention, mentionsIn;
import "../../domain/project_settings.dart" show OmadaOrdering;
import "../../domain/shell.dart" show shellBypassCommand;
import "../../domain/wired_skill.dart";
import "../../data/builtin/templates.dart" show passWord;
import "../../providers.dart";

/// Per-chat state container exposed to the UI.
class ChatViewState {
  ChatViewState({
    this.chat,
    this.isRunning = false,
    this.approvals = const {},
    this.questions = const {},
    this.runningSubAgents = const {},
    this.retry,
    this.status,
    this.unfinishedNotice,
    this.shellOutput,
  });
  final Chat? chat;
  final bool isRunning;

  /// What the turn is waiting to be allowed, keyed by the reply that asked
  /// for it — each turn's banner answers its own turn, and a room with two
  /// running shows both.
  final Map<String, List<ToolApproval>> approvals;

  /// What the agent is waiting to be told. Turn-scoped like [approvals]: the
  /// call and the answers are what the conversation keeps.
  final Map<String, List<AskRequest>> questions;

  /// Sub-agents spawned by `task` calls that are still running — delegated
  /// participants at work, shown as room activity. Turn-scoped view state like
  /// [approvals]: the call/result pair is what persists, and these exist only
  /// to drive the activity strip. Keyed by the reply that fanned them out.
  final Map<String, List<SubAgentStartEvent>> runningSubAgents;

  /// Set while the backend is retrying a failed attempt. Transient: it belongs
  /// to the running turn, not to the conversation, so it is never persisted.
  final String? retry;

  /// What the turn is doing, for the row the spinner is on. Transient like
  /// [retry], and null once the reply has started — from there the caret is
  /// what says the turn is alive.
  final String? status;

  /// A notice for the [ResumeBar] when the turn ended resumable — "Step limit
  /// reached" for a step limit, null otherwise. Turn-scoped: not persisted, so
  /// a reload shows the default "Unfinished turn" text.
  final String? unfinishedNotice;

  /// The tail of what a running command has printed. Transient like
  /// [retry]: the call/result pair is what the conversation keeps, so the
  /// block is gone the moment the pair completes.
  final String? shellOutput;

  /// Who may speak now — see [RoomPhase], whose facts "The room's phase is
  /// one answer" in `lib/ui/chat/AGENTS.md` owns.
  RoomPhase get roomPhase => questions.values.any((q) => q.isNotEmpty)
      ? RoomPhase.waitingOnYou
      : isRunning
          ? RoomPhase.agentSpeaking
          : RoomPhase.open;

  ChatViewState copyWith({
    Chat? chat,
    bool? isRunning,
    Map<String, List<ToolApproval>>? approvals,
    Map<String, List<AskRequest>>? questions,
    Map<String, List<SubAgentStartEvent>>? runningSubAgents,
    String? retry,
    bool clearRetry = false,
    String? status,
    bool clearStatus = false,
    String? unfinishedNotice,
    bool clearUnfinishedNotice = false,
    String? shellOutput,
    bool clearShellOutput = false,
  }) =>
      ChatViewState(
        chat: chat ?? this.chat,
        isRunning: isRunning ?? this.isRunning,
        approvals: approvals ?? this.approvals,
        questions: questions ?? this.questions,
        runningSubAgents: runningSubAgents ?? this.runningSubAgents,
        retry: clearRetry ? null : (retry ?? this.retry),
        status: clearStatus ? null : (status ?? this.status),
        unfinishedNotice: clearUnfinishedNotice
            ? null
            : (unfinishedNotice ?? this.unfinishedNotice),
        shellOutput:
            clearShellOutput ? null : (shellOutput ?? this.shellOutput),
      );
}

/// Who may speak in the room — see [ChatViewState.roomPhase].
enum RoomPhase {
  /// Nothing is running; the composer is the user's.
  open,

  /// A turn is running and has not asked anything: the main agent is
  /// speaking, the composer shows Stop.
  agentSpeaking,

  /// A turn is waiting on the user — the composer's place is taken by the
  /// question panel.
  waitingOnYou,
}

/// What a page needs of whatever is driving its turn. [ChatController] for a
/// chat on this device, `MirrorChatController` for one whose home device is a
/// paired peer — the widgets between them are the same either way, and only
/// where the work happens differs.
abstract interface class TurnDriver {
  Future<void> send(String text, {List<Attachment> attachments});
  Future<void> resume();
  Future<void> abort();
  Future<void> respondApproval(String approvalId, ApprovalResponse r,
      {ToolApproval? approval});
  Future<void> answerQuestions(String requestId, List<String?> answers);

  /// Whether an approval answer may write a standing rule here. False for a
  /// mirrored chat: the banner is being answered from the other device, and
  /// the rule is the home device's to write — its banner asks the question,
  /// so offering it twice would be two answers to one call.
  bool get rulesWritable => true;
}

/// Drives a single chat: loads from store, sends prompts, accumulates streamed
/// events into messages, and appends them to the chat's log as they arrive.
class ChatController extends Notifier<ChatViewState> implements TurnDriver {
  ChatController(this.chatId);

  @override
  bool get rulesWritable => true;

  final String chatId;
  final _uuid = const Uuid();

  /// The live turns, keyed by the reply each writes. One today; the table is
  /// what lets a second turn run beside the first without its recorder, its
  /// retry state or its interrupt reaching across — see [_RunningTurn].
  final Map<String, _RunningTurn> _turns = {};

  /// Every recorder's writes funnel through one queue, so two turns appending
  /// to the same log cannot interleave lines. One turn serialises through its
  /// own recorder already; the funnel is for the room with more than one.
  Future<void>? _appendQueue;

  /// Appends [records] to this chat's log behind every append before it.
  Future<void> _append(List<ChatRecord> records) {
    final queued = _appendQueue;
    final repo = ref.read(chatRepositoryProvider);
    return _appendQueue =
        (queued == null ? Future<void>.sync(() => repo.append(chatId, records)) : queued.then((_) => repo.append(chatId, records)))
            .catchError((Object e) {
      // A failed line must not wedge the queue; the lost records get a line.
      logFailure("chat", "could not append to $chatId", e);
    });
  }

  /// Open a turn: its recorder, its completer, and its place in the table.
  _RunningTurn _openTurnEntry(String replyId) {
    final turn = _RunningTurn._(replyId: replyId, done: Completer<TurnEnd?>());
    turn.recorder = TurnRecorder(
        append: _append, onParts: (parts) => _writeReply(turn, parts));
    turn.recorder.open(replyId);
    _turns[replyId] = turn;
    return turn;
  }

  /// Completes with the last [TurnEnd] when every turn in flight now is over
  /// — a fan-out settles as one. A caller that starts a turn through [send]
  /// or [resume] and needs to know when it is done — the reminder runner, a
  /// voice handover — awaits this. Null where nothing is running.
  Future<TurnEnd?>? get turnDone {
    if (_turns.isEmpty) return null;
    return Future.wait([for (final turn in _turns.values) turn.done.future])
        .then((ends) => ends.lastOrNull);
  }

  @override
  ChatViewState build() {
    // The provider is not auto-disposed: clear a controller that outlived its page, or its id re-opens the deleted chat from memory.
    final deletionSub = ref.read(chatRepositoryProvider).changes.listen((event) {
      if (event is Deleted && event.chatId == chatId) state = ChatViewState();
    });
    ref.onDispose(() {
      for (final turn in _turns.values) {
        turn.sub?.cancel();
        turn.recorder.dispose();
      }
      deletionSub.cancel();
    });
    _ready = _load();
    return ChatViewState();
  }

  /// The first read of the chat off disk. **Anything that drives a turn waits
  /// on it**, because a controller is built the moment something asks for it
  /// and driven in the same breath — `createChat` sends the first message,
  /// `RemoteTurnDriver` hands over a peer's — and a turn started before this
  /// lands finds no chat and silently does nothing.
  late Future<void> _ready;

  /// The reply being written. It is always the last message of a running turn.
  Message? get _reply {
    final messages = state.chat?.messages;
    return messages == null || messages.isEmpty ? null : messages.last;
  }

  /// The single running turn, where exactly one is — every path that drives,
  /// stops or watches a turn speaks about it, and a room with two running has
  /// to name which.
  _RunningTurn? get _liveTurn =>
      _turns.length == 1 ? _turns.values.first : null;

  String get replyText => _reply?.plainText ?? "";

  /// Fold [parts] into the message [turn] is writing, by id rather than by
  /// position: the last message is the running turn's only while it is the
  /// only turn, and a second reply growing beside it is not patched by
  /// coincidence.
  void _writeReply(_RunningTurn turn, List<MessagePart> parts) {
    final chat = state.chat;
    if (chat == null) return;
    final at = chat.messages.indexWhere((m) => m.id == turn.replyId);
    if (at < 0) return;
    final messages = List<Message>.from(chat.messages);
    messages[at] = messages[at].copyWith(parts: parts);
    state = state.copyWith(chat: chat.copyWith(messages: messages));
  }

  /// Take a state written elsewhere — the sidebar pinning this chat — in place.
  /// Reloading instead would dispose a running turn. Nothing to do where the
  /// chat is not loaded yet: it reads the same write off disk.
  void applyState(ChatState written) {
    final chat = state.chat;
    if (chat == null) return;
    state = state.copyWith(chat: chat.copyWith(state: written));
  }

  /// Retitle in place, for the same reason.
  void applyTitle(String title) {
    final chat = state.chat;
    if (chat == null) return;
    applyState(chat.state.copyWith(title: title));
  }

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

  Future<void> _load() async {
    try {
      final chat = await ref.read(chatRepositoryProvider).openChat(chatId);
      if (ref.mounted) state = state.copyWith(chat: chat);
    } catch (e) {
      // Deleted under us — swept for its TTL, or removed on a paired device.
      // Left unsaid the page keeps a spinner up with nothing behind it.
      logFailure("chat", "could not open $chatId", e);
    }
  }

  /// The composer's own path: what it is holding becomes files under the chat
  /// before anything else, since from here on a prompt is its parts. Said
  /// while a turn runs, it is appended to the log as it stands and dispatched
  /// when the room settles — the log is the queue.
  ///
  /// A `/skill` flagged `invocation: callback` never reaches here as a prompt:
  /// it is checked before the room's guards, the way the `!` shell bypass is,
  /// and refused while a turn runs rather than queued — a callback mid-turn
  /// is the session the turn is rewriting underneath it. Where it is checked
  /// after that, the turn it runs goes through the room's machinery like any
  /// other, so the spinner, Stop and the composer's rules hold.
  @override
  Future<void> send(String text, {List<Attachment> attachments = const []}) async {
    await _ready;
    if (state.chat == null) return;
    final repo = ref.read(chatRepositoryProvider);
    final wired = wiredSkillFromText(text);
    if (wired != null) {
      if (state.isRunning) {
        state = state.copyWith(
            status: "Wait for the turn to finish before compacting");
        return;
      }
      switch (wired.skill) {
        case WiredSkill.compact:
          await _promptCompacting(wired.arguments);
      }
      return;
    }
    final files = await repo.saveAttachments(chatId, attachments);
    if (state.isRunning) {
      await _sayLater(text, files);
      return;
    }
    await _prompt(text, files: files);
  }

  /// What was said while a turn ran and is still unsaid. The messages are on
  /// the log already — written as they were said — and this is what is left
  /// to say. The composed message itself, so the drain dispatches what the
  /// log holds rather than composing a second one.
  final List<Message> _said = [];

  Future<void> _sayLater(String text, List<MessagePart> files) async {
    final say = ref.read(chatRepositoryProvider).composeUserPrompt(text,
        project: state.chat?.state.project, files: files);
    // The routing record rides the say the moment it lands — the same stamp a
    // fresh send writes where the prompt is not on the log yet.
    final userMsg = state.chat == null
        ? say
        : say.copyWith(
            addressees: _stampedMentions(state.chat!, say));
    // The say lands on the log through the room's one append funnel; state
    // is re-read after the write, so what changed in flight is not ours to
    // revert.
    await _append(recordsOf([userMsg]));
    final chat = state.chat;
    if (chat == null) return;
    state = state.copyWith(
        chat: chat.copyWith(
            messages: [...chat.messages, userMsg],
            state: chat.state.copyWith(updatedAt: DateTime.now())));
    _said.add(userMsg);
    _drainSaid();
  }

  /// What was said while a turn ran, in the order it was said: schedule each,
  /// and dispatch what the room may run now. The schedule is the queue — what
  /// waits sits in its member's FIFO, and the settle that ends the turn
  /// dispatches it ([_endTurn]), so a say for a member already speaking waits
  /// for that member's turn to finish instead of opening a second one beside
  /// it. Both ends of the queue — a say landing while a turn runs, and the
  /// drain a finishing turn runs — read it through this one method. Relay
  /// order drops the room's part of that rule, keeping the member's: the
  /// dispatch runs whatever it may, its per-lane check leaving a say for
  /// a busy member queued while one for an idle member — or for the idle
  /// house — runs at once.
  void _drainSaid() {
    final chat = state.chat;
    if (chat == null) return;
    while (_said.isNotEmpty) {
      final said = _said.removeAt(0);
      // The routing is the stamp: the record the say landed with is the
      // room's answer to who it addressed, and is not re-read from the
      // library while the room runs.
      _schedule(chat, [for (final a in said.addressees) ?nameOf(a)],
          userPrompt: said);
    }
    if (_turns.isNotEmpty && _ordering != OmadaOrdering.relay) return;
    unawaited(_dispatch());
  }

  /// Say [text] and run the turn it starts. [files] are already under the
  /// chat's `resources/`. [replacing] makes it another thread beside a prompt
  /// already in the conversation — an edit — rather than the next thing said.
  ///
  /// The prompt is composed once and schedules from there: what it addresses
  /// runs through the ordering like anything else in the room, one member
  /// turn per mention. [replacing] is the exception — an edit answers for
  /// itself, under whoever the prompt it stands beside named.
  Future<void> _prompt(String text,
      {List<MessagePart> files = const [], Message? replacing}) async {
    final repo = ref.read(chatRepositoryProvider);
    final chat = state.chat;
    if (chat == null || state.isRunning) return;
    final at =
        replacing == null ? chat.messages.length : chat.messages.indexOf(replacing);
    if (at < 0) return;

    final userMsg =
        repo.composeUserPrompt(text, project: chat.state.project, files: files);
    if (replacing != null) {
      await _say(userMsg, replacing: replacing);
      return;
    }
    _schedule(chat, mentioned(chat, userMsg), userPrompt: userMsg);
    await _dispatch();
  }

  /// The `/compact` callback's own turn: the ask goes on the log like anything
  /// said, and the turn is one status row while the summarizer runs — no
  /// model loop, no tools. What it produces is the [CompactionRecord], not a
  /// reply: the divider in the conversation is its whole trace, so the turn
  /// ends with an empty reply and nothing else is ever written into it.
  ///
  /// Reached from [send]'s wired arm, which has already refused while a turn
  /// runs — the guards here are its to carry.
  Future<void> _promptCompacting(String arguments) async {
    final chat = state.chat;
    if (chat == null) return;
    final userMsg = ref
        .read(chatRepositoryProvider)
        .composeUserPrompt("/compact${arguments.isEmpty ? "" : " $arguments"}",
            project: chat.state.project);
    await _say(userMsg);
  }

  /// The compact turn's body, driven from [openTurn] by the wired check on
  /// the prompt. The turn is already open — the entry seated, the prompt and
  /// its empty reply logged — so this runs the summarizer, writes the marker,
  /// and ends the turn the way any event stream would have. Shaped like the
  /// loop's end so `isRunning`, Stop and the settle rules hold over it.
  Future<void> _runCompactTurn(
      _RunningTurn turn, String arguments) async {
    // The wait says what it is: a summarizer over a long conversation is a
    // read of minutes, and a spinner that cannot be told apart from a hang is
    // the row that says nothing.
    state = state.copyWith(status: "Compacting the conversation");
    try {
      await _applyCompaction(instructions: arguments.trim().isEmpty ? null : arguments.trim());
    } catch (e) {
      logFailure("compact", "compact turn failed", e);
    } finally {
      // Unconditional, like the stream path's onDone: the finish is
      // idempotent and `_endTurn` guards its own state, and a turn disposed
      // mid-run still writes its `turnEnd` rather than reading as killed.
      await _finishTurn(turn);
    }
  }

  /// The tail every compaction shares: ask the summarizer, then land the
  /// marker through the repository — whose `_rethread` walk is the one copy
  /// of append/reload/rebuild, reached through this controller's own
  /// reentrancy-guarded wrapper so a thread move racing the summarizer
  /// resolves rather than interleaves.
  ///
  /// [recheck] is the auto path's answer to the minutes the summarizer
  /// takes: the room is settled when it starts, and may not be when it ends —
  /// a turn starting while it ran is the session the landing would kill
  /// (`resetSession` stops whatever is running) and rewrite underneath. Where
  /// it is true, the landing is skipped whole — no marker, so the next settle
  /// may retry. The manual compact turn is its own running turn and lands
  /// unconditionally.
  Future<void> _applyCompaction(
      {required String? instructions, bool recheck = false}) async {
    final chat = state.chat;
    final result = chat == null
        ? null
        : await ref.read(chatRepositoryProvider).compact(chatId,
            history: chat.messages,
            compactions: chat.compactions,
            instructions: instructions);
    if (!ref.mounted || result == null || (recheck && state.isRunning)) return;
    // The wrapper's own guard is the reentrancy flag, and it sets the chat on
    // the way through — so nothing to hand back here.
    await _rethread((repo) {
      return repo.appendCompaction(chatId,
          upToMessageId: result.upToMessageId, summary: result.summary);
    });
  }

  /// Open the turn [userMsg] starts, whether it is being composed now or was
  /// said while the room ran and is already on the log. Where it is not on the
  /// log yet — a fresh send — it rides in [opening]; where it is, the opening
  /// is the reply alone and [history] ends before it, since the message is
  /// already the last thing said. [member] is who the room has decided
  /// answers it, where scheduling decided ahead of the prompt. No guard on
  /// the room here: dispatching a fan-out is what puts several turns in
  /// flight, and the verbs that need the guard carry their own.
  Future<void> _say(Message userMsg,
      {Message? replacing, String? member, int generation = 0}) async {
    final chat = state.chat;
    if (chat == null) return;
    final logged = replacing == null && chat.messages.contains(userMsg);
    final at = logged
        ? chat.messages.indexOf(userMsg)
        : replacing == null
            ? chat.messages.length
            : chat.messages.indexOf(replacing);
    if (at < 0) return;
    // Scheduling that named the member stamps them directly; a fresh send
    // reads the address off what composing wrote into the message.
    final author = member != null
        ? "${CompletionKind.agent.trigger}$member"
        : authorFor(chat, userMsg);
    await openTurn(
      chat: chat,
      prompt: userMsg,
      history: chat.messages.take(at).toList(),
      opening: [
        if (!logged) userMsg,
        _newReply(author: author),
      ],
      replacing: replacing,
      omadaMember: member,
      generation: generation,
    );
  }

  /// Open a turn: put the messages it starts with in the conversation and in
  /// the log, then hand the prompt to the backend.
  ///
  /// [opening] is what the turn writes — the prompt and its empty reply, or the
  /// reply alone where the prompt is already there. [history] is the
  /// conversation the model is answering, which does not include the prompt:
  /// `sendPrompt` adds that itself. [replacing] is the message [opening] is an
  /// alternative to, and null when this is simply the next thing said.
  /// [omadaMember] is who the room has decided answers it, where scheduling
  /// decided ahead of the prompt — a dispatched item — rather than from it.
  /// [generation] is the dispatch wave the turn belongs to, on the entry for
  /// the handoff that reads it.
  Future<void> openTurn({
    required Chat chat,
    required Message prompt,
    required List<Message> history,
    required List<Message> opening,
    Message? replacing,
    String? omadaMember,
    int generation = 0,
  }) async {
    final repo = ref.read(chatRepositoryProvider);
    final omada = ref.read(omadaOnProvider(chat.state.project));
    // The routing record rides the say where it is written — a fresh send's
    // or an edit's say, stamped the one time here and the same copy logged
    // and sent; a say already on the log keeps the record the room made
    // where it landed, the way [omadaOn] is kept, since a member the library
    // lost since does not rewrite the room's past.
    final logged = chat.messages.contains(prompt);
    final say = logged
        ? prompt
        : prompt.copyWith(omadaOn: omada, addressees: _stampedMentions(chat, prompt));
    // The room's mode at this turn, stamped on the turn's opener: the page
    // derives sections from these stamps, a separator above an opener that
    // flips from the last one. The implicit off a chat starts in is not a
    // section — nothing separates the first exchange from a chat that never
    // heard of Omada — so the first flip is the on-flip; the off-flip is
    // what bounds an on-section for the label rule.
    final openingWithMode = [
      identical(opening.first, prompt)
          ? say
          : opening.first.copyWith(omadaOn: omada),
      ...opening.sublist(1),
    ];
    final updated = chat
        .withTurn(openingWithMode, replacing: replacing)
        .copyWith(state: chat.state.copyWith(updatedAt: DateTime.now()));

    final isFirst = chat.messages.isEmpty;
    state = state.copyWith(chat: updated, isRunning: true, clearRetry: true, clearStatus: true);
    // The prompt and the empty reply go down before the turn starts, so a chat
    // killed before the model says anything still shows what was asked. What
    // comes back carries the TTL anchor the save resolved, and is kept.
    // The entry takes its seat **before** the save: a sibling settling while
    // it is in flight would read the room as settled and hand off from a
    // wave still opening.
    final turn = _openTurnEntry(opening.last.id);
    turn.retryable = false;
    turn.errorLine = "";
    turn.round = 0;
    turn.generation = generation;
    // Resolved once: the entry's stamp — what relay's busy lane reads — and
    // the parameter the backend records are the same fact.
    final member = omadaMember ?? _memberAnswering(chat, prompt);
    turn.omadaMember = member;
    applyState(await repo.saveState(updated.state));
    await turn.recorder.write(recordsOf(openingWithMode,
        siblingOf: replacing?.id,
        replacing: replacing != null && !chat.worthAThread(replacing)));
    // Only the first message names the chat, and not a headless one — the
    // reminder already named it. The list is not refreshed here: the chat was
    // written, and listed, when it was created — and refreshing re-reads every
    // chat off disk to draw the row it already has.
    if (isFirst) unawaited(_maybeNameChat(prompt.plainText));

    // Invalidated mid-turn — a chat moved while one was starting. The move
    // aborted whatever was running, so this turn never starts; there is
    // nothing to abort here and nothing to write beside the move.
    if (!ref.mounted) return;
    // A callback's turn is run here rather than sent to the backend: the
    // compact machinery is the controller's to drive, and the turn ends with
    // the marker it writes rather than an event stream. The turn is already
    // open, the entry seated and logged above, so this is the body where the
    // backend's own would have been. The dispatch switches on the skill, the
    // way send did — adding a wired skill is an enum entry and an arm here.
    final wired = prompt.role == MessageRole.user
        ? wiredSkillFromText(prompt.plainText)
        : null;
    if (wired != null) {
      switch (wired.skill) {
        case WiredSkill.compact:
          unawaited(_runCompactTurn(turn, wired.arguments));
      }
      return;
    }
    _listen(turn, repo.sendPrompt(chatId, say,
        history: history,
        compactions: chat.compactions,
        replaces: replacing != null,
        omadaMember: member));
  }

  /// The member a turn is answered by: the one the project's Omada addresses
  /// through [prompt] — a user prompt names them in its documents, a member's
  /// reply names the next one in its text. Decided against what the library
  /// holds now; null is the main agent. The answer is not authorship: what
  /// names the author is [Message.author], stamped where the turn opens, and
  /// a member's reply is still role `assistant`. See "The room and its
  /// participants" in `lib/ui/chat/AGENTS.md`.
  String? _memberAnswering(Chat chat, Message prompt) {
    if (!ref.read(omadaOnProvider(chat.state.project))) return null;
    final named = prompt.role == MessageRole.assistant
        ? _mentionIn(chat, prompt)
        : _memberIfKnown(chat, nameOf(authorFor(chat, prompt)));
    return named;
  }

  /// The member [name] answers for, where the library still knows them — an
  /// unknown name is prose, not an address. Null is the main agent.
  String? _memberIfKnown(Chat chat, String? name) {
    if (name == null) return null;
    return ref
            .read(promptLibraryProvider(chat.state.project))
            .find(CompletionKind.agent, name) ==
        null
        ? null
        : name;
  }

  /// Who a turn opened on [prompt] names as its author, where the project
  /// runs Omada: the one member the prompt addresses. A command is not
  /// addressed to anyone, whatever its text names — `!grep @researcher` runs
  /// a command, it does not ask researcher to speak — and a callback is not
  /// addressed at all: `/compact @researcher` compacts, it does not hand the
  /// floor over. Omada off never stamps: the reply is the main agent's, and a
  /// label on it would claim a member authored what is the house's voice.
  /// See "The contract between direct and Omada chats" in `lib/ui/chat/AGENTS.md`.
  String? authorFor(Chat chat, Message prompt) =>
      !ref.read(omadaOnProvider(chat.state.project)) ||
              shellBypassCommand(prompt.plainText) != null ||
              wiredSkillFromText(prompt.plainText) != null
          ? null
          : authorFrom(prompt.documents);

  /// The turn's reply. Always role `assistant` — the role is the render
  /// class, not the author; [Message.author] is what names them.
  Message _newReply({String? author}) => Message(
        id: _uuid.v4(),
        role: MessageRole.assistant,
        createdAt: DateTime.now(),
        parts: const [],
        author: author,
      );

  /// Carry on the turn the chat was cut off in. What this produces goes on the
  /// end of the reply that is already there, closed by a second [TurnEndRecord]
  /// when it finishes.
  @override
  Future<void> resume() async {
    await _ready;
    if (state.isRunning) return;
    final chat = state.chat;
    if (chat == null || !chat.unfinished) return;
    // The user re-engaging is a new patience: their budget starts over, the
    // way a fresh send's would.
    _liveTurn?.round = 0;
    await _startResume();
  }

  /// The body of [resume] without its guards, so the automatic retry rounds
  /// take the same path the user's Continue button does. The chat is checked
  /// where the caller can still read its answer; the reply is re-read here
  /// because a round sees a chat the previous round just wrote to.
  ///
  /// [replyId] names the reply, and is what the retry branch passes: the
  /// round belongs to one turn, and a room still running another — a
  /// sibling's reply streaming below — must not have this round re-open the
  /// sibling's recorder. Null keeps the old rule, the last assistant message
  /// — a say queued while the round ran (or a sibling reply, under
  /// overlapping turns) can sit below this turn's own.
  Future<void> _startResume({String? replyId}) async {
    final chat = state.chat;
    final reply = replyId == null
        ? chat!.messages.lastWhereOrNull(_resumableReply)
        : chat!.messages
            .firstWhereOrNull((m) => m.id == replyId && _resumableReply(m));
    if (reply == null) return;

    state = state.copyWith(isRunning: true, clearRetry: true, clearStatus: true);
    // Kept open across the round: a caller awaiting [turnDone] gets one
    // completion, at the true end, not one per attempt.
    final turn = _turns[reply.id] ?? _openTurnEntry(reply.id);
    turn.interrupted = false;
    turn.finishing = false;
    // The fresh entry has no lane of its own: the Continue path is what runs
    // a member's turn again, and the field is what relay's busy lane reads.
    turn.omadaMember ??= _memberIfKnown(chat, nameOf(reply.author));
    turn.recorder.open(reply.id, existing: reply.parts);

    _listen(turn, ref.read(chatRepositoryProvider).resumeTurn(chatId,
        history: chat.messages,
        compactions: chat.compactions,
        omadaMember: _memberIfKnown(chat, nameOf(reply.author))));
  }

  /// What a turn can be carried on from: an assistant's reply, never a
  /// command's — see "Carrying on an interrupted turn" for why a command is
  /// left out.
  static bool _resumableReply(Message m) =>
      m.role == MessageRole.assistant &&
      shellBypassCommand(m.plainText) == null &&
      wiredSkillFromText(m.plainText) == null;

  void _listen(_RunningTurn turn, Stream<AgentEvent> stream) {
    turn.sub = stream.listen(
        (event) => _onEvent(turn, event),
        onDone: () => _finishTurn(turn),
        onError: (Object e) => _onError(turn, e));
  }

  /// The user message that produced [messageId] — itself when it is one,
  /// otherwise the closest one above it.
  Message? _promptFor(Chat chat, String messageId) {
    final from = chat.messages.indexWhere((m) => m.id == messageId);
    if (from < 0) return null;
    final at = chat.messages.lastIndexWhere((m) => m.role == MessageRole.user, from);
    return at < 0 ? null : chat.messages[at];
  }

  /// The reply [messageId] names — itself when it is one, otherwise the first
  /// one under it. Null where the turn has none, which is a prompt whose only
  /// reply has been deleted.
  Message? _replyFor(Chat chat, String messageId) {
    final from = chat.messages.indexWhere((m) => m.id == messageId);
    if (from < 0) return null;
    final at = chat.messages.indexWhere((m) => m.role == MessageRole.assistant, from);
    return at < 0 ? null : chat.messages[at];
  }

  /// Resend a message with new text, as another thread beside it. The file
  /// parts come across as they are: the resources are already under this chat,
  /// and branching leaves the message they belong to where it is.
  Future<void> editAndResend(String messageId, String text) async {
    final chat = state.chat;
    if (chat == null || state.isRunning) return;
    final prompt = _promptFor(chat, messageId);
    if (prompt == null) return;
    await _prompt(text, files: prompt.files.toList(), replacing: prompt);
  }

  /// Run the turn again, as another thread beside the reply already there.
  ///
  /// The prompt is not written a second time: it is the branch point, so the
  /// counter lands under the reply — which is the message the arrows move
  /// between. Works from either side of the exchange, and carries on the end
  /// where the reply it would have branched from has been deleted.
  Future<void> regenerate(String messageId) async {
    final chat = state.chat;
    if (chat == null || state.isRunning) return;
    final prompt = _promptFor(chat, messageId);
    if (prompt == null) return;
    await openTurn(
      chat: chat,
      prompt: prompt,
      history: chat.messages.take(chat.messages.indexOf(prompt)).toList(),
      opening: [_newReply(author: authorFor(chat, prompt))],
      replacing: _replyFor(chat, messageId),
    );
  }

  /// Read the thread beside the one [messageId] is on. [step] is -1 or 1 — the
  /// arrows under the message.
  Future<void> stepThread(String messageId, int step) async {
    final chat = _rethreadable;
    final to = chat?.threadBeside(messageId, step);
    if (chat == null || to == null) return;
    await _rethread((repo) => repo.selectThread(chat, to));
  }

  /// Delete the thread [messageId] heads, and everything below it.
  Future<void> deleteThread(String messageId) async {
    final chat = _rethreadable;
    if (chat == null) return;
    await _rethread((repo) => repo.deleteThread(chat, messageId));
  }

  /// The conversation a thread change can be worked out from, or null where
  /// there is none to make. An earlier change still in flight is one of those:
  /// it is about to replace the conversation this one would be computed from,
  /// so a held-down arrow would issue a reload per frame against state that no
  /// longer holds.
  Chat? get _rethreadable => state.isRunning || _rethreading ? null : state.chat;
  bool _rethreading = false;

  Future<void> _rethread(Future<Chat> Function(ChatRepository repo) change) async {
    _rethreading = true;
    try {
      final now = await change(ref.read(chatRepositoryProvider));
      if (ref.mounted) state = state.copyWith(chat: now);
    } finally {
      _rethreading = false;
    }
  }

  void _onEvent(_RunningTurn turn, AgentEvent event) {
    if (_reply == null) return;

    turn.recorder.handle(event);
    switch (event) {
      // What the recorder already turned into parts. Listed rather than
      // defaulted, so a new kind of event has to be decided about here too.
      case ResponseStart():
      case TextDelta():
      case ReasoningDelta():
      case ReasoningEnd():
      case ToolCallEvent():
      case ArtifactEvent():
      case SkillInstallEvent():
      case InstructionsReadEvent():
        break;
      case ToolResultEvent():
      case ShellRunEvent():
        // The pair completing is the live block's end: the result and the
        // run part are what the conversation keeps of the output from here.
        state = state.copyWith(clearShellOutput: true);
        break;
      case ErrorEvent(:final message, :final retryable):
        // Whether the round can carry the turn on from this, and the first
        // line for the retry row and the failure notification. Both are
        // turn-scoped view state: the error part is what the conversation
        // keeps, and neither field outlives the turn.
        turn.retryable = retryable;
        final lineAt = message.indexOf("\n");
        turn.errorLine = lineAt < 0 ? message : message.substring(0, lineAt);
        break;
      case StepLimitEvent():
      case InfoEvent():
        break;
      case ApprovalRequestEvent(:final approval):
        state = state.copyWith(
            approvals: {
              ...state.approvals,
              turn.replyId: [...state.approvals[turn.replyId] ?? [], approval]
            });
      case QuestionRequestEvent(:final request):
        state = state.copyWith(questions: {
          ...state.questions,
          turn.replyId: [...state.questions[turn.replyId] ?? [], request]
        });
      case SubAgentStartEvent():
        state = state.copyWith(runningSubAgents: {
          ...state.runningSubAgents,
          turn.replyId: [
            ...(state.runningSubAgents[turn.replyId] ?? []),
            event
          ]
        });
      case SubAgentEndEvent(:final id):
        state = state.copyWith(runningSubAgents: {
          for (final entry in state.runningSubAgents.entries)
            entry.key: entry.value.where((s) => s.id != id).toList()
        });
      case RetryEvent(:final attempt, :final message):
        state = state.copyWith(retry: "Attempt $attempt failed: $message");
      case ShellOutputEvent(:final text):
        // The live view of a command's output, for the block under the label.
        // Cleared where the pair completes, in the cases above.
        state = state.copyWith(shellOutput: text);
      case StatusEvent(:final label):
        state = label == null
            ? state.copyWith(clearStatus: true)
            : state.copyWith(status: label);
      case DoneEvent(:final aborted):
        if (aborted) turn.recorder.outcome ??= TurnEnd.aborted;
        state = state.copyWith(clearShellOutput: true);
        _finishTurn(turn);
    }
  }

  /// The turn is over when it has been written, not when the last event
  /// arrives. Writing is asynchronous — a browser's filesystem cannot be
  /// anything else — so returning before the queue drains would report a
  /// finished turn whose last records are still in flight, and closing the app
  /// in that window would lose them. A write that fails still has to clear
  /// [isRunning], or the composer stays disabled with nothing running.
  ///
  /// The terminal record is the point of this: a log whose last message has no
  /// [TurnEndRecord] was being written when the process died, and that absence
  /// is the only thing that can tell a reload the difference.
  Future<void> _finishTurn(_RunningTurn turn) async {
    // Whoever lands first drives the finish; the rest await its future, so a
    // stop during the retry backoff resolves at the true end, not the guard.
    if (turn.finishing) return turn.finishingFuture;
    turn.finishing = true;
    turn.finishingFuture = _driveTurnToEnd(turn);
    await turn.finishingFuture;
  }

  Future<void> _driveTurnToEnd(_RunningTurn turn) async {
    turn.sub?.cancel();
    turn.sub = null;
    // A banner the turn left outstanding was answered deny on its way out —
    // the backend completes it as one — and the record says so, rather than
    // leaving a question nobody ever answered in the log. An interrupted turn
    // records nothing: the turn itself is the open question.
    if (!turn.interrupted) {
      for (final approval in state.approvals[turn.replyId] ?? const []) {
        turn.recorder.recordApprovalAnswer(approval.id, "deny");
      }
    }
    // Null is a turn that was interrupted rather than ended — the log has no
    // closing record, and `?? true` below is the same thing its reader makes
    // of one. See "Carrying on an interrupted turn".
    final TurnEnd? reason;
    if (turn.interrupted) {
      await turn.recorder.interrupt();
      // An interruption is the app going away, not a round ending: what was
      // said stays unsaid, the Continue path carrying the turn on — not
      // dispatched here, which would open a fresh turn mid-teardown.
      _said.clear();
      _schedules.clear();
      reason = null;
    } else {
      reason = await turn.recorder.close();
    }
    // A retryable failure is a blip the turn is carried on from, not an
    // outcome to report: the round waits out its backoff and re-enters the
    // same resume the user's Continue button takes. The wait holds nothing —
    // the user pressing stop has to reach it first, which is what the
    // generation is for. The turn's completer stays open across rounds, so a
    // caller awaiting [turnDone] — the reminder runner, voice — gets one
    // completion, at the true end. The entry stays in the table across the
    // rounds — a retry re-opens this entry's recorder, not a fresh one whose
    // completer nobody holds — and leaves the table only at the true end.
    if (reason == TurnEnd.error &&
        turn.retryable &&
        turn.round < _roundsTotal) {
      final gen = turn.retryGen;
      final round = turn.round;
      turn.round++;
      final wait = Duration(seconds: (1 << round).clamp(1, 30));
      if (!ref.mounted) return;
      state = state.copyWith(
        retry: "Retrying (${turn.round}/$_roundsTotal) — ${turn.errorLine}",
        approvals: _withoutTurn(state.approvals, turn.replyId),
        questions: _withoutTurn(state.questions, turn.replyId),
        runningSubAgents:
            _withoutTurn(state.runningSubAgents, turn.replyId),
      );
      await Future<void>.delayed(wait);
      if (turn.retryGen != gen) {
        // A stop cut the wait short: still an ending, not a stranded entry.
        await _endTurn(turn, turn.interrupted ? null : turn.recorder.outcome);
        return;
      }
      if (!ref.mounted) return;
      // A deleted chat has nothing to carry on.
      if (state.chat == null) return;
      await _startResume(replyId: turn.replyId);
      return;
    }
    await _endTurn(turn, reason);
  }

  /// The turn's true end: out of the table, the state the ending leaves, the
  /// completer completed, the round's bookkeeping put away. The retry branch
  /// returns here when its wait is cut short — a stop while the backoff runs
  /// is still an ending, whoever's finish reaches it first.
  Future<void> _endTurn(_RunningTurn turn, TurnEnd? reason) async {
    if (!ref.mounted) return;
    final done = turn.done;
    _turns.remove(turn.replyId);
    // The settle reads how deep the round ran when this turn finished; the
    // entry is leaving the table, so the fact stays behind.
    _finishedGenerations[turn.replyId] = turn.generation;
    // Nothing is left to answer once the turn is over: the backend has already
    // answered its own outstanding questions with nothing, so a banner or a
    // panel still on screen would send its reply into the void. Only this
    // turn's — a sibling still running keeps its own.
    state = state.copyWith(
      // What a reload would now make of the log, so a turn that gave up is
      // offered straight away rather than only once the chat is opened again.
      chat: state.chat?.copyWith(unfinished: reason?.resumable ?? true),
      isRunning: _turns.isNotEmpty,
      approvals: _withoutTurn(state.approvals, turn.replyId),
      questions: _withoutTurn(state.questions, turn.replyId),
      runningSubAgents: _withoutTurn(state.runningSubAgents, turn.replyId),
      clearRetry: _turns.isEmpty,
      clearStatus: _turns.isEmpty,
      unfinishedNotice: reason == TurnEnd.stepLimit
          ? "Step limit reached"
          : null,
    );
    done.complete(reason);
    await _notifyFailure(reason, turn.errorLine);
    if (reason == TurnEnd.aborted || reason == TurnEnd.error) {
      // An aborted round is a stopped one: the unsaid is dropped, and a
      // sibling's parked reply goes with it rather than handing off from a
      // round the user stopped.
      _said.clear();
      _schedules.clear();
      _settledReplies.clear();
      _finishedGenerations.clear();
      return;
    }

    // The room has settled: what was said while it spoke is said next, in
    // the order it was said. Said messages schedule their members the same
    // way anything else does, so a mention in one runs through the ordering
    // like a handoff's does. Handoffs read the room only once the schedule
    // holds nothing — the user's own words dispatch ahead of the agents'.
    _drainSaid();
    // The context this turn left behind is the one thing that grows without
    // being said. Checked here, where the turn is over and the session is
    // settled, rather than mid-turn — the summarizer cannot run over a
    // session the loop is still rewriting. The number is the backend's own
    // reading of what its last request weighed.
    if (reason == TurnEnd.done) _maybeAutoCompact();
    // The settle runs whatever the schedule may run now: what it left — a
    // second item for a member whose first is still queued, the cap's —
    // dispatches at the settles it causes. This reply hands off with them,
    // parked for the settle that ends the wave, rather than now.
    await _settle(turn, reason);
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
      await _applyCompaction(instructions: null, recheck: true);
    } catch (e) {
      logFailure("compact", "auto-compact failed", e);
    }
  }

  /// A turn has ended: the room may hand off. Under the wave orderings the
  /// schedule may still hold what the settle will not run now — an item the
  /// cap stops, or a member's second item behind one still running — and
  /// this turn's reply hands off with the wave, parked for the settle that
  /// ends it, rather than waiting on a schedule that will not drain this
  /// settle. Where siblings were still speaking when this turn finished, its
  /// reply is already waiting in `_settledReplies` — handoffs evaluate at the
  /// settle, against every reply that finished the wave, not only the last
  /// one written. Relay order is the one rule without that wait: nothing
  /// parks, so the reply below is this turn's own and the per-lane check at
  /// dispatch is what holds "one turn per member" against it.
  Future<void> _settle(_RunningTurn turn, TurnEnd? reason) async {
    if (_turns.isNotEmpty && _ordering != OmadaOrdering.relay) {
      // A sibling is still speaking: this reply hands off when the room
      // settles, not now — the wave waits, whatever order the siblings
      // finished in.
      if (reason == TurnEnd.done) _settledReplies.add(turn.replyId);
      return;
    }
    final chat = state.chat;
    if (chat == null) return;
    // The room is settled (or relay, which never waits): every reply the
    // wave finished hands off in conversation order, the order they were
    // said — this turn's own first, where it finished the wave. Under relay
    // the list is this turn's own, and what a prior wave parked is drained
    // rather than stranded when the user flips the ordering mid-round.
    final ids = [..._settledReplies, if (reason == TurnEnd.done) turn.replyId];
    _settledReplies.clear();
    _finishedGenerations.removeWhere(
        (id, _) => !ids.contains(id));
    final replies = [
      for (final id in ids)
        chat.messages.firstWhereOrNull((m) => m.id == id),
    ].whereType<Message>().toList();
    await _maybeHandoff(reason, replies);
    // Whatever the schedule may run now, runs: a queued say, a handoff just
    // scheduled, or a member's next item behind one still queued. The
    // handoff's own gate decides what was scheduled, not what runs — an
    // off-Omada room's queued says and what a failure leaves queued drain
    // through here all the same.
    await _dispatch();
  }

  /// The replies of turns that finished while a sibling was still speaking,
  /// in finish order: their handoffs wait for the settle this one causes.
  final List<String> _settledReplies = [];

  /// What finished replies hand the baton to. A reply that names members —
  /// each turn ended `done`, nothing a failure leaves carrying — has their
  /// turns scheduled, the room's round, until the generation cap says the
  /// agents have had the floor long enough. The mentions are read off each
  /// reply's text against the library — the members named *now* are the ones
  /// handed to, the room's own wording — and scheduled through the same
  /// [_dispatch] path every turn takes.
  ///
  /// Under relay the entry is spent here: the schedule may run the handoff
  /// while other turns are still in flight, and the entry behind this call
  /// is this turn's own, so waiting for a wave's cleanup would hold a
  /// generation the next wave reads as deeper than it ran.
  Future<void> _maybeHandoff(
      TurnEnd? reason, List<Message> replies) async {
    if (reason != TurnEnd.done) return;
    if (!ref.mounted) return;
    final chat = state.chat;
    if (chat == null) return;
    // Omada off is the room as it always was: nothing hands anything to
    // anyone, whatever a reply's text happens to name.
    if (!ref.read(omadaOnProvider(chat.state.project))) return;
    // A decline ends what agents are handing each other: the user's own
    // schedule is not theirs to cancel, so an item the user put there (its
    // prompt, not a reply) survives wherever it sits in the queue.
    for (final reply in replies) {
      if (_isPass(reply)) {
        for (final member in _schedules.keys.toList()) {
          final items = _schedules[member]!;
          final kept = items.where((item) => item.reply == null).toList();
          if (kept.isEmpty) {
            _schedules.remove(member);
          } else {
            _schedules[member] = kept;
          }
        }
        continue;
      }
      // The wave lands one past the turn that named it: the round's depth is
      // the finished turn's own, and the cap reads it at dispatch. The entry
      // is out of the table by now — the finished turn's own is what counts.
      final finished = _finishedGenerations[reply.id] ?? 0;
      _schedule(chat, mentioned(chat, reply),
          reply: reply, generation: finished);
    }
  }

  /// How deep the round ran when each reply finished, kept for the settle
  /// that reads it — the turn entries are gone from the table by then.
  final Map<String, int> _finishedGenerations = {};

  /// The members [message] addresses, in the order it names them — a user
  /// prompt through what composing wrote into its documents, a member's
  /// reply through its text. Names the library does not know are prose,
  /// not an address, a command is addressed to no one it names —
  /// `!grep @researcher` runs a command, it does not ask researcher to
  /// speak — and a callback is addressed to no one either: `/compact` is the
  /// house's own turn. A direct chat addresses no one at all: Omada off is
  /// the room as it always was, the house answering whatever is said. The
  /// sigil is off what comes back: a schedule is keyed by the library's
  /// name for the member.
  List<String> mentioned(Chat chat, Message message) {
    if (!ref.read(omadaOnProvider(chat.state.project)) ||
        shellBypassCommand(message.plainText) != null ||
        wiredSkillFromText(message.plainText) != null) {
      return const [];
    }
    return message.role == MessageRole.user
        ? authorKeys(message.documents)
            .map(nameOf)
            .whereType<String>()
            .where((name) => _memberIfKnown(chat, name) != null)
            .toList()
        : mentionsIn(message.plainText,
            ref.read(promptLibraryProvider(chat.state.project)));
  }

  /// The routing record a say carries: [mentioned]'s answer, sigils on — the
  /// as-typed dialect the author stamp and the mention documents keep, and
  /// the one the projection words addresses and identities in.
  List<String> _stampedMentions(Chat chat, Message message) => [
        for (final member in mentioned(chat, message))
          "${CompletionKind.agent.trigger}$member",
      ];

  /// The room's scheduling. `_schedules` is one FIFO per member of what they
  /// have been addressed to run; a member runs one turn at a time and reads
  /// the next item when the room settles. An item is either a user prompt —
  /// already on the log where it was said while the room ran — or a handoff,
  /// the reply that names them. The null key is the main agent, who answers
  /// what no member was addressed for. [generation] is the dispatch wave the
  /// item belongs to: zero is the user's own and uncapped, a handoff lands
  /// one past the reply that names it.
  final Map<String?, List<_Scheduled>> _schedules = {};

  /// One dispatch at a time; a second arriving mid-[openTurn] asks for a
  /// pass rather than running one beside it.
  bool _dispatching = false;

  /// Whether a dispatch was asked while one ran.
  bool _dispatchPending = false;

  void _schedule(Chat chat, List<String> members,
      {Message? userPrompt, Message? reply, int generation = 0}) {
    if (members.isEmpty) {
      // Nobody addressed: the main agent's, and only a user prompt makes
      // one — a reply that names nobody is the round ending, not the house
      // speaking unprompted.
      if (userPrompt != null) {
        (_schedules[null] ??= [])
            .add(_Scheduled(userPrompt: userPrompt, generation: generation));
      }
      return;
    }
    for (final member in members) {
      (_schedules[member] ??= []).add(_Scheduled(
          userPrompt: userPrompt,
          reply: reply,
          generation: reply == null ? generation : generation + 1));
    }
  }

  /// Run what the schedule holds. Sequential order runs one item at a time —
  /// the first of the schedule, whatever member it names — and what follows
  /// dispatches at the settle it causes. Parallel order answers with one
  /// turn per member at once, each FIFO's head: one turn per member still
  /// stands, and what is left dispatches at the settle they cause.
  ///
  /// A dispatched item is gone from its FIFO before the turn opens, so a
  /// settle re-entering while the turn runs finds the schedule behind it and
  /// not the item running. Re-entering is real — a say landing mid-[openTurn]
  /// reads the same queue — so a second call asks for a pass rather than
  /// running two sequential items at once.
  Future<void> _dispatch() async {
    if (_dispatching) {
      _dispatchPending = true;
      return;
    }
    _dispatching = true;
    try {
      await _dispatchPass();
      while (_dispatchPending) {
        _dispatchPending = false;
        await _dispatchPass();
      }
    } finally {
      _dispatching = false;
    }
  }

  /// One pass over the schedule, serving any dispatch asked while it ran.
  Future<void> _dispatchPass() async {
    final parallel = _ordering == OmadaOrdering.parallel;
    // The cap counts dispatch waves of agent-to-agent work: an item in its
    // generation or under is the user's own and never blocked, one past it
    // is the round's and the cap stops the wave.
    final max = _maxGenerations;
    var dispatched = false;
    for (final member in _schedules.keys.toList()) {
      final items = _schedules[member];
      if (items == null || items.isEmpty) {
        if (items != null) _schedules.remove(member);
        continue;
      }
      // The cap stops a member's handoff wave, not the user's words: a capped
      // head is dropped and the generation zero item behind it kept.
      final item = items.first;
      if (item.generation > 0 && item.generation >= max) {
        items.removeAt(0);
        if (items.isEmpty) _schedules.remove(member);
        continue;
      }
      // Sequential runs one item at a time, and parallel and relay run one
      // per lane — relay's extra rule is the busy check below, not a
      // one-per-pass limit. The item is off its FIFO either way before the
      // turn opens.
      final busy = {for (final turn in _turns.values) turn.omadaMember};
      if (!parallel && _ordering != OmadaOrdering.relay && dispatched) continue;
      if (_ordering == OmadaOrdering.relay && busy.contains(member)) continue;
      items.removeAt(0);
      if (items.isEmpty) _schedules.remove(member);
      dispatched = true;
      await _run(member, item);
    }
  }

  /// Open the turn one scheduled item runs as. [member] null is the main
  /// agent's; a handoff's prompt is the reply that names the member, already
  /// in the conversation.
  Future<void> _run(String? member, _Scheduled item) async {
    final prompt = item.userPrompt;
    final reply = item.reply;
    if (prompt != null) {
      await _say(prompt, member: member, generation: item.generation);
      return;
    }
    final chat = state.chat;
    if (chat == null || reply == null) return;
    await openTurn(
      chat: chat,
      prompt: reply,
      // The conversation the member answers ends before the reply that hands
      // to them: `sendPrompt` adds the prompt itself, and history holding it
      // too would have the member read their mentioning reply twice.
      history: chat.messages.take(chat.messages.indexOf(reply)).toList(),
      // The next reply is authored by the member handed to. The stamp
      // carries the sigil, the way every author stamp does.
      opening: [_newReply(author: "${CompletionKind.agent.trigger}$member")],
      omadaMember: member,
      generation: item.generation,
    );
  }

  /// The room's scheduling order: the project's pick, else the app default,
  /// else sequential — the answer a room that never heard of the setting
  /// runs under.
  OmadaOrdering get _ordering {
    final project = state.chat?.state.project;
    return ref.read(projectSettingsProvider(project)).omadaOrdering ??
        ref.read(appSettingsProvider).omadaOrdering ??
        OmadaOrdering.sequential;
  }

  /// The one member [reply] names by handle, as the composer's own
  /// `_mention` reads one. Null where it names none, or more than one — a
  /// multi-mention is a round, and rounds are not sequential handoffs.
  String? _mentionIn(Chat chat, Message reply) =>
      singleAgentMention(reply.plainText,
          ref.read(promptLibraryProvider(chat.state.project)));

  /// Whether a reply says nothing but that its author passes: word for word,
  /// so a longer reply is a reply and the convention is unambiguous.
  bool _isPass(Message reply) => reply.plainText.trim() == passWord;

  /// How deep the agent-to-agent rounds of a round may go: dispatch waves,
  /// not turns — a three-member fan-out is one generation whatever it fans
  /// out to. The project's override wins over the app default, and the user
  /// speaking resets the count: the cap is about agents talking to each
  /// other without end, not about how long a conversation may run.
  int get _maxGenerations {
    final project = state.chat?.state.project;
    return ref.read(projectSettingsProvider(project)).omadaMaxGenerations ??
        ref.read(appSettingsProvider).omadaMaxGenerations;
  }

  /// What this turn is allowed: the setting, resolved at the round the same
  /// way the approve mode is, so an edit reaches the next failure rather than
  /// the next launch.
  int get _roundsTotal => ref.read(appSettingsProvider).turnRetries;

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

  void _onError(_RunningTurn turn, Object e) {
    turn.retryable = false;
    final message = e.toString();
    final lineAt = message.indexOf("\n");
    turn.errorLine = lineAt < 0 ? message : message.substring(0, lineAt);
    turn.recorder.handle(ErrorEvent(message));
    _finishTurn(turn);
  }

  /// Set before the abort is awaited, though `DoneEvent.aborted` would say the
  /// same: killing the turn closes the stream, and a backend that closed it
  /// without the event would let `onDone` reach [_finishTurn] first and record
  /// the turn as having finished.
  @override
  Future<void> abort() async {
    final turns = List.of(_turns.values);
    if (turns.isEmpty) return;
    // The round stops whole: every running turn goes, and what was said while
    // they ran is dropped by the endings they record.
    for (final turn in turns) {
      turn.retryGen++;
      turn.recorder.outcome = TurnEnd.aborted;
    }
    await ref.read(chatRepositoryProvider).abort(chatId);
    await Future.wait(
        [for (final turn in turns) _finishTurn(turn)]);
  }

  /// Stop a turn without ending it: the agent is cancelled and the log is left
  /// **open**, so the chat offers to carry it on. See "Carrying on an
  /// interrupted turn" for why this is not [abort].
  ///
  /// Set before the agent is cancelled, the way [abort] sets its outcome:
  /// cancelling closes the stream, so [_finishTurn] can run from the `onDone`
  /// rather than from the line below, and it has to make the same decision
  /// whichever gets there first.
  Future<void> interrupt() async {
    if (!state.isRunning) return;
    final turns = List.of(_turns.values);
    if (turns.isEmpty) return;
    for (final turn in turns) {
      turn.retryGen++;
      turn.interrupted = true;
    }
    await ref.read(chatRepositoryProvider).abort(chatId);
    await Future.wait(
        [for (final turn in turns) _finishTurn(turn)]);
  }

  @override
  Future<void> respondApproval(
    String approvalId,
    ApprovalResponse r, {
    ToolApproval? approval,
  }) async {
    final repo = ref.read(chatRepositoryProvider);
    await repo.respondApproval(chatId, approvalId, r, approval: approval);
    // The banner is part of the turn's record: its "asked" part is
    // superseded with the answer, so a reload draws what was asked and what
    // was answered, not a question nobody ever answered. The turn it belongs
    // to is read before the approval leaves the view state — after, the
    // lookup would find nothing, and the record would read asked forever.
    final replyId = state.approvals.entries
        .where((e) => e.value.any((a) => a.id == approvalId))
        .map((e) => e.key)
        .firstOrNull;
    if (replyId != null) {
      _turns[replyId]?.recorder.recordApprovalAnswer(approvalId, r.name);
    }
    state = state.copyWith(
        approvals: _withoutApproval(state.approvals, approvalId));
    // A project-tier answer (always in project) wrote `project.json` behind
    // the settings page's back: the provider loaded once at startup and its
    // state is stale until told. Same for the chat's `meta.json`, whose
    // change the repository already streams.
    ref.invalidate(projectSettingsProvider(null));
    ref.invalidate(projectSettingsProvider(state.chat?.state.project));
  }

  /// Answer a request the panel was showing. One entry per question it held,
  /// null where nothing was picked.
  @override
  Future<void> answerQuestions(String requestId, List<String?> answers) async {
    final repo = ref.read(chatRepositoryProvider);
    await repo.respondQuestions(chatId, requestId, answers);
    state = state.copyWith(
        questions: _withoutQuestion(state.questions, requestId));
  }

  /// The map without the turn's own list — what a finished turn leaves of the
  /// view state it was holding, a sibling's kept.
  static Map<String, List<T>> _withoutTurn<T>(
          Map<String, List<T>> map, String replyId) =>
      Map<String, List<T>>.from(map)..remove(replyId);

  /// The map without [id] from any turn's list. Both lists hold items with
  /// an `id` field, read for the removal.
  static Map<String, List<ToolApproval>> _withoutApproval(
          Map<String, List<ToolApproval>> map, String id) =>
      _dropItem(map, id, (item) => item.id);

  static Map<String, List<AskRequest>> _withoutQuestion(
          Map<String, List<AskRequest>> map, String id) =>
      _dropItem(map, id, (item) => item.id);

  static Map<String, List<T>> _dropItem<T>(
          Map<String, List<T>> map, String id, Object? Function(T) keyOf) =>
      {
        for (final entry in map.entries)
          entry.key:
              entry.value.where((item) => keyOf(item) != id).toList()
      };
}

final chatControllerProvider =
    NotifierProvider.family<ChatController, ChatViewState, String>(ChatController.new);

/// One live turn of the room: everything that was a controller field when a
/// turn was the only thing a chat could run. The recorder is built per entry
/// — its one-reply assumption is per-instance, which is what keeps
/// [TurnRecorder] unchanged under parallel turns — and the fields below it
/// are the retry machinery, scoped to the turn they carry.
class _RunningTurn {
  /// [onParts] is wired late, from [attach]: the recorder wants the turn it
  /// belongs to, and the turn does not exist until its constructor returns.
  factory _RunningTurn(
      {required String replyId,
      required Completer<TurnEnd?> done,
      required Future<void> Function(List<ChatRecord>) append}) {
    final turn = _RunningTurn._(replyId: replyId, done: done);
    turn.recorder = TurnRecorder(append: append, onParts: (parts) {
      if (turn.onParts != null) turn.onParts!(turn, parts);
    });
    return turn;
  }

  _RunningTurn._({required this.replyId, required this.done});

  /// The reply this turn writes, and the table's key.
  final String replyId;

  /// Everything the turn's events become: the reply's parts, and the records
  /// that persist them.
  late final TurnRecorder recorder;

  /// The controller's own fold of the parts into the conversation — wired at
  /// open, so a recorder built for one chat's log cannot outlive it.
  void Function(_RunningTurn turn, List<MessagePart> parts)? onParts;

  /// Completes at the turn's true end — across retry rounds, one completion.
  final Completer<TurnEnd?> done;

  /// The turn's stream subscription, cancelled in [_finishTurn].
  StreamSubscription<AgentEvent>? sub;

  /// This turn is being stopped rather than ended — see [ChatController.interrupt].
  bool interrupted = false;

  /// Whether [_finishTurn] has begun on this turn.
  bool finishing = false;

  /// The finish in flight, which a second reach awaits.
  Future<void>? finishingFuture;

  /// Bumped by abort and interrupt so a pending retry cannot fire after the
  /// user pressed stop — this turn's generation, not the room's.
  int retryGen = 0;

  /// Whether the turn's last failure can be carried on from, and the line for
  /// the retry row and the failure notification.
  bool retryable = false;
  String errorLine = "";

  /// Retry rounds spent on this turn so far.
  int round = 0;

  /// The dispatch wave this turn belongs to: zero for the user's own, one
  /// and up for what agents handed to each other. The handoff that follows
  /// this turn reads it to know how deep the round has run.
  int generation = 0;

  /// Who this turn speaks for, where a member does — what the relay ordering's
  /// per-lane busy check reads. Null is the main agent's lane.
  String? omadaMember;
}

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

/// One item of the room's schedule: what a member (or the main agent, where
/// the schedule names nobody) has been addressed to run. Either a user
/// prompt — already on the log where it was said while the room ran — or a
/// handoff, the reply that names the member. [generation] is the dispatch
/// wave the item belongs to: zero is the user's own, uncapped, and one and
/// up counts against the cap.
class _Scheduled {
  _Scheduled({this.userPrompt, this.reply, required this.generation});

  final Message? userPrompt;
  final Message? reply;
  final int generation;
}