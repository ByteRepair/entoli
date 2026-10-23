import "dart:async";

import "package:collection/collection.dart";
import "package:uuid/uuid.dart";

import "../../core/log.dart";
import "../agent_backend.dart";
import "../chat_log.dart";
import "../chat_repository.dart";
import "../models.dart";
import "../project_settings.dart" show OmadaOrdering;
import "../prompt_library.dart" show nameOf;
import "../shell.dart" show shellBypassCommand;
import "../turn_recorder.dart";
import "../wired_skill.dart";
import "agent.dart";
import "room_state.dart";
import "roster.dart";
import "schedule.dart";

/// What a room needs of whoever holds it: the settings it reads at each use,
/// where its state goes, and the services that are not the room's own —
/// naming the chat, saying a failure out loud, compacting a grown session.
/// `ChatController` is the one host; a test can be another.
abstract interface class RoomHost {
  /// Who [project]'s room can address, read fresh at each use.
  Roster roster(String? project);

  OmadaOrdering ordering(String? project);

  /// How many agent-to-agent waves a round may run.
  int maxGenerations(String? project);

  /// How many automatic rounds a retryable failure gets.
  int get turnRetries;

  /// The room's state changed; [state] is the whole of it.
  void stateChanged(ChatViewState state);

  /// The chat's first prompt was said. Nothing waits on the answer.
  void firstSaid(String text);

  /// A turn has truly ended — awaited before the room settles.
  Future<void> turnEnded(TurnEnd? reason, String errorLine);

  /// A turn ended `done` and the room has dispatched what was said meanwhile.
  /// Nothing waits on the answer.
  void settledDone();
}

/// A chat is a room: the user, the house, and — with Omada on — the members
/// of the project's library. This owns everything about it that is not
/// Riverpod's: the turns in flight, what was said while they ran, the order
/// of speaking, and the log they all append to. See "The room and its
/// participants" in `lib/domain/room/AGENTS.md`.
///
/// Invariants:
/// - An agent has at most one turn in flight.
/// - `state.isRunning` is false only where no turn is in flight.
/// - A message's `addressees` is stamped once, where it is written, and the
///   room schedules off the stamp rather than re-reading the text.
class ChatRoom {
  ChatRoom(this.chatId, this._repo, this._host) {
    _ready = _load();
  }

  final String chatId;
  final ChatRepository _repo;
  final RoomHost _host;
  final _uuid = const Uuid();

  ChatViewState _state = ChatViewState();

  /// The room as the page reads it.
  ChatViewState get state => _state;
  set _view(ChatViewState next) {
    _state = next;
    if (!_disposed) _host.stateChanged(next);
  }

  /// Forget the chat: it was deleted, and a room that outlived its page must
  /// not re-open it from memory.
  void reset() => _view = ChatViewState();

  bool _disposed = false;

  /// The holder is gone: running turns stop being listened to, and nothing
  /// the room still has in flight reaches it.
  void dispose() {
    _disposed = true;
    for (final turn in _turns.values) {
      turn.sub?.cancel();
      turn.recorder.dispose();
    }
  }

  /// The live turns, keyed by the reply each writes. The table is what lets a
  /// second turn run beside the first without its recorder, its retry state
  /// or its interrupt reaching across — see [_RunningTurn].
  final Map<String, _RunningTurn> _turns = {};

  final Schedule _schedule = Schedule();

  /// Every recorder's writes funnel through one queue, so two turns appending
  /// to the same log cannot interleave lines. One turn serialises through its
  /// own recorder already; the funnel is for the room with more than one.
  Future<void>? _appendQueue;

  /// Appends [records] to this chat's log behind every append before it.
  Future<void> _append(List<ChatRecord> records) {
    final queued = _appendQueue;
    return _appendQueue =
        (queued == null ? Future<void>.sync(() => _repo.append(chatId, records)) : queued.then((_) => _repo.append(chatId, records)))
            .catchError((Object e) {
      // A failed line must not wedge the queue; the lost records get a line.
      logFailure("chat", "could not append to $chatId", e);
    });
  }

  Agent _agent(String? handle) => Agent(_repo, chatId, handle);

  Roster _roster(Chat chat) => _host.roster(chat.state.project);

