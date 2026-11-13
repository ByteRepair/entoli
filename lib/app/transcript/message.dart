import "../../domain/bot_avatar/pose.dart" show BotMood;
import "../../domain/models.dart";
import "../../domain/shell.dart" show shellBypassCommand;
import "../../domain/system_notification.dart";
import "../../domain/wired_skill.dart";
import "../settings/spec.dart" show SettingReader;
import "activity.dart";

/// What a stretch of a message sits on: nothing — a reply, which is the page
/// rather than something said to one side of it — or the fill of a prompt,
/// a command the user ran, the app's own notice, a tool's or the system's.
enum BubbleTint { none, prompt, command, notice, tool, system }

/// Who the message's name over it says spoke, or null for a reply, which
/// has none: nothing else in a conversation is drawn full width and
/// unbubbled, so a name over every reply was the layout said twice.
class Speaker {
  const Speaker(this.name, this.tint);

  final String? name;
  final BubbleTint tint;
}

/// Who said a system notification, where the user's name would be.
const noticeSpeaker = "System";

/// One stretch of a message, in the order it happened. A sealed set the
/// frontends switch over.
sealed class MessageBlock {
  const MessageBlock();
}

/// What was said, in a bubble or, for a reply, on the page: the files a
/// prompt was sent with, its text, and what trails the last thing said.
final class BubbleBlock extends MessageBlock {
  const BubbleBlock({
    required this.tint,
    this.files = const [],
    this.said = const [],
    this.trailing = const [],
  });

  final BubbleTint tint;
  final List<FilePart> files;
  final List<Said> said;
  final List<Trailing> trailing;
}

/// An activity on a row of its own.
final class ActivityBlock extends MessageBlock {
  const ActivityBlock(this.node);

  final ActivityNode node;
}

/// Two or more activities none of which is important, behind one toggle,
/// collapsed until opened. [start] is the first one's part index, which is
/// what keeps the toggle's state across a streamed delta's rebuild.
final class ActivityRunBlock extends MessageBlock {
  const ActivityRunBlock(this.start, this.nodes);

  final int start;
  final List<ActivityNode> nodes;
}

/// A file the reply made, below the call that made it.
final class FileBlock extends MessageBlock {
  const FileBlock(this.file);

  final FilePart file;
}

/// A command the user ran, and what it printed: the answer to their message
/// rather than something the turn did on its way to one.
final class ShellRunBlock extends MessageBlock {
  const ShellRunBlock(this.run);

  final ShellRunPart run;
}

/// What the user said while the turn ran, where the turn read it — or what
/// the app said to it, which is not theirs.
final class SteerBlock extends MessageBlock {
  const SteerBlock(this.message, {required this.notice});

  final Message message;
  final bool notice;

  String get heading => "${notice ? noticeSpeaker : "You"}, while it worked";

  BubbleBlock get bubble => BubbleBlock(
    tint: notice ? BubbleTint.notice : BubbleTint.prompt,
    files: message.files.toList(),
    said: [if (message.hasText) ProseSaid(message.plainText)],
  );
}

/// One thing said in a bubble.
sealed class Said {
  const Said();
}

/// Markdown, ending in a caret while it is still being written.
final class ProseSaid extends Said {
  const ProseSaid(this.markdown, {this.caret = false});

  final String markdown;
  final bool caret;
}

final class ErrorSaid extends Said {
  const ErrorSaid(this.message);

  final String message;

  String get text => "Error: $message";
}

/// A `!` message, set apart as the command it runs.
final class CommandSaid extends Said {
  const CommandSaid(this.command);

  final String command;
}

/// What trails the last thing a message said: turn state rather than parts.
sealed class Trailing {
  const Trailing();
}

/// Stands in for the reply until its first text arrives: [status] is what
/// the turn is doing, [notice] what has gone wrong with it, and trouble wins
/// the one row there is.
final class WaitingTrailing extends Trailing {
  const WaitingTrailing({this.status, this.notice});

