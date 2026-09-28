import "dart:typed_data";

import "package:collection/collection.dart";

import "../../domain/ask.dart";
import "../../domain/models.dart";
import "../../domain/prompt_library.dart";
import "llm/llm_client.dart";
import "templates.dart";

/// The conversation as a provider has to see it, built out of what `conv.jsonl`
/// kept. This is what makes a session that missed the conversation — rewound,
/// or belonging to a chat opened after a restart — answer as though it had been
/// there all along.
///
/// A domain assistant [Message] is a whole turn, and a turn is several provider
/// responses; each has to go back as one assistant message with its own
/// thinking, text and calls, followed by the results answering them. The parts
/// say which response they came out of, so the grouping is read rather than
/// guessed.
///
/// Named for the projection rather than `project`, which everywhere else in
/// this codebase is the directory a chat lives in.
///
/// **This is the only thing that words a conversation for a model**, the turn
/// being sent included — `BuiltinAgent._openTurn` projects the message it is
/// about to log rather than wording one of its own. See "The projection" in
/// `lib/domain/CLAUDE.md` for what that is worth and what it costs.
///
/// [first] says whether the first user message in [messages] is also the first
/// of the conversation, which is the one dressed as a task. False where this is
/// a fragment appended to a session that already holds the rest — see
/// `_runBypass`.
///
/// [viewer] is whose session this projection words the conversation for — null
/// for the main agent, a member's `@name` for their own. A reply authored by
/// another participant is worded as a user-role message labeled with who wrote
/// it, so the viewer's model never reads another agent's words as its own; the
/// human user's messages stay exactly as they are. A reply with no author is
/// the viewer's own — today every conversation's shape, and byte-identical
/// to what this worded before Omada existed.
///
/// [load] answers with a resource's bytes. Asynchronous for that alone, which
/// is what it costs to hand a model the image it was sent rather than the name
/// of it.
///
/// [compactions] are the markers on the thread [messages] walks — the last one
/// is what the model reads instead of everything before its boundary, the
/// earlier ones being shadows an earlier compaction left. A marker whose
/// boundary is not among [messages] is ignored, which is what makes a fragment
/// (a `history` that stops short of it) project the span it was handed whole.
/// The boundary message itself is summarized too, so the first message after a
/// marker is the first thing the model reads verbatim — and `first` applies
/// to the message the summary stands in for, so the task dress lands on the
/// turn that opened the work.
Future<List<LlmMessage>> projectionOf(
  List<Message> messages, {
  bool first = true,
  required ResourceLoader load,
  String? viewer,
  List<ConversationCompaction> compactions = const [],
}) async {
  // The newest marker whose boundary the projection was handed, and where it
  // sits. Anything before it is summarized; anything after it is verbatim.
  // LastIndexWhere rather than indexWhere: an earlier marker is a shadow the
  // newest one replaced, and the log can hold any number of those.
  //
  // Decided before the bytes are read, which is the point: the attachments of
  // the summarized span are the expensive half of what the summary replaces,
  // and the compacted tail is loaded whole. The ids decide the boundary, so
  // this is one pass over ids before any load, not a scan per marker.
  final live = {
    for (final m in messages) m.id: m,
  };
  final marker = compactions.lastWhereOrNull((c) => live[c.upToMessageId] != null);
  final from = marker == null
      ? 0
      : messages.indexWhere((m) => m.id == marker.upToMessageId) + 1;
  // Every resource at once rather than a message at a time: on the web each
  // read is its own IndexedDB transaction, and a long conversation's would
  // otherwise be one round trip after another. Only the verbatim half's bytes
  // are read — the summarized span's are what the summary replaced.
  final files = await Future.wait(messages.asMap().entries.map((e) =>
      e.value.role == MessageRole.user && e.key >= from
          ? _attachments(e.value, load)
          : _noFiles));
  final projected = <LlmMessage>[];
  if (marker != null) {
    projected.add(LlmMessage(role: LlmRole.user, text: summarizedTurnText(marker.summary)));
  }
  for (final (index, message) in messages.indexed) {
    // Before the marker: summarized, and the attachments with it — the bytes
    // are the expensive half of what the summary replaces.
    if (index < from) continue;
    switch (message.role) {
      case MessageRole.user:
        final text = _userText(message);
        if (text.isNotEmpty) {
          projected.add(LlmMessage(
            role: LlmRole.user,
            text: userTurnText(text, at: message.createdAt, first: first && index == from),
            attachments: files[index],
          ));
        }
      case MessageRole.assistant:
        // Someone else's reply reaches this viewer labeled as theirs: an
        // assistant message is, by provider convention, the model's own words,
        // and a member's reply projected as one would have the viewer's model
        // believe it wrote what it reads. Identities are compared in the
        // library's dialect — the sigil off both sides, the unnamed reply the
        // main agent's — which is the dialect [viewer] is carried in.
        final theirs = nameOf(message.author) ?? mainAgentLabel;
        if (theirs != (viewer ?? mainAgentLabel)) {
          final said = _saidText(message);
          if (said != null) {
            projected.add(LlmMessage(
              role: LlmRole.user,
              text: peerTurnText(said, by: theirs, at: message.createdAt),
            ));
          }
          // A peer reply's tool calls are its own session's business: the
          // viewer reads what was said, not the commands behind it.
          continue;
        }
        projected.addAll(_assistant(message));
      case MessageRole.system:
      case MessageRole.tool:
        // The system prompt is rewritten every turn, and a result is a part of
        // the turn that ran it rather than a message of its own.
        break;
    }
  }
  return projected;
}