  /// Open a turn: its recorder, its completer, and its place in the table.
  ///
  /// Pre: [agent] has no turn in flight.
  _RunningTurn _openTurnEntry(String replyId, Agent agent) {
    assert(!_turns.values.any((t) => t.agent.handle == agent.handle),
        "an agent has at most one turn in flight");
    final turn =
        _RunningTurn(replyId: replyId, agent: agent, done: Completer<TurnEnd?>());
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

  /// The first read of the chat off disk. **Anything that drives a turn waits
  /// on it**, because a room is built the moment something asks for it and
  /// driven in the same breath — `createChat` sends the first message,
  /// `RemoteTurnDriver` hands over a peer's — and a turn started before this
  /// lands finds no chat and silently does nothing.
  late final Future<void> _ready;

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
  void _writeReply(_RunningTurn turn, List<MessagePart> parts) =>
      _updateReply(turn, (m) => m.copyWith(parts: parts));

  void _updateReply(_RunningTurn turn, Message Function(Message) change) {
    final chat = state.chat;
    if (chat == null) return;
    final at = chat.messages.indexWhere((m) => m.id == turn.replyId);
    if (at < 0) return;
    final messages = List<Message>.from(chat.messages);
    messages[at] = change(messages[at]);
    _view = state.copyWith(chat: chat.copyWith(messages: messages));
  }

  /// Take a state written elsewhere — the sidebar pinning this chat — in place.
  /// Reloading instead would dispose a running turn. Nothing to do where the
  /// chat is not loaded yet: it reads the same write off disk.
  void applyState(ChatState written) {
    final chat = state.chat;
    if (chat == null) return;
    _view = state.copyWith(chat: chat.copyWith(state: written));
  }

  /// Retitle in place, for the same reason.
  void applyTitle(String title) {
    final chat = state.chat;
    if (chat == null) return;
    applyState(chat.state.copyWith(title: title));
  }

  Future<void> _load() async {
    try {
      final chat = await _repo.openChat(chatId);
      if (!_disposed) _view = state.copyWith(chat: chat);
    } catch (e) {
      // Deleted under us — swept for its TTL, or removed on a paired device.
      // Left unsaid the page keeps a spinner up with nothing behind it.
      logFailure("chat", "could not open $chatId", e);
    }
  }

  /// The composer's own path: what it is holding becomes files under the chat
  /// before anything else, since from here on a prompt is its parts. Said
  /// while a turn runs, it steers that turn — read at its next step — unless
  /// [queue] asks for it to wait, or no running turn is its addressee's; a
  /// queued say is appended to the log as it stands and dispatched when the
  /// room settles — the log is the queue.
  ///
  /// A `/skill` flagged `invocation: callback` never reaches here as a prompt:
  /// it is checked before the room's guards, the way the `!` shell bypass is,
  /// and refused while a turn runs rather than queued — a callback mid-turn
  /// is the session the turn is rewriting underneath it. Where it is checked
  /// after that, the turn it runs goes through the room's machinery like any
  /// other, so the spinner, Stop and the composer's rules hold.
  Future<void> send(String text,
      {List<Attachment> attachments = const [], bool queue = false}) async {
    await _ready;
    if (state.chat == null) return;
    final wired = wiredSkillFromText(text);
    if (wired != null) {
      if (state.isRunning) {
        _view = state.copyWith(
            status: "Wait for the turn to finish before compacting");
        return;
      }
      switch (wired.skill) {
        case WiredSkill.compact:
          await _promptCompacting(wired.arguments);
      }
      return;
    }
    final files = await _repo.saveAttachments(chatId, attachments);
    if (state.isRunning) {
      final say = _composeSay(text, files);
      if (queue || !_steer(say)) await _sayLater(say);
      return;
    }
    await _prompt(text, files: files);
  }

  /// What was said while a turn ran and is still unsaid. The messages are on
  /// the log already — written as they were said — and this is what is left
  /// to say. The composed message itself, so the drain dispatches what the
  /// log holds rather than composing a second one.
  final List<Message> _said = [];

  /// A say made while the room runs. The routing record rides it the moment
  /// it lands — the same stamp a fresh send writes where the prompt is not on
  /// the log yet.
  Message _composeSay(String text, List<MessagePart> files) {
    final say = _repo.composeUserPrompt(text,
        project: state.chat?.state.project, files: files);
    final chat = state.chat;
    return chat == null
        ? say
        : say.copyWith(addressees: _roster(chat).addressees(say));
  }

  /// Hand [say] to the running turn it addresses, to be read at that turn's
  /// next step. False where there is none to take it: a command, a say naming
  /// several members, or one whose addressee is not speaking — those queue.
  bool _steer(Message say) {
    final turn = _steeredBy(say);
    if (turn == null || !turn.steers.offer(say)) return false;
    _showSteering();
    return true;
  }

  /// Whether [text], sent now, would steer a running turn rather than wait
  /// for it: the composer asks, to offer the choice only where there is one.
  bool steers(String text) =>
      state.isRunning && _steeredBy(_composeSay(text, const [])) != null;

  _RunningTurn? _steeredBy(Message say) {
    final chat = state.chat;
    if (chat == null || shellBypassCommand(say.plainText) != null) return null;
    if (say.addressees.length > 1) return null;
    final to = _roster(chat).answering(say);
    return _turns.values.firstWhereOrNull((t) => t.agent.handle == to);
  }

  /// The strip, read off the inboxes rather than kept beside them.
  void _showSteering() => _view = state.copyWith(steering: [
        for (final t in _turns.values) ...t.steers.pending,
      ]);

  /// Send a say still waiting for its turn to read it after the turn instead.
  Future<void> queueSteer(String id) async {
    final say = _unsteer(id);
    if (say != null) await _sayLater(say);
  }

  /// Take back a say its turn has not read yet, as the composer held it: its
  /// text and its files, read back from where sending saved them and removed
  /// there, since nothing on the log names them and a resend saves its own.
  /// Null where the turn already has it; a file whose resource has gone is
  /// left out.
  Future<Draft?> withdrawSteer(String id) async {
    final say = _unsteer(id);
    if (say == null) return null;
    final attachments = await Future.wait(say.files.map((f) async {
      final bytes = await _repo.readResource(chatId, f.resource);
      await _repo.deleteResource(chatId, f.resource);
      return bytes == null
          ? null
          : Attachment(filename: f.filename, mimeType: f.mimeType, bytes: bytes);
    }));
    return (text: say.plainText, attachments: attachments.nonNulls.toList());
  }

  Message? _unsteer(String id) {
    final say =
        _turns.values.map((t) => t.steers.withdraw(id)).nonNulls.firstOrNull;
    if (say != null) _showSteering();
    return say;
  }

  Future<void> _sayLater(Message say) async {
    await _land([say]);
    if (state.chat != null) _drainSaid();
  }

  /// Put [says] on the log and on screen, after whatever is there, left to
  /// be said. It goes through the room's one append funnel; state is re-read
  /// after the write, so what changed in flight is not ours to revert.
  Future<void> _land(List<Message> says) async {
    await _append(recordsOf(says));
    final chat = state.chat;
    if (chat == null) return;
    _view = state.copyWith(
        chat: chat.copyWith(
            messages: [...chat.messages, ...says],
            state: chat.state.copyWith(updatedAt: DateTime.now())));
    _said.addAll(says);
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
      _schedule.addPrompt([for (final a in said.addressees) ?nameOf(a)], said);
    }
    if (_turns.isNotEmpty && _ordering.waitsForWave) return;
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
    final chat = state.chat;
    if (chat == null || state.isRunning) return;
    final at =
        replacing == null ? chat.messages.length : chat.messages.indexOf(replacing);
    if (at < 0) return;

    final userMsg =
        _repo.composeUserPrompt(text, project: chat.state.project, files: files);
    if (replacing != null) {
      await _say(userMsg, replacing: replacing);
      return;
    }
    _schedule.addPrompt(_roster(chat).mentioned(userMsg), userMsg);
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
    final userMsg = _repo.composeUserPrompt(
        "/compact${arguments.isEmpty ? "" : " $arguments"}",
        project: chat.state.project);
    await _say(userMsg);
  }

