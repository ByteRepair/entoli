/// A chat's goal: what `/goal <objective>` sets, and what keeps the agent
/// working across stops until a reviewer reads the conversation and finds it
/// met. See "Goals" in `lib/domain/AGENTS.md`.
library;

import "models.dart";
import "system_notification.dart";

/// Where a goal stands. Only [active] is reviewed when the agent stops; the
/// other three are kept so the composer can say how it ended, until the user
/// clears it or sets another.
enum GoalStatus {
  /// Reviewed whenever a reply ends with no tool call.
  active,

  /// The user paused it, or the turn did, for a model that kept stopping
  /// without doing anything. `/goal resume` carries on.
  paused,

  /// The reviewer found the objective met.
  met,

  /// The reviewer found it cannot be met as things stand — it needs the user.
  blocked,
}

/// A chat's goal as it stands: the fold of the `goal` records on the thread
/// being read ([goalOf]), so it is the log's, and a restart rebuilds it.
class ChatGoal {
  const ChatGoal({
    required this.objective,
    this.status = GoalStatus.active,
    this.reason,
  });

  /// What the user asked for, as typed after `/goal`.
  final String objective;

  final GoalStatus status;

  /// The reviewer's last word on it, or why it was paused.
  final String? reason;

  bool get isActive => status == GoalStatus.active;

  @override
  bool operator ==(Object other) =>
      other is ChatGoal &&
      other.objective == objective &&
      other.status == status &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(objective, status, reason);
}

/// Where a goal stands after [change], or null where it leaves no goal.
GoalStatus? goalStatusAfter(GoalChange change) => switch (change) {
  GoalChange.set || GoalChange.resumed => GoalStatus.active,
  GoalChange.paused => GoalStatus.paused,
  GoalChange.met => GoalStatus.met,
  GoalChange.blocked => GoalStatus.blocked,
  GoalChange.cleared => null,
  // Nothing moved, so there is no status to leave it in; [goalOf] reads this
  // as "no change", which is the whole of what an answer is.
  GoalChange.answered => null,
};

/// The goal [marks] leave, in order: a set starts one, a clear ends it,
/// everything else moves the one there is, and an answer moves nothing at all
/// — it is a row the user reads, not a change to what stands. A mark about a
/// goal that is not the one standing — a stale verdict landing after a new
/// `/goal` — moves nothing either.
ChatGoal? goalOf(Iterable<GoalMark> marks) {
  ChatGoal? goal;
  for (final mark in marks) {
    if (!mark.change.changesGoal) continue;
    final starts = mark.change == GoalChange.set;
    if (!starts && goal?.objective != mark.objective) continue;
    goal = switch (goalStatusAfter(mark.change)) {
      null => null,
      final status => ChatGoal(
        objective: mark.objective,
        status: status,
        reason: status == GoalStatus.active ? null : mark.reason,
      ),
    };
  }
  return goal;
}

/// The goal a chat's log leaves it with.
extension ChatGoals on Chat {
  ChatGoal? get goal => goalOf(goals);
}

/// How many reviews in a row, in one turn, may follow a stretch with no tool
/// call before the goal pauses: a model that only talks is not getting closer.
const maxGoalStalls = 3;

/// The chat's goal as a turn reaches it: read at every stop, off the room's
/// copy of the log, so a pause or a clear mid-turn lands before the next
/// review.
typedef GoalReader = ChatGoal? Function();

/// What `/goal` was asked to do, read off the arguments after the name.
sealed class GoalCommand {
  const GoalCommand();

  /// The message that sends this command — the inverse of [goalCommandOf].
  String get text;

  /// Whether it hands a turn to a model: setting a goal and resuming one do,
  /// the rest only change the goal.
  bool get runsModel => false;
}

/// `/goal <objective>`: replace whatever goal there was and start working.
class GoalSet extends GoalCommand {
  const GoalSet(this.objective);
  final String objective;

  @override
  String get text => "/goal $objective";

  @override
  bool get runsModel => true;
}

/// `/goal` alone: say what the goal is and where it stands.
class GoalShow extends GoalCommand {
  const GoalShow();

  @override
  String get text => "/goal";
}

/// `/goal pause`: stop reviewing, keep the goal.
class GoalPause extends GoalCommand {
  const GoalPause();

