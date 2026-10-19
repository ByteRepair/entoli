import "dart:async";

import "agent_backend.dart";
import "chat_log.dart";
import "models.dart";

/// A turn's events, accumulated into the reply's parts and appended to a log as
/// they arrive.
///
/// Both things that run an agent keep one: `ChatController` for the
/// conversation the user is reading, and `SubAgentRunner` for a `task` call's
/// own transcript. They differ only in where the records go and in who wants to
/// be told the parts changed — everything else about turning a stream of events
/// into a log is the same job, and a sub-agent with a weaker version of it
/// would be a sub-agent whose kill leaves a file nothing can read.
class TurnRecorder {
  TurnRecorder({required this.append, this.onParts}) : _logs = true;

  /// A recorder with no log behind it: it accumulates the parts and nothing
  /// else. What `BuiltinAgent` keeps, so the conversation it sends the model is
  /// derived from the parts its own events produce rather than assembled a
  /// second way beside them — see "The projection" in `lib/domain/AGENTS.md`.
  TurnRecorder.parts()
      : append = _writesNothing,
        onParts = null,
        _logs = false {
    // Named rather than opened: there is no message, and no log to put one in.
    // It is set because buffered text is dropped when nothing is being
    // recorded, and here everything is — into memory.
    _messageId = _nothing;
  }

  static const _nothing = "";
  static Future<void> _writesNothing(List<ChatRecord> records) async {}

  /// Whether anything is written. False for [TurnRecorder.parts], which skips
  /// the checkpoints and their timer rather than building records for a log
  /// that is not there.
  final bool _logs;

  /// Where the records go. Serialised through this recorder's own queue, so a
  /// caller with other records for the same log writes them with [write]
  /// rather than calling this.
  final Future<void> Function(List<ChatRecord> records) append;

  /// The reply's parts, whenever they change. Null where nothing is watching —
  /// a sub-agent has no bubble to redraw.
  final void Function(List<MessagePart> parts)? onParts;

  List<MessagePart> _parts = const [];

  /// What this turn has produced so far. The same list [onParts] was last
  /// handed.
  List<MessagePart> get parts => _parts;

  /// Deltas arrive per token; a reader only needs them per frame.
  final StringBuffer _pending = StringBuffer();
  Timer? _flush;
  bool _pendingIsReasoning = false;

  /// The reply being logged, and its parts as the log last saw them. A
  /// checkpoint writes the difference, so a part that has not changed is not
  /// written twice.
  String? _messageId;
  List<MessagePart> _logged = const [];

  /// Text grows without any event to hang a write off, so a delta arms this
  /// and the log catches up a second later. Everything else is written the
  /// moment it lands. One-shot rather than periodic, like [_flush]: a timer
  /// that keeps rearming itself is a widget test that never settles.
  Timer? _checkpoint;
  static const _checkpointEvery = Duration(seconds: 1);

  /// Appends run one at a time and in order: the log is a file being added to,
  /// and two writers would interleave lines. Queued work reads the state when
  /// it runs, so calls that pile up behind a slow write collapse into one.
  ///
  /// Null until the first one rather than seeded with a completed future. A
  /// `Future.value()` built when the recorder is — which in a widget test is
  /// on the fake clock — only completes when the tree is pumped, and the first
  /// append is awaited from inside `runAsync`, where it cannot be.
  Future<void>? _queue;

  /// The response being streamed. Every part produced while it is set is
  /// stamped with it, which is what lets a turn be handed back to a provider
  /// one response at a time — see [MessagePart].
  String? _responseId;

  /// How the turn ended, where something other than the model decided it. Null
  /// means it simply finished. Turn-scoped rather than read off the reply's
  /// parts: a resumed turn adds to a message that may already hold the
  /// [ErrorPart] the last attempt ended on. An abort wins over an error —
  /// killing a turn is a good way to make it fail.
  TurnEnd? outcome;

  /// The newest request's context, which the close writes. See
  /// [TurnEndRecord.context].
  ContextUsage? _context;

