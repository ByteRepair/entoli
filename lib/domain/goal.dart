/// A chat's goal: what `/goal <objective>` sets, and what keeps the agent
/// working across stops until a reviewer reads the conversation and finds it
/// met. See "Goals" in `lib/domain/AGENTS.md`.
library;

import "system_notification.dart";

/// Where a goal stands. Only [active] is reviewed when the agent stops; the
/// other three are kept so the composer can say how it ended, until the user
/// clears it or sets another.
enum GoalStatus {
  /// Reviewed whenever a reply ends with no tool call.
  active,

  /// The user paused it, or the loop did: too many rounds, or a model that
  /// kept stopping without doing anything. `/goal resume` carries on.
  paused,

  /// The reviewer found the objective met.
  met,

  /// The reviewer found it cannot be met as things stand — it needs the user.
  blocked,
}

/// One chat's goal, kept in its `meta.json`: read at every stop rather than
/// copied into the turn, so pausing or clearing it mid-turn lands before the
/// next review.
class ChatGoal {
  const ChatGoal({
    required this.objective,
    this.status = GoalStatus.active,
    this.rounds = 0,
    this.stalls = 0,
    this.reason,
  });

  /// What the user asked for, as typed after `/goal`.
  final String objective;

  final GoalStatus status;

  /// How many times the reviewer sent the agent back to work on this goal:
  /// said, not capped. The turn's step limit is what bounds a run of them,
  /// each send-back being a step of the turn it happens in.
  final int rounds;

  /// Reviews in a row that sent the agent back after a stretch in which it
  /// called no tool: a model saying it is done, or that it will carry on,
  /// without doing anything. [maxGoalStalls] of them pause it.
  final int stalls;

  /// The reviewer's last word on it, or why it was paused.
  final String? reason;

  bool get isActive => status == GoalStatus.active;

  ChatGoal copyWith({
    GoalStatus? status,
    int? rounds,
    int? stalls,
    String? reason,
  }) => ChatGoal(
    objective: objective,
    status: status ?? this.status,
    rounds: rounds ?? this.rounds,
    stalls: stalls ?? this.stalls,
    reason: reason ?? this.reason,
  );

  /// Running again from nothing: what `/goal resume` does to the counters, so
  /// a goal paused by a cap is not paused again by the next stop.
  ChatGoal resumed() => ChatGoal(objective: objective);

  /// Null where the JSON is not a goal, so a hand-edited file loses the goal
  /// rather than the chat's other overrides.
  static ChatGoal? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final objective = json["objective"];
    if (objective is! String || objective.trim().isEmpty) return null;
    return ChatGoal(
      objective: objective,
      status:
          GoalStatus.values.asNameMap()[json["status"]] ?? GoalStatus.paused,
      rounds: json["rounds"] as int? ?? 0,
      stalls: json["stalls"] as int? ?? 0,
      reason: json["reason"] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    "objective": objective,
    "status": status.name,
    if (rounds != 0) "rounds": rounds,
    if (stalls != 0) "stalls": stalls,
    if (reason != null) "reason": reason,
  };

  @override
  bool operator ==(Object other) =>
      other is ChatGoal &&
      other.objective == objective &&
      other.status == status &&
      other.rounds == rounds &&
      other.stalls == stalls &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(objective, status, rounds, stalls, reason);
}

/// How many reviews in a row may follow a stretch with no tool call before
/// the goal pauses: a model that only talks is not getting closer.
const maxGoalStalls = 3;

/// One chat's goal, as the turn reaches it: read at every stop, written with
/// what the review found. `ChatRepository` is the implementation, over the
/// chat's `meta.json`.
abstract interface class GoalStore {
  Future<ChatGoal?> read();
  Future<void> write(ChatGoal? goal);
}

/// What `/goal` was asked to do, read off the arguments after the name.
sealed class GoalCommand {
  const GoalCommand();
}

/// `/goal <objective>`: replace whatever goal there was and start working.
class GoalSet extends GoalCommand {
  const GoalSet(this.objective);
  final String objective;
}

/// `/goal` alone: say what the goal is and where it stands.
class GoalShow extends GoalCommand {
  const GoalShow();
}

/// `/goal pause`: stop reviewing, keep the goal.
class GoalPause extends GoalCommand {
  const GoalPause();
}

/// `/goal resume`: review again, and start a turn to carry on.
class GoalResume extends GoalCommand {
  const GoalResume();
}

/// `/goal clear`, and the words Claude Code takes for it.
class GoalClear extends GoalCommand {
  const GoalClear();
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

/// Whether `/goal` with [arguments] hands a turn to a model: setting one and
/// resuming one do, the rest only change the goal.
bool goalCommandRunsModel(String arguments) =>
    switch (goalCommandOf(arguments)) {
      GoalSet() || GoalResume() => true,
      _ => false,
    };

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

/// The status line for `/goal` alone, and the composer pill's tooltip.
String goalSummary(ChatGoal? goal) {
  if (goal == null) return "No goal is set. Set one with /goal <objective>";
  final state = switch (goal.status) {
    GoalStatus.active => "Goal active",
    GoalStatus.paused => "Goal paused",
    GoalStatus.met => "Goal met",
    GoalStatus.blocked => "Goal blocked",
  };
  return [
    "$state: ${goal.objective}",
    if (goal.rounds > 0) "${goal.rounds} round(s)",
    ?goal.reason,
  ].join(" · ");
}