/// Where a resource's bytes are, given the name a [FilePart] holds. Null for
/// one that is no longer on disk, which is a file named to the model rather
/// than a turn that fails.
typedef ResourceLoader = Future<Uint8List?> Function(String resource);

/// A projection with nothing behind it to read bytes from: a sub-agent's
/// transcript, which holds no user message and so no file part, and the tests
/// that project a conversation no chat on disk ever held.
Future<Uint8List?> noResources(String resource) async => null;

/// A message no log will hold: the reply a `!` turn writes, a sub-agent's task.
/// The id is the one field [projectionOf] does not read.
Message unloggedMessage(MessageRole role, DateTime at, List<MessagePart> parts) =>
    Message(id: "", role: role, createdAt: at, parts: parts);

/// Expanded first, decorated second. The other order hands `$ARGUMENTS` the
/// `(attached: …)` note, so `/review` with a file attached would substitute the
/// decoration into the middle of the command's template.
///
/// Files are named as well as sent: the bytes carry no filename, and one whose
/// resource has gone is left with nothing but its name.
String _userText(Message message) {
  final text = expandedPrompt(message.plainText, message.documents).trim();
  final files = message.files.map((f) => f.filename).join(", ");
  if (files.isEmpty) return text;
  return text.isEmpty ? "(attached: $files)" : "$text\n\n(attached: $files)";
}

final Future<List<LlmAttachment>> _noFiles = Future.value(const []);

Future<List<LlmAttachment>> _attachments(Message message, ResourceLoader load) async {
  final loaded = await Future.wait(message.files.map((file) async {
    final bytes = await load(file.resource);
    return bytes == null
        ? null
        : LlmAttachment(
            filename: file.filename, mimeType: file.mimeType, bytes: bytes);
  }));
  return loaded.nonNulls.toList();
}

/// One turn's reply as the provider messages it becomes: one per response, each
/// followed by the results answering its calls. What a running turn puts in
/// front of the model, and what a reload rebuilds — the same function, so there
/// is nothing to keep level. See "One accumulation" in `lib/domain/CLAUDE.md`.
Iterable<LlmMessage> assistantMessages(List<MessagePart> parts) =>
    _assistant(unloggedMessage(MessageRole.assistant, _noDate, parts));

/// What another participant said in a reply, worded for a different viewer:
/// the plain text of it, which is what one agent owes another. Thinking and
/// tool calls are the author's own session's business; a run the reader never
/// watches is reported by what was said about it.
String? _saidText(Message message) {
  final said = message.plainText.trim();
  return said.isEmpty ? null : said;
}

/// A reply's date is not read by anything that words one, so a turn being
/// assembled has none to give.
final _noDate = DateTime.fromMillisecondsSinceEpoch(0);