  final String? status;
  final String? notice;

  String? get line => notice ?? status;
}

/// What a running command has printed so far.
final class LiveOutputTrailing extends Trailing {
  const LiveOutputTrailing(this.output);

  final String output;
}

/// A failed turn's way on, so it is not a dead end.
final class RetryTrailing extends Trailing {
  const RetryTrailing();
}

/// The turn state a message is laid out against: whether it is the one
/// being written, what the turn says beside its spinner, and what a running
/// command has printed under it.
class MessageMoment {
  const MessageMoment({
    this.waiting = false,
    this.status,
    this.notice,
    this.shellOutput,
    this.canRetry = false,
  });

  static const still = MessageMoment();

  final bool waiting;
  final String? status;
  final String? notice;
  final String? shellOutput;

  /// Whether a failed turn here offers Retry.
  final bool canRetry;

  /// What its author's Bot Avatar does: thinks while it is being written.
  BotMood get mood => waiting ? BotMood.thinking : BotMood.idle;
}

/// A message split the way it reads: everything the model did as activities
/// of their own, everything it said in bubbles, in the order it happened.
/// The rules of the conversation's layout — what breaks a run of
/// activities, where the caret goes, when a spinner shows — are here, and a
/// frontend draws what this returns.
class MessageLayout {
  MessageLayout(this.message, {required this.chatId, required this.catalog});

  final Message message;
  final String chatId;
  final ActivityCatalog catalog;

  bool get _isUser => message.role == MessageRole.user;

  String get _text => message.plainText;

  /// A `!` message's command, or null where it is prose.
  late final String? command = _isUser ? shellBypassCommand(_text) : null;

  /// Whether this prompt runs a callback (`/compact`).
  late final bool wired = _isUser && wiredSkillFromText(_text) != null;

  /// Whether this prompt is the app's notification rather than the user's.
  late final bool notice = _isUser && isSystemNotification(_text);

  Speaker get speaker => switch (message.role) {
    MessageRole.user when notice => const Speaker(
      noticeSpeaker,
      BubbleTint.notice,
    ),
    // A command the user ran is not something they said, so it is not in
    // the colour the things they said are in.
    MessageRole.user => Speaker(
      "You",
      command == null && !wired ? BubbleTint.prompt : BubbleTint.command,
    ),
    MessageRole.assistant => Speaker(message.author, BubbleTint.none),
    MessageRole.tool => const Speaker("Tool", BubbleTint.tool),
    MessageRole.system => const Speaker("System", BubbleTint.system),
  };

  /// The turn's last round failed: within a round nothing follows an error,
  /// so a turn that ended on one has it trailing.
  bool get hasError => message.parts.lastOrNull is ErrorPart;

  List<MessageBlock> blocks(SettingReader reader, MessageMoment moment) =>
      _Assembler(this, reader, moment).run();
}

class _Assembler {
  _Assembler(this.layout, this.reader, this.moment);

  final MessageLayout layout;
  final SettingReader reader;
  final MessageMoment moment;

  final _out = <MessageBlock>[];
  final _said = <Said>[];
  late var _files = layout._isUser
      ? layout.message.files.toList()
      : <FilePart>[];

  final _gathered = <ActivityNode>[];
  var _runStart = -1;

  Message get _message => layout.message;