  /// Begin recording [messageId]. [existing] is what the log already holds of
  /// it — nothing for a new turn, its parts so far for one being carried on, so
  /// a checkpoint writes only what this turn adds.
  void open(String messageId, {List<MessagePart> existing = const []}) {
    outcome = null;
    _context = null;
    _responseId = null;
    _messageId = messageId;
    _logged = existing;
    _parts = existing;
  }

  /// Everything a turn's events do to the reply. Events that change no part —
  /// approvals, questions, retries, the turn ending — are ignored here and left
  /// to whoever is watching the same stream.
  void handle(AgentEvent event) {
    switch (event) {
      case ResponseStart(:final id):
        // Before the id moves: what is buffered was said by the response that
        // is ending, not the one starting.
        flushDeltas();
        _responseId = id;
      case TextDelta(:final text):
        _bufferDelta(text);
      case ReasoningDelta(:final text):
        _bufferDelta(text, reasoning: true);
      case ReasoningEnd(:final text, :final duration, :final signature):
        _endReasoning(text, duration, signature);
      case ToolCallEvent(:final call):
        addPart(MessagePart.toolCall(toolCall: call));
      case ToolResultEvent(:final result):
        addPart(MessagePart.toolResult(result: result));
      case ShellRunEvent(:final run):
        addPart(run);
      case ArtifactEvent(:final artifactId, :final entryFile, :final title):
        addPart(MessagePart.artifact(artifactId: artifactId, entryFile: entryFile, title: title));
      case SkillInstallEvent(:final installId, :final title):
        addPart(MessagePart.skillInstall(installId: installId, title: title));
      case ImageEvent(:final part):
        addPart(part);
      case InstructionsReadEvent(:final files):
        // The backend claims against the history for a main-agent turn, so
        // this records the conversation's first read of each file. The
        // containment check is for the turn that has no claim behind it —
        // a sub-agent's, whose own transcript may re-record on a resume what
        // it already recorded before it was interrupted. A reply never
        // stacks two identical read records.
        final part = MessagePart.instructions(files: files);
        if (!_parts.contains(part)) addPart(part);
      case ErrorEvent(:final message):
        _appendError(message);
      case StepLimitEvent():
        outcome ??= TurnEnd.stepLimit;
      // Turn-scoped view state, or the turn's own end. Listed rather than
      // defaulted so that a new kind of event has to be decided about here as
      // well as wherever it is drawn.
      case ApprovalRequestEvent(:final approval):
        // The banner is part of the turn's record now: what was asked and —
        // superseded in place when the answer lands — what was answered.
        addPart(MessagePart.approval(
            approvalId: approval.id,
            toolName: approval.toolName,
            argumentsText: approval.argumentsText,
            deniedDirs: approval.deniedDirs,
            answer: "asked"));
      case ContextEvent(:final usage):
        _context = usage;
      case QuestionRequestEvent():
      case SubAgentStartEvent():
      case SubAgentEndEvent():
      case RetryEvent():
      case StatusEvent():
      case ShellOutputEvent():
      case InfoEvent():
      case DoneEvent():
        break;
    }
  }

  /// Write [records] to the same log, behind whatever this recorder has queued.
  /// For records that are not the turn's own — the pair opening it, say.
  Future<void> write(List<ChatRecord> records) =>
      _enqueue(() => append(records));

  /// Close the turn: the last of the reply and the record saying why it ended,
  /// in one write. The reason is returned because the caller has to agree with
  /// what a reload would now make of the log.
  ///
  /// The terminal record is the point of this: a log whose last message has no
  /// [TurnEndRecord] was being written when the process died, and that absence
  /// is the only thing that can tell a reload the difference.
  ///
  /// [addressees] is the reply's routing, see [TurnEndRecord.addressees].
  Future<TurnEnd> close({List<String> addressees = const []}) async {
    final reason = outcome ?? TurnEnd.done;
    await _stop(reason, addressees: addressees);
    return reason;
  }

  /// Stop recording and write **no** closing record, leaving the turn open —
  /// which is what a reload reads as one the process died in the middle of,
  /// and so what makes it one to offer to carry on. See "Carrying on an
  /// interrupted turn".
  Future<void> interrupt() => _stop(null);