  /// The compact turn's body, driven from [_openTurn] by the wired check on
  /// the prompt. The turn is already open — the entry seated, the prompt and
  /// its empty reply logged — so this runs the summarizer, writes the marker,
  /// and ends the turn the way any event stream would have. Shaped like the
  /// loop's end so `isRunning`, Stop and the settle rules hold over it.
  Future<void> _runCompactTurn(
      _RunningTurn turn, String arguments) async {
    // The wait says what it is: a summarizer over a long conversation is a
    // read of minutes, and a spinner that cannot be told apart from a hang is
    // the row that says nothing.
    _view = state.copyWith(status: "Compacting the conversation");
    try {
      await compact(instructions: arguments.trim().isEmpty ? null : arguments.trim());
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
  /// of append/reload/rebuild, reached through this room's own
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
  Future<void> compact(
      {required String? instructions, bool recheck = false}) async {
    final chat = state.chat;
    final result = chat == null
        ? null
        : await _repo.compact(chatId,
            history: chat.messages,
            compactions: chat.compactions,
            instructions: instructions);
    if (_disposed || result == null || (recheck && state.isRunning)) return;
    // The wrapper's own guard is the reentrancy flag, and it sets the chat on
    // the way through — so nothing to hand back here.
    await _rethread((repo) => repo.appendCompaction(chatId, result));
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
        : _roster(chat).authorFor(userMsg);
    await _openTurn(
      chat: chat,
      prompt: userMsg,
      history: chat.messages.take(at).toList(),
      opening: [
        if (!logged) userMsg,
        _newReply(author: author),
      ],
      replacing: replacing,
      member: member,
      generation: generation,
    );
  }

  /// Open a turn: put the messages it starts with in the conversation and in
  /// the log, then hand the prompt to the agent answering it.
  ///
  /// [opening] is what the turn writes — the prompt and its empty reply, or the
  /// reply alone where the prompt is already there. [history] is the
  /// conversation the model is answering, which does not include the prompt:
  /// `sendPrompt` adds that itself. [replacing] is the message [opening] is an
  /// alternative to, and null when this is simply the next thing said.
  /// [member] is who the room has decided answers it, where scheduling
  /// decided ahead of the prompt — a dispatched item — rather than from it.
  /// [generation] is the dispatch wave the turn belongs to, on the entry for
  /// the handoff that reads it.
  Future<void> _openTurn({
    required Chat chat,
    required Message prompt,
    required List<Message> history,
    required List<Message> opening,
    Message? replacing,
    String? member,
    int generation = 0,
  }) async {
    final roster = _roster(chat);
    final omada = roster.omada;
    // The routing record rides the say where it is written — a fresh send's
    // or an edit's say, stamped the one time here and the same copy logged
    // and sent; a say already on the log keeps the record the room made
    // where it landed, the way [omadaOn] is kept, since a member the library
    // lost since does not rewrite the room's past.
    final logged = chat.messages.contains(prompt);
    final say = logged
        ? prompt
        : prompt.copyWith(omadaOn: omada, addressees: roster.addressees(prompt));
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
    _view = state.copyWith(chat: updated, isRunning: true, clearRetry: true, clearStatus: true);
    // The prompt and the empty reply go down before the turn starts, so a chat
    // killed before the model says anything still shows what was asked. What
    // comes back carries the TTL anchor the save resolved, and is kept.
    // The entry takes its seat **before** the save: a sibling settling while
    // it is in flight would read the room as settled and hand off from a
    // wave still opening. Who answers is resolved once: the entry's agent —
    // what relay's busy lane reads — and the one the stream goes to are the
    // same fact.
    final agent = _agent(member ?? roster.answering(prompt));
    final turn = _openTurnEntry(opening.last.id, agent);
    turn.generation = generation;
    applyState(await _repo.saveState(updated.state));
    await turn.recorder.write(recordsOf(openingWithMode,
        siblingOf: replacing?.id,
        replacing: replacing != null && !chat.worthAThread(replacing)));
    // Only the first message names the chat. The list is not refreshed here:
    // the chat was written, and listed, when it was created.
    if (isFirst) _host.firstSaid(prompt.plainText);

    // Disposed mid-turn — a chat moved while one was starting. The move
    // aborted whatever was running, so this turn never starts; there is
    // nothing to abort here and nothing to write beside the move.
    if (_disposed) return;
    // A callback's turn is run here rather than sent to the agent: the
    // compact machinery is the room's to drive, and the turn ends with the
    // marker it writes rather than an event stream. The dispatch switches on
    // the skill, the way send did — adding a wired skill is an enum entry and
    // an arm here.
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
    _listen(turn, agent.take(say,
        history: history,
        compactions: chat.compactions,
        replaces: replacing != null,
        steers: turn.steers));
  }

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

    _view = state.copyWith(isRunning: true, clearRetry: true, clearStatus: true);
    // The member who wrote the reply carries it on; a fresh entry takes them
    // as its lane, which is what relay's busy check reads.
    final agent = _agent(_roster(chat).known(nameOf(reply.author)));
    // Kept open across the round: a caller awaiting [turnDone] gets one
    // completion, at the true end, not one per attempt.
    final turn = _turns[reply.id] ?? _openTurnEntry(reply.id, agent);
    turn.interrupted = false;
    turn.finishing = false;
    turn.recorder.open(reply.id, existing: reply.parts);

    _listen(
        turn,
        agent.carryOn(
            history: chat.messages,
            compactions: chat.compactions,
            steers: turn.steers));
  }

  /// What a turn can be carried on from: an assistant's reply. A command's
  /// turn is ruled out by its prompt, in `endsUnfinished` — not by the reply's
  /// own text, which a model may well start with `!` (a markdown image).
  static bool _resumableReply(Message m) => m.role == MessageRole.assistant;

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
    await _openTurn(
      chat: chat,
      prompt: prompt,
      history: chat.messages.take(chat.messages.indexOf(prompt)).toList(),
      opening: [_newReply(author: _roster(chat).authorFor(prompt))],
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
      final now = await change(_repo);
      if (!_disposed) _view = state.copyWith(chat: now);
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
      case ImageEvent():
      case InstructionsReadEvent():
        break;
      case SteerEvent():
        // Read: it is the reply's from here, drawn where it landed.
        _showSteering();
      case ToolResultEvent():
      case ShellRunEvent():
        // The pair completing is the live block's end: the result and the
        // run part are what the conversation keeps of the output from here.
        _view = state.copyWith(
            shellOutput: _withoutTurn(state.shellOutput, turn.replyId));
        break;
      case ErrorEvent(:final message, :final retryable):
        // Whether the round can carry the turn on from this, and the first
        // line for the retry row and the failure notification. Both are
        // turn-scoped view state: the error part is what the conversation
        // keeps, and neither field outlives the turn.
        turn.retryable = retryable;
        turn.errorLine = message.split("\n").first;
        break;
      case StepLimitEvent():
      case InfoEvent():
        break;
      case ContextEvent(:final usage):
        // What the close will write, on screen before it does.
        _updateReply(turn, (m) => m.copyWith(context: usage));
      case ApprovalRequestEvent(:final approval):
        _view = state.copyWith(
            approvals: {
              ...state.approvals,
              turn.replyId: [...state.approvals[turn.replyId] ?? [], approval]
            });
      case QuestionRequestEvent(:final request):
        _view = state.copyWith(questions: {
          ...state.questions,
          turn.replyId: [...state.questions[turn.replyId] ?? [], request]
        });
      case SubAgentStartEvent():
        _view = state.copyWith(runningSubAgents: {
          ...state.runningSubAgents,
          turn.replyId: [
            ...(state.runningSubAgents[turn.replyId] ?? []),
            event
          ]
        });
      case SubAgentEndEvent(:final id):
        _view = state.copyWith(runningSubAgents: {
          for (final entry in state.runningSubAgents.entries)
            entry.key: entry.value.where((s) => s.id != id).toList()
        });
      case RetryEvent(:final attempt, :final message):
        _view = state.copyWith(retry: "Attempt $attempt failed: $message");
      case ShellOutputEvent(:final text):
        // The live view of a command's output, for the block under the label.
        // Cleared where the pair completes, in the cases above.
        _view = state.copyWith(
            shellOutput: {...state.shellOutput, turn.replyId: text});
      case StatusEvent(:final label):
        _view = label == null
            ? state.copyWith(clearStatus: true)
            : state.copyWith(status: label);
      case DoneEvent(:final aborted):
        if (aborted) turn.recorder.outcome ??= TurnEnd.aborted;
        _view = state.copyWith(
            shellOutput: _withoutTurn(state.shellOutput, turn.replyId));
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
      _schedule.clearQueues();
      reason = null;
    } else {
      turn.recorder.flushDeltas();
      final to = turn.recorder.outcome == null ? _routeOf(turn) : const <String>[];
      reason = await turn.recorder.close(addressees: to);
      if (to.isNotEmpty) _stampAddressees(turn.replyId, to);
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
        turn.round < _host.turnRetries) {
      final rounds = _host.turnRetries;
      final gen = turn.retryGen;
      final round = turn.round;
      turn.round++;
      final wait = Duration(seconds: (1 << round).clamp(1, 30));
      if (_disposed) return;
      _view = state.copyWith(
        retry: "Retrying (${turn.round}/$rounds) — ${turn.errorLine}",
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
      if (_disposed) return;
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
    if (_disposed) return;
    final done = turn.done;
    // What was said to the turn and never read goes after it, as a say made
    // to wait would: dispatched below, or left on the log where the round was
    // stopped. Landed while the turn still holds the room, so a send racing
    // this queues behind it.
    final unread = turn.steers.close();
    if (unread.isNotEmpty) {
      _showSteering();
      await _land(unread);
      if (_disposed) return;
    }
    _turns.remove(turn.replyId);
    // The settle reads how deep the round ran when this turn finished; the
    // entry is leaving the table, so the fact stays behind.
    _schedule.finished(turn.replyId, turn.generation);
    // Nothing is left to answer once the turn is over: the backend has already
    // answered its own outstanding questions with nothing, so a banner or a
    // panel still on screen would send its reply into the void. Only this
    // turn's — a sibling still running keeps its own.
    _view = state.copyWith(
      // What a reload would now make of the log, so a turn that gave up is
      // offered straight away rather than only once the chat is opened again.
      chat: state.chat?.copyWith(unfinished: reason?.resumable ?? true),
      isRunning: _turns.isNotEmpty,
      approvals: _withoutTurn(state.approvals, turn.replyId),
      questions: _withoutTurn(state.questions, turn.replyId),
      runningSubAgents: _withoutTurn(state.runningSubAgents, turn.replyId),
      clearRetry: _turns.isEmpty,
      clearStatus: _turns.isEmpty,
      shellOutput: _withoutTurn(state.shellOutput, turn.replyId),
      unfinishedNotice: reason == TurnEnd.stepLimit
          ? "Step limit reached"
          : null,
    );
    done.complete(reason);
    await _host.turnEnded(reason, turn.errorLine);
    if (reason == TurnEnd.aborted || reason == TurnEnd.error) {
      // An aborted round is a stopped one: the unsaid is dropped, and a
      // sibling's parked reply goes with it rather than handing off from a
      // round the user stopped.
      _said.clear();
      _schedule.clear();
      return;
    }

    // The room has settled: what was said while it spoke is said next, in
    // the order it was said. Said messages schedule their members the same
    // way anything else does, so a mention in one runs through the ordering
    // like a handoff's does. Handoffs read the room only once the schedule
    // holds nothing — the user's own words dispatch ahead of the agents'.
    _drainSaid();
    // The context this turn left behind is the one thing that grows without
    // being said, and the host decides whether to compact it. Here, where the
    // turn is over and the session is settled — the summarizer cannot run
    // over a session the loop is still rewriting — and after the drain, so a
    // say it just dispatched reads as a running room.
    if (reason == TurnEnd.done) _host.settledDone();
    await _settle(turn, reason);
  }

  /// A turn has ended: the room may hand off. Under the wave orderings the
  /// schedule may still hold what the settle will not run now — an item the
  /// cap stops, or a member's second item behind one still running — and
  /// this turn's reply hands off with the wave, parked for the settle that
  /// ends it, rather than waiting on a schedule that will not drain this
  /// settle. Relay order is the one rule without that wait: nothing parks,
  /// so the reply below is this turn's own and the per-lane check at
  /// dispatch is what holds "one turn per member" against it.
  Future<void> _settle(_RunningTurn turn, TurnEnd? reason) async {
    if (_turns.isNotEmpty && _ordering.waitsForWave) {
      // A sibling is still speaking: this reply hands off when the room
      // settles, not now — the wave waits, whatever order the siblings
      // finished in.
      if (reason == TurnEnd.done) _schedule.park(turn.replyId);
      return;
    }
    final chat = state.chat;
    if (chat == null) return;
    // The room is settled (or relay, which never waits): every reply the
    // wave finished hands off in conversation order, the order they were
    // said — this turn's own first, where it finished the wave. Under relay
    // the list is this turn's own, and what a prior wave parked is drained
    // rather than stranded when the user flips the ordering mid-round.
    final ids = _schedule.settle(reason == TurnEnd.done ? turn.replyId : null);
    final replies = [
      for (final id in ids)
        chat.messages.firstWhereOrNull((m) => m.id == id),
    ].whereType<Message>().toList();
    _handoff(reason, chat, replies);
    // Whatever the schedule may run now, runs: a queued say, a handoff just
    // scheduled, or a member's next item behind one still queued. The
    // handoff's own gate decides what was scheduled, not what runs — an
    // off-Omada room's queued says and what a failure leaves queued drain
    // through here all the same.
    await _dispatch();
  }

  /// What finished replies hand the baton to. A reply that names members —
  /// each turn ended `done`, nothing a failure leaves carrying — has their
  /// turns scheduled, the room's round, until the generation cap says the
  /// agents have had the floor long enough. The routing is the stamp the
  /// close wrote, as a say's is. A reply that ended with `end_turn` named no
  /// one, so it hands to no one: silence is nothing said, not a veto on what
  /// siblings handed off.
  void _handoff(TurnEnd? reason, Chat chat, List<Message> replies) {
    if (reason != TurnEnd.done || _disposed) return;
    // Omada off is the room as it always was: nothing hands anything to
    // anyone, whatever a reply's text happens to name.
    if (!_roster(chat).omada) return;
    for (final reply in replies) {
      // The wave lands one past the turn that named it: the round's depth is
      // the finished turn's own, and the cap reads it at dispatch.
      _schedule.addHandoff([for (final a in reply.addressees) ?nameOf(a)], reply,
          generation: _schedule.generationOf(reply.id), thread: chat.messages);
    }
  }

  /// The routing [turn]'s reply closes with: the roster's read of the parts it
  /// ends on, sigils on.
  List<String> _routeOf(_RunningTurn turn) {
    final chat = state.chat;
    final reply = chat?.messages.firstWhereOrNull((m) => m.id == turn.replyId);
    if (chat == null || reply == null) return const [];
    return _roster(chat).addressees(reply.copyWith(parts: turn.recorder.parts));
  }

  /// Puts the routing the close wrote on the reply in memory too, so the next
  /// dispatch's history words it the way a reload would.
  void _stampAddressees(String replyId, List<String> to) {
    final chat = state.chat;
    if (chat == null) return;
    _view = state.copyWith(
        chat: chat.copyWith(messages: [
      for (final m in chat.messages)
        m.id == replyId ? m.copyWith(addressees: to) : m,
    ]));
  }

  /// Run what the schedule may run now, through the room's ordering.
  Future<void> _dispatch() => _schedule.dispatch(
      ordering: () => _ordering,
      cap: () => _host.maxGenerations(state.chat?.state.project),
      busy: () => {for (final turn in _turns.values) turn.agent.handle},
      run: _run);

  /// Open the turn one scheduled item runs as. [member] null is the main
  /// agent's; a handoff's prompt is the reply that names the member, already
  /// in the conversation.
  Future<void> _run(String? member, ScheduledItem item) async {
    final prompt = item.userPrompt;
    final reply = item.reply;
    if (prompt != null) {
      await _say(prompt, member: member, generation: item.generation);
      return;
    }
    final chat = state.chat;
    if (chat == null || reply == null) return;
    await _openTurn(
      chat: chat,
      prompt: reply,
      // The conversation the member answers ends before the reply that hands
      // to them: `sendPrompt` adds the prompt itself, and history holding it
      // too would have the member read their mentioning reply twice.
      history: chat.messages.take(chat.messages.indexOf(reply)).toList(),
      // The next reply is authored by the member handed to. The stamp
      // carries the sigil, the way every author stamp does.
      opening: [_newReply(author: "${CompletionKind.agent.trigger}$member")],
      member: member,
      generation: item.generation,
    );
  }

  /// The room's scheduling order, read at each use so a change reaches the
  /// next dispatch.
  OmadaOrdering get _ordering => _host.ordering(state.chat?.state.project);

  void _onError(_RunningTurn turn, Object e) {
    turn.retryable = false;
    final message = e.toString();
    turn.errorLine = message.split("\n").first;
    turn.recorder.handle(ErrorEvent(message));
    _finishTurn(turn);
  }

  /// Set before the abort is awaited, though `DoneEvent.aborted` would say the
  /// same: killing the turn closes the stream, and a backend that closed it
  /// without the event would let `onDone` reach [_finishTurn] first and record
  /// the turn as having finished.
  Future<void> abort() =>
      _stopAll((turn) => turn.recorder.outcome = TurnEnd.aborted);

  /// Stop a turn without ending it: the agent is cancelled and the log is left
  /// **open**, so the chat offers to carry it on. See "Carrying on an
  /// interrupted turn" for why this is not [abort].
  ///
  /// Set before the agent is cancelled, the way [abort] sets its outcome:
  /// cancelling closes the stream, so [_finishTurn] can run from the `onDone`
  /// rather than from the line below, and it has to make the same decision
  /// whichever gets there first.
  Future<void> interrupt() => _stopAll((turn) => turn.interrupted = true);

  /// The round stops whole: every running turn is marked, then the agent is
  /// cancelled and each turn finished.
  ///
  /// Post: no turn is in flight.
  Future<void> _stopAll(void Function(_RunningTurn) mark) async {
    final turns = List.of(_turns.values);
    if (turns.isEmpty) return;
    for (final turn in turns) {
      turn.retryGen++;
      mark(turn);
    }
    await _repo.abort(chatId);
    await Future.wait([for (final turn in turns) _finishTurn(turn)]);
  }

  /// Answer a banner. The banner is part of the turn's record: its "asked"
  /// part is superseded with the answer, so a reload draws what was asked and
  /// what was answered, not a question nobody ever answered. The turn it
  /// belongs to is read before the approval leaves the view state — after,
  /// the lookup would find nothing, and the record would read asked forever.
  Future<void> respondApproval(
    String approvalId,
    ApprovalResponse r, {
    ToolApproval? approval,
  }) async {
    await _repo.respondApproval(chatId, approvalId, r, approval: approval);
    final replyId = state.approvals.entries
        .where((e) => e.value.any((a) => a.id == approvalId))
        .map((e) => e.key)
        .firstOrNull;
    if (replyId != null) {
      _turns[replyId]?.recorder.recordApprovalAnswer(approvalId, r.name);
    }
    _view = state.copyWith(
        approvals: _dropItem(state.approvals, approvalId, (a) => a.id));
  }

  /// Answer a request the panel was showing. One entry per question it held,
  /// null where nothing was picked.
  Future<void> answerQuestions(String requestId, List<String?> answers) async {
    await _repo.respondQuestions(chatId, requestId, answers);
    _view = state.copyWith(
        questions: _dropItem(state.questions, requestId, (q) => q.id));
  }

  /// The map without the turn's own entry — what a finished turn leaves of the
  /// view state it was holding, a sibling's kept.
  static Map<String, V> _withoutTurn<V>(Map<String, V> map, String replyId) =>
      Map<String, V>.from(map)..remove(replyId);

  /// The map without [id] from any turn's list.
  static Map<String, List<T>> _dropItem<T>(
          Map<String, List<T>> map, String id, Object? Function(T) keyOf) =>
      {
        for (final entry in map.entries)
          entry.key:
              entry.value.where((item) => keyOf(item) != id).toList()
      };
}

/// One live turn of the room. The recorder is built per entry — its
/// one-reply assumption is per-instance, which is what keeps [TurnRecorder]
/// unchanged under parallel turns — and the fields below it are the retry
/// machinery, scoped to the turn they carry.
class _RunningTurn {
  _RunningTurn({required this.replyId, required this.agent, required this.done});

  /// The reply this turn writes, and the table's key.
  final String replyId;

  /// Who this turn speaks for — what the relay ordering's per-lane busy
  /// check reads.
  final Agent agent;

  /// Everything the turn's events become: the reply's parts, and the records
  /// that persist them.
  late final TurnRecorder recorder;

  /// Completes at the turn's true end — across retry rounds, one completion.
  final Completer<TurnEnd?> done;

  /// The turn's stream subscription, cancelled in [ChatRoom._finishTurn].
  StreamSubscription<AgentEvent>? sub;

  /// What the user says to this turn while it runs. Open across retry rounds,
  /// closed at the turn's true end.
  final SteerInbox steers = SteerInbox();

  /// This turn is being stopped rather than ended — see [ChatRoom.interrupt].
  bool interrupted = false;

  /// Whether [ChatRoom._finishTurn] has begun on this turn.
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
}