  @override
  String get text => "/goal pause";
}

/// `/goal resume`: review again, and start a turn to carry on.
class GoalResume extends GoalCommand {
  const GoalResume();

  @override
  String get text => "/goal resume";

  @override
  bool get runsModel => true;
}

/// `/goal clear`, and the words Claude Code takes for it.
class GoalClear extends GoalCommand {
  const GoalClear();

  @override
  String get text => "/goal clear";
}

const _clearWords = {"clear", "stop", "off", "reset", "none", "cancel"};

/// The command [arguments] — what follows `/goal` — names. One word that is
/// a verb is the verb; anything else is an objective, so "pause the build
/// on red" is a goal and "pause" is not.
GoalCommand goalCommandOf(String arguments) {
  final words = arguments.trim();
  return switch (words.toLowerCase()) {
    "" => const GoalShow(),
    "pause" => const GoalPause(),
    "resume" => const GoalResume(),
    final w when _clearWords.contains(w) => const GoalClear(),
    _ => GoalSet(words),
  };
}

/// What the model reads in place of `/goal <objective>`: the work, and how it
/// will be judged. Worded from the log by the projection, so a reload and a
/// resend read the same.
String goalKickoff(String objective) => [
  "The user set a goal for this conversation:",
  "",
  "<goal>",
  objective,
  "</goal>",
  "",
  "Work toward it until it is fully achieved, then finish with a reply "
      "that shows the evidence: what you ran or checked, and what it showed. "
      "Each time you end a reply without a tool call, a reviewer reads the "
      "conversation and decides whether the goal is met. A claim without "
      "evidence does not count, and if it is not met you will be asked to "
      "carry on. If you are blocked — you need the user's decision, access "
      "or information — say so plainly and stop.",
].join("\n");

/// What the model reads in place of `/goal resume`.
const goalResumedText =
    "The user resumed the goal set earlier in this conversation. Carry on "
    "working toward it until it is fully achieved, and finish with a reply "
    "that shows the evidence.";

/// The reviewer's verdict, sent back as a nudge: the goal, why it is not met
/// yet, and the next step where the reviewer named one.
String goalNudge(String objective, String reason, String? next) =>
    systemNotification([
      "The goal is not met yet, so the turn carries on.",
      "<goal>",
      objective,
      "</goal>",
      "Reviewer: $reason",
      if (next != null && next.trim().isNotEmpty) "Next step: ${next.trim()}",
      "Take the next concrete step now, verify the result, and show the "
          "evidence. If you are blocked, say so plainly and stop.",
    ]);

/// Where a goal stands, in one line: "Goal active: ship it". The one wording
/// for it, so the strip's tooltip and a row that reports one cannot drift.
String goalHeadline(ChatGoal goal) =>
    "${goalStatusLabel(goal.status)}: ${goal.objective}";

/// The status line for the goal row's tooltip.
String goalSummary(ChatGoal? goal) => goal == null
    ? "No goal is set. Set one with /goal <objective>"
    : [goalHeadline(goal), ?goal.reason].join(" · ");

/// What a `/goal` that changed nothing found, as the row it leaves.
///
/// A command that changes no goal — a clear with nothing to clear, a pause of
/// a goal already paused, `/goal` alone — reports rather than changes, so its
/// row is worded as the answer it is: the state it found, or that there was
/// none. See [GoalChange.answered].
String goalAnswer(ChatGoal? goal) =>
    goal == null ? "No goal was set" : goalHeadline(goal);

/// What a goal standing at [status] is called on screen.
String goalStatusLabel(GoalStatus status) => switch (status) {
  GoalStatus.active => "Goal active",
  GoalStatus.paused => "Goal paused",
  GoalStatus.met => "Goal met",
  GoalStatus.blocked => "Goal blocked",
};

/// What a [GoalMark] says happened, as its row in the conversation reads.
String goalChangeLabel(GoalChange change) => switch (change) {
  GoalChange.set => "Goal set",
  GoalChange.resumed => "Goal resumed",
  GoalChange.paused => "Goal paused",
  GoalChange.cleared => "Goal cleared",
  GoalChange.met => "Goal met",
  GoalChange.blocked => "Goal blocked",
  GoalChange.answered => "Goal answered",
};