  List<MessageBlock> run() {
    final parts = _message.parts;
    // The part a running turn is working on: the thinking block that has
    // not closed, and the text still being written.
    final liveAt = moment.waiting && parts.isNotEmpty ? parts.length - 1 : null;
    // A running turn shows a caret at the end of the text being written, or
    // a spinner when there is no such text, never both.
    final carets = liveAt != null && parts[liveAt] is TextPart;
    final results = _message.toolResults;
    final calls = {
      for (final part in parts.whereType<ToolCallPart>()) part.toolCall.id,
    };

    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      switch (part) {
        case ToolResultPart(:final result) when calls.contains(result.callId):
          // Shown by the call it answers.
          continue;
        case ReasoningPart() ||
            ToolCallPart() ||
            ToolResultPart() ||
            InstructionsPart() ||
            ApprovalPart() ||
            ArtifactPart() ||
            SkillInstallPart():
          final activity = layout.catalog.of(part)!;
          final run = _runOf(part, i, results, live: i == liveAt);
          // What breaks a run of activities: one important of itself, the
          // call the live turn is on, and a run that came back failed.
          final important =
              activity.important(run) ||
              (i == liveAt && part is ToolCallPart) ||
              run.failed;
          final node = activity.node(reader, run);
          if (important) {
            _flushRun();
            _out.add(ActivityBlock(node));
            break;
          }
          if (_runStart == -1) _runStart = i;
          _gathered.add(node);
        case FilePart():
          if (layout._isUser) continue;
          _flushRun();
          _closeBubble();
          _out.add(FileBlock(part));
        case ReactionPart():
          // A reaction shows on the message it answers.
          continue;
        case ShellRunPart():
          _flushRun();
          _closeBubble();
          _out.add(ShellRunBlock(part));
        case TextPart(:final text):
          // Text with a tool call under it stopped arriving before the call
          // started, so a caret there would point at nothing.
          _flushRun();
          final command = layout.command;
          _said.add(
            command == null
                ? ProseSaid(text, caret: i == liveAt)
                : CommandSaid(command),
          );
        case ErrorPart(:final message):
          _flushRun();
          _said.add(ErrorSaid(message));
        case SteerPart(:final message):
          _flushRun();
          _closeBubble();
          _out.add(
            SteerBlock(
              message,
              notice: isSystemNotification(message.plainText),
            ),
          );
      }
    }
    _flushRun();
    _closeBubble(
      trailing: [
        if (moment.waiting && !carets && !_message.hasText)
          WaitingTrailing(status: moment.status, notice: moment.notice),
        // Not gated on waiting, which is the last message's: a message said
        // after this reply would take the block.
        if (moment.shellOutput case final output?) LiveOutputTrailing(output),
        if (layout.hasError && !moment.waiting && moment.canRetry)
          const RetryTrailing(),
      ],
    );
    return _out;
  }

  void _closeBubble({List<Trailing> trailing = const []}) {
    if (_said.isEmpty && trailing.isEmpty && _files.isEmpty) return;
    _out.add(
      BubbleBlock(
        tint: layout.speaker.tint,
        files: _files,
        said: _said.toList(),
        trailing: trailing,
      ),
    );
    _files = const [];
    _said.clear();
  }

  void _flushRun() {
    if (_gathered.isEmpty) return;
    _closeBubble();
    if (_gathered.length >= 2) {
      _out.add(ActivityRunBlock(_runStart, _gathered.toList()));
    } else {
      _out.addAll(_gathered.map(ActivityBlock.new));
    }
    _gathered.clear();
    _runStart = -1;
  }

  Run _runOf(
    MessagePart part,
    int at,
    Map<String, ToolResult> results, {
    required bool live,
  }) {
    final chatId = layout.chatId;
    return switch (part) {
      ToolCallPart(:final toolCall) => Run(
        chatId: chatId,
        callId: toolCall.id,
        call: toolCall,
        result: results[toolCall.id],
        going: live && _message.hasText,
      ),
      ToolResultPart(:final result) => Run(
        chatId: chatId,
        callId: result.callId,
        result: result,
      ),
      ApprovalPart(:final approvalId) => Run(
        chatId: chatId,
        part: part,
        result: results[approvalId],
      ),
      ReasoningPart(:final durationMs) => Run(
        chatId: chatId,
        part: part,
        at: at,
        going: live && durationMs == null,
      ),
      _ => Run(chatId: chatId, part: part, at: at),
    };
  }
}