  /// Stop recording, with [reason] closing the log or null leaving it open.
  /// The last of the reply goes in the same write, since every append is an
  /// open and a close of the file.
  Future<void> _stop(TurnEnd? reason,
      {List<String> addressees = const []}) async {
    flushDeltas();
    _checkpoint?.cancel();
    _checkpoint = null;
    final ending = _messageId;
    if (ending == null) return;
    _messageId = null;
    await _enqueue(() => _appendChanged(ending, then: [
          if (reason != null)
            ChatRecord.turnEnd(
                messageId: ending,
                reason: reason,
                addressees: addressees,
                context: _context),
        ]));
  }

  void dispose() {
    _flush?.cancel();
    _checkpoint?.cancel();
  }

  /// The answer a banner was given, superseding its "asked" part in place —
  /// the same index written again, last wins, the same bargain parts make.
  /// Called by the controller when the user answers; the banner's part keeps
  /// its place in the arrival order. No-op where the turn was never opened or
  /// the approval is not in this turn's parts (an answer racing the turn out).
  void recordApprovalAnswer(String approvalId, String answer) {
    if (_messageId == null) return;
    flushDeltas();
    final parts = List<MessagePart>.from(_parts);
    final at = parts.indexWhere(
        (p) => p is ApprovalPart && p.approvalId == approvalId && p.answer == "asked");
    if (at < 0) return;
    final asked = parts[at] as ApprovalPart;
    parts[at] =
        asked.copyWith(answer: answer);
    _publish(parts);
    checkpoint();
  }

  /// Every discrete part goes through here, and so do its record and the
  /// response it belongs to: a new kind of event cannot forget either.
  void addPart(MessagePart part) {
    flushDeltas();
    _publish([..._parts, _inResponse(part)]);
    checkpoint();
  }

  void checkpoint() {
    final logging = _messageId;
    if (_logs && logging != null) unawaited(_enqueue(() => _appendChanged(logging)));
  }

  /// Fold everything buffered into the reply's trailing part of the same kind.
  /// Must run before anything else is appended, so parts keep their arrival
  /// order.
  void flushDeltas() {
    _flush?.cancel();
    _flush = null;
    if (_pending.isEmpty) return;
    final text = _pending.toString();
    _pending.clear();
    if (_messageId == null) return;

    final parts = List<MessagePart>.from(_parts);
    final last = parts.lastOrNull;
    if (_pendingIsReasoning) {
      final at = _openReasoningAt(parts);
      if (at < 0) {
        parts.add(MessagePart.reasoning(text: text, responseId: _responseId));
      } else {
        final open = parts[at] as ReasoningPart;
        parts[at] = open.copyWith(text: "${open.text}$text");
      }
    } else if (last is TextPart && last.responseId == _responseId) {
      parts[parts.length - 1] = last.copyWith(text: "${last.text}$text");
    } else {
      parts.add(MessagePart.text(text: text, responseId: _responseId));
    }
    _publish(parts);
  }

  void _publish(List<MessagePart> parts) {
    _parts = parts;
    onParts?.call(parts);
  }

  void _bufferDelta(String text, {bool reasoning = false}) {
    if (reasoning != _pendingIsReasoning) flushDeltas();
    _pendingIsReasoning = reasoning;
    _pending.write(text);
    // Only where somebody is waiting on fresher text than the next discrete
    // part brings. A parts-only recorder is read once per step, and it flushes
    // itself when it is: timing out to rebuild the same string sixty times a
    // second for a reader that is not there copies the whole reply each time.
    if (!_logs && onParts == null) return;
    _flush ??= Timer(const Duration(milliseconds: 16), flushDeltas);
    _checkpoint ??= Timer(_checkpointEvery, () {
      _checkpoint = null;
      flushDeltas();
      checkpoint();
    });
  }

  /// A block is timed once it closes, so an untimed one is still being
  /// written. Searched for rather than assumed last: another part can land
  /// between a block's deltas and the event that closes it. Only this
  /// response's: a block left open by the one before is not this one's to fill.
  int _openReasoningAt(List<MessagePart> parts) => parts.lastIndexWhere(
      (p) => p is ReasoningPart && p.durationMs == null && p.responseId == _responseId);