Iterable<LlmMessage> _assistant(Message message) sync* {
  // Over the whole message rather than per response: a result is paired to its
  // call by id, and one that landed in a later response than the call it
  // answers must not be read as missing.
  final results = message.toolResults;

  // The directory the shell is standing in, as the parts of this message
  // report it, walked in the order the commands ran. It starts nowhere, which
  // is what keeps the turn's opening move un-noted — the model ran the `cd`
  // itself — and it is the whole of the tracking, since the note is derived
  // from the fact the part carries rather than held on the session. A reload
  // walks the same parts in the same order, so it words the same notes.
  String? cwd;
  String noted(String text, String? moved) {
    final note = cwdChangedNote(cwd, moved);
    if (moved != null) cwd = moved;
    return note == null ? text : "$text\n\n$note";
  }

  for (final response in _responses(message.parts)) {
    final reasoning = StringBuffer();
    final text = StringBuffer();
    String? signature;
    final calls = <LlmToolCall>[];

    for (final part in response) {
      switch (part) {
        case ReasoningPart():
          reasoning.write(part.text);
          signature ??= part.signature;
        case TextPart():
          text.write(part.text);
        case ToolCallPart(:final toolCall):
          calls.add(LlmToolCall(
            id: toolCall.id,
            name: toolCall.name,
            argumentsJson: toolCall.argumentsJson ?? "{}",
          ));
        case ShellRunPart():
          // The user's own command, worded as what the app did for them. It is
          // the whole of its turn, so there is nothing else in this response
          // for it to run into.
          text.write(noted(
            shellRunTranscript(
              command: part.command,
              returnCode: part.returnCode,
              output: part.output,
              exceptionInfo: part.exceptionInfo,
              violations: part.violations,
            ),
            part.cwd,
          ));
        case ToolResultPart():
        case FilePart():
        case ArtifactPart():
        case SkillInstallPart():
        case ApprovalPart():
        case ErrorPart():
          // Results are read off `results` by the call they answer. An error is
          // what the turn reported to the user; the model never saw it, so
          // putting it back would be inventing an exchange. An artifact is
          // view-only output; the model sees the call that produced it, not the
          // page. A permission banner is the gate's question, not the model's —
          // the model saw the command it triggered and the result it produced,
          // and nothing of the banner between them.
          break;
      }
    }

    if (reasoning.isEmpty && text.isEmpty && calls.isEmpty) continue;

    yield LlmMessage(
      role: LlmRole.assistant,
      text: text.toString(),
      reasoning: reasoning.isEmpty ? null : reasoning.toString(),
      reasoningSignature: signature,
      toolCalls: calls,
    );

    // Every call is answered, including one whose result never landed: a
    // provider that sees a tool call with no result rejects the next turn.
    for (final call in calls) {
      final result = results[call.id];
      yield LlmMessage(
        role: LlmRole.tool,
        toolCallId: call.id,
        text: result == null
            ? _interruptedText(call.name)
            : noted(_toolResultText(call.name, result), result.cwd),
      );
    }
  }
}

/// The parts of one turn, split into the responses they came out of. A part
/// naming no response — a result, an error — continues the one before it, since
/// that is the response it belongs to.
List<List<MessagePart>> _responses(List<MessagePart> parts) {
  final responses = <List<MessagePart>>[];
  String? current;
  for (final part in parts) {
    final id = _responseIdOf(part);
    if (responses.isEmpty || (id != null && id != current)) {
      responses.add([]);
      current = id;
    }
    responses.last.add(part);
  }
  return responses;
}

/// Enumerated rather than defaulted: a new part that carries a `responseId`
/// and is not named here groups into the response before it, which is a wrong
/// answer no test would ask about. See "One accumulation".
String? _responseIdOf(MessagePart part) => switch (part) {
      TextPart(:final responseId) ||
      ReasoningPart(:final responseId) ||
      ToolCallPart(:final responseId) =>
        responseId,
      ToolResultPart() ||
      ShellRunPart() ||
      FilePart() ||
      ArtifactPart() ||
      SkillInstallPart() ||
      ApprovalPart() ||
      ErrorPart() =>
        null,
    };

/// **How a tool's outcome is worded for a model, and the only place it is.**
/// A turn reports its results and nothing else: the model is answered with this,
/// off the part that was reported, whether the turn is running now or being read
/// back out of the log.
///
/// An `ask_user` that was answered reads as the answers themselves — it is the
/// user talking, not a command reporting. One that failed does not: the reason
/// is in `exceptionInfo` and the answers are empty, so it reads as any other
/// failure would.
String _toolResultText(String tool, ToolResult result) =>
    tool == askToolName && result.returnCode == 0 ? result.output : _observed(result);

/// [observation] of a result, memoised on the result itself. A running turn
/// re-words its whole reply after every step — see "One accumulation" — and
/// encoding a ten-kilobyte command output as JSON forty times over is the bulk
/// of what that costs. The result is an immutable value in an immutable part,
/// so the same instance always words the same way; every instance a reload
/// builds is fresh and simply misses.
///
/// Only this branch is memoised, and that is deliberate: it is the expensive
/// one, and it is the one that does not depend on which tool was called, so
/// the result alone is the whole of the key.
String _observed(ToolResult result) => _observations[result] ??= observation(
      returnCode: result.returnCode,
      output: result.output,
      exceptionInfo: result.exceptionInfo,
      violations: result.violations,
    );

final _observations = Expando<String>("observation");

/// A call whose result never landed, which is a turn killed between making it
/// and writing the answer down. One wording for every tool: which one it was is
/// in the call the model can already see, and refining "it may not have run"
/// per tool is second-guessing an interruption nothing here witnessed. Split
/// only where [_toolResultText] splits — an `ask_user` is answered in prose either
/// way, never as a command's outcome.
String _interruptedText(String tool) =>
    tool == askToolName ? _askInterrupted : _interrupted;

const _askInterrupted = "The turn was interrupted before these questions reached "
    "the user, so nothing was answered.";

final _interrupted = observation(
  returnCode: -1,
  output: "",
  exceptionInfo: "The turn was interrupted before this returned, so its result "
      "was never recorded. It may or may not have run — check rather than assume.",
);
