import "package:collection/collection.dart";

import "../../domain/end_turn.dart" show drawnAsRow;
import "../../domain/models.dart";
import "../../domain/reaction.dart";
import "../../domain/room/room_state.dart" show ChatViewState;
import "../chat_controller.dart" show TurnDriver;

/// The conversation as rows, the core's account of what is on the page:
/// each frontend draws these, and nothing it draws decides what a row is.
class Transcript {
  const Transcript(this.chatId, this.rows);

  /// [chat] walked off its thread in order. A turn opener carrying a mode
  /// that differs from the running one leads with a [ModeRow] — both flips
  /// are rows. A compaction boundary is said after the message it covers,
  /// and a goal's change after the message its record names. A reply that
  /// ended with `end_turn` is not a row: it is on the log, not the page. Nor
  /// is a reaction: it shows on the message it answers.
  factory Transcript.of(String chatId, Chat chat, {String? compactFailure}) {
    final rows = <TranscriptRow>[];
    var on = false;
    final byBoundary = {for (final c in chat.compactions) c.upToMessageId: c};
    final goals = chat.goals.groupListsBy((g) => g.afterMessageId);
    final reactions = reactionsOn(chat.messages);
    // What a running turn appends to: the newest message that is not a
    // reaction, which a reaction queued behind the turn must not displace.
    final newest = chat.messages.lastWhereOrNull((m) => m.reaction == null);
    for (final m in chat.messages) {
      final opener = m.omadaOn;
      if (opener != null && opener != on) {
        on = opener;
        rows.add(ModeRow(on, at: m.id));
      }
      if (drawnAsRow(m)) {
        rows.add(
          MessageRow(
            m,
            last: identical(m, newest),
            reactions: reactions[m.id] ?? const [],
          ),
        );
      }
      final marker = byBoundary[m.id];
      if (marker != null) rows.add(CompactionRow(marker.summary, after: m.id));
      for (final (i, mark) in (goals[m.id] ?? const <GoalMark>[]).indexed) {
        rows.add(GoalRow(mark, key: "goal:${m.id}:$i"));
      }
    }
    if (compactFailure != null) rows.add(CompactionFailedRow(compactFailure));
    return Transcript(chatId, rows);
  }

  final String chatId;
  final List<TranscriptRow> rows;
}

/// One row of the conversation. [key] is stable across a streamed delta,
/// which is what a frontend keys its row by and what the wire sends a
/// changed row under.
sealed class TranscriptRow {
  const TranscriptRow();

  String get key;
}

final class MessageRow extends TranscriptRow {
  const MessageRow(
    this.message, {
    required this.last,
    this.reactions = const [],
  });

  final Message message;

  /// The newest message of the thread, which a running turn appends to —
  /// the spinner and the caret live on it.
  final bool last;

  /// The emoji it has been reacted with.
  final List<String> reactions;

  @override
  String get key => "message:${message.id}";
}

/// A line saying the room's mode changed before message [at].
final class ModeRow extends TranscriptRow {
  const ModeRow(this.omada, {required this.at});

  final bool omada;
  final String at;

  String get text => omada ? "Omada is turned on" : "Omada is turned off";

  @override
  String get key => "mode:$at";
}

/// Where a compaction's summary took over, [summary] being what the model
/// reads in place of the messages above.
final class CompactionRow extends TranscriptRow {
  const CompactionRow(this.summary, {required this.after});

  final String summary;
  final String after;

  static const text = "Compact Conversation";

  @override
  String get key => "compaction:$after";
}

/// The divider an automatic compaction would have left, saying why it did
/// not — at the end of the thread.
final class CompactionFailedRow extends TranscriptRow {
  const CompactionFailedRow(this.reason);

  final String reason;

  static const text = "Could not compact the conversation";

  @override
  String get key => "compaction-failed";
}

/// A change to the chat's goal.
final class GoalRow extends TranscriptRow {
  const GoalRow(this.mark, {required this.key});

  final GoalMark mark;

  @override
  final String key;
}

/// What a delete asks first, worded by whether anything is left: the last
/// thread at a branch takes the rest of the conversation with it, which is a
/// different thing to be agreeing to.
class DeleteQuestion {
  const DeleteQuestion(this.message);

  final String message;

  static const title = "Delete thread";
  static const confirmLabel = "Delete";
}

/// What can be done to one message, and doing it: the threads written where
/// it is and the steps between them, delete, edit, regenerate, react. Every
/// rule of when each is on offer is here, so the frontends' action rows are
/// a drawing of this.
class MessageActions {
  MessageActions({
    required this.message,
    required this.driver,
    required this.running,
    required this.last,
    this.threads,
  });

  /// No driver: a transcript shown read-only, a sub-agent's.
  MessageActions.none(this.message)
    : driver = null,
      running = false,
      last = false,
      threads = null;

  final Message message;
  final TurnDriver? driver;
  final bool running;
  final bool last;

  /// The threads written where this message is, oldest first and including
  /// it; null where nothing was branched here.
  final List<String>? threads;

  /// While a turn runs, the controller refuses every edit.
  bool get _mutable => driver != null && !running;

  int get threadCount => threads?.length ?? 1;
  int get thread => threads?.indexOf(message.id) ?? 0;

  /// The counter and arrows are there only where there is more than one
  /// thread: `1/1` and two dead arrows say nothing.
  bool get showsThreads => threadCount > 1;

  String get threadLabel => "${thread + 1}/$threadCount";

  /// The arrows stop at either end rather than wrapping, and are dead during
  /// a turn.
  bool canStep(int step) {
    final to = thread + step;
    return _mutable && to >= 0 && to < threadCount;
  }

  Future<void> step(int step) async {
    if (canStep(step)) await driver!.stepThread(message.id, step);
  }

  /// Copy is offered only where something was said.
  bool get canCopy => message.hasText;

  String get markdown => message.plainText;

  bool get canDelete => _mutable;

  DeleteQuestion get deleteQuestion {
    final others = threadCount - 1;
    return DeleteQuestion(
      others > 0
          ? "This thread and everything below it will be removed. The other "
                "${others == 1 ? "one stays" : "$others stay"}."
          : "This message and everything below it will be removed.",
    );
  }

  Future<void> delete() async {
    if (canDelete) await driver!.deleteThread(message.id);
  }

  bool get canEdit => _mutable && message.role == MessageRole.user;

  /// A blank message says nothing, so sending one is not what was meant.
  Future<void> edit(String text) async {
    final trimmed = text.trim();
    if (canEdit && trimmed.isNotEmpty) {
      await driver!.editAndResend(message.id, trimmed);
    }
  }

  bool get canRegenerate => _mutable;

  Future<void> regenerate() async {
    if (canRegenerate) await driver!.regenerate(message.id);
  }

  /// Any message, the user's own included; not the reply still being
  /// written.
  bool get canReact => driver != null && !(running && last);

  Future<void> react(Reaction reaction) async {
    if (canReact) await driver!.react(message.id, reaction);
  }

  /// The actions of [row] in [view], driven by [driver].
  static MessageActions of(
    MessageRow row,
    ChatViewState view,
    TurnDriver? driver,
  ) => MessageActions(
    message: row.message,
    driver: driver,
    running: view.isRunning,
    last: row.last,
    threads: driver == null ? null : view.chat?.branches[row.message.id],
  );
}