  /// Close the thinking block being written. The backend's text wins over what
  /// streamed: a provider that sends no deltas still reports the whole of it.
  void _endReasoning(String? text, Duration? duration, String? signature) {
    flushDeltas();
    final parts = List<MessagePart>.from(_parts);
    final at = _openReasoningAt(parts);
    final open = at < 0 ? null : parts[at] as ReasoningPart;
    final body = text != null && text.isNotEmpty ? text : (open?.text ?? "");
    if (body.isEmpty && open == null) return;

    final sealed = MessagePart.reasoning(
      text: body,
      durationMs: duration?.inMilliseconds,
      signature: signature,
      responseId: _responseId,
    );
    if (open == null) {
      parts.add(sealed);
    } else {
      parts[at] = sealed;
    }
    _publish(parts);
    checkpoint();
  }

  void _appendError(String message) {
    if (_messageId == null) return;
    outcome ??= TurnEnd.error;
    flushDeltas();
    final parts = List<MessagePart>.from(_parts);
    final last = parts.lastOrNull;
    // A retry round replaces the failed one's error rather than stacking
    // beside it: the controller re-enters a turn that ended on an error, and
    // the only thing that can follow one is the next round's — the stream
    // closes after the event. Superseding writes the same index, which is how
    // every part that changes is written.
    if (last is ErrorPart) {
      parts[parts.length - 1] = MessagePart.error(message: message);
    } else {
      parts.add(MessagePart.error(message: message));
    }
    _publish(parts);
    checkpoint();
  }

  /// Stamp a part with the response being streamed, where it has somewhere to
  /// put it. A result belongs to the call it answers and an error to nobody, so
  /// neither carries one.
  ///
  /// Enumerated rather than defaulted, and the pair to `_responseIdOf`: a new
  /// part that carries a `responseId` and is not named here is never stamped
  /// with one, so it reads back as part of whatever response came before it.
  MessagePart _inResponse(MessagePart part) => switch (part) {
        TextPart() => part.copyWith(responseId: _responseId),
        ReasoningPart() => part.copyWith(responseId: _responseId),
        ToolCallPart() => part.copyWith(responseId: _responseId),
        ToolResultPart() ||
        ShellRunPart() ||
        FilePart() ||
        ArtifactPart() ||
        SkillInstallPart() ||
        ApprovalPart() ||
        InstructionsPart() ||
        ErrorPart() =>
          part,
      };

  /// Write whatever the reply has grown by, and [then] after it. Parts are
  /// compared rather than counted: a thinking block is closed in place, and a
  /// provider that interleaves parts can close one that is no longer last.
  ///
  /// Text that only grew is written as the piece it grew by. Writing the part
  /// whole each time would cost its length once per checkpoint, so a reply
  /// streaming for two minutes would be written a hundred times over.
  /// [forMessage] is passed rather than read here: queued work runs later, and
  /// by then the turn it belongs to may have cleared itself.
  Future<void> _appendChanged(String forMessage,
      {List<ChatRecord> then = const []}) async {
    final parts = _messageId == null || _messageId == forMessage
        ? _parts
        : const <MessagePart>[];
    final records = <ChatRecord>[];
    for (var i = 0; i < parts.length; i++) {
      if (i >= _logged.length) {
        records.add(ChatRecord.part(messageId: forMessage, index: i, part: parts[i]));
        continue;
      }
      if (_logged[i] == parts[i]) continue;
      final grown = textGrownFrom(_logged[i], parts[i]);
      records.add(grown == null
          ? ChatRecord.part(messageId: forMessage, index: i, part: parts[i])
          : ChatRecord.append(messageId: forMessage, index: i, text: grown));
    }
    records.addAll(then);
    if (records.isEmpty) return;
    await append(records);
    // After the write, so a failed one is retried by the next checkpoint
    // rather than treated as landed.
    if (parts.isNotEmpty) _logged = List.of(parts);
  }

  /// Put [work] at the end of the append queue. Failures are swallowed on
  /// purpose: a checkpoint that could not be written is not worth ending a
  /// turn over, and the next one writes what this one missed.
  Future<void> _enqueue(Future<void> Function() work) {
    final queued = _queue;
    return _queue =
        (queued == null ? Future<void>.sync(work) : queued.then((_) => work()))
            .catchError((Object _) {});
  }
}
