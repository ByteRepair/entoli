import "dart:convert";

import "../../core/log.dart";
import "llm/llm_client.dart";

/// What the reviewer found: the goal met, not met yet (and why, and what
/// next), or not to be met without the user.
enum GoalVerdictKind { met, carryOn, blocked }

class GoalVerdict {
  const GoalVerdict(this.kind, this.reason, {this.next});

  final GoalVerdictKind kind;
  final String reason;

  /// The step the reviewer would take next, where it named one.
  final String? next;
}

/// Reads a conversation and says whether its goal is met. The working model
/// never marks its own goal done — Claude Code's `/goal` and OpenCode's both
/// put that call to a separate reviewer, and so does this: a model that
/// believes it finished is the case the goal exists to catch.
abstract interface class GoalReviewer {
  /// Null where the reviewer gave no usable answer: the turn then ends as it
  /// would have with no goal, and the goal stays active for the next stop.
  Future<GoalVerdict?> review(String objective, List<LlmMessage> transcript);
}

/// The reviewer as one model call: the classifier model where the settings
/// name one, as Claude Code uses a small fast model, else the turn's own, as
/// OpenCode does. No tools and no session — it reads a digest of the
/// conversation and answers in JSON.
class LlmGoalReviewer implements GoalReviewer {
  LlmGoalReviewer({required this.client, required this.model});

  final LlmClient client;
  final String model;

  /// Long enough for a slow local model to read a long digest; a review that
  /// takes longer has stopped being a check on a stop.
  static const _timeout = Duration(minutes: 2);

  /// How much of the conversation's end the reviewer reads. The evidence for
  /// a goal met is in the last stretch of work; the goal itself is in the
  /// prompt.
  static const transcriptBudget = 40000;

  @override
  Future<GoalVerdict?> review(
    String objective,
    List<LlmMessage> transcript,
  ) async {
    try {
      final chunks = await client
          .stream([
            const LlmMessage(role: LlmRole.system, text: _systemPrompt),
            LlmMessage(
              role: LlmRole.user,
              text: reviewPrompt(objective, transcript),
            ),
          ], model: model)
          .timeout(_timeout)
          .toList();
      final answer = chunks.whereType<LlmCompletion>().lastOrNull?.message.text;
      final verdict = parseVerdict(answer);
      if (verdict == null) {
        logFailure("goal", "the reviewer gave no usable verdict");
      }
      return verdict;
    } catch (e) {
      logFailure("goal", "the review failed", e);
      return null;
    }
  }

  /// The JSON object in [answer], read leniently: a model that wraps it in a
  /// fence or a sentence still answered. Null where there is no verdict.
  static GoalVerdict? parseVerdict(String? answer) {
    if (answer == null) return null;
    final start = answer.indexOf("{");
    final end = answer.lastIndexOf("}");
    if (start < 0 || end <= start) return null;
    try {
      final json = jsonDecode(answer.substring(start, end + 1));
      if (json is! Map<String, dynamic>) return null;
      final kind = switch (json["verdict"]) {
        "met" || "done" => GoalVerdictKind.met,
        "continue" => GoalVerdictKind.carryOn,
        "blocked" || "impossible" => GoalVerdictKind.blocked,
        _ => null,
      };
      if (kind == null) return null;
      final reason = json["reason"];
      final next = json["next"];
      return GoalVerdict(
        kind,
        reason is String && reason.trim().isNotEmpty
            ? reason.trim()
            : "No reason given.",
        next: next is String && next.trim().isNotEmpty ? next.trim() : null,
      );
    } on FormatException {
      return null;
    }
  }

  /// The goal and the end of the conversation, as text: the reviewer may be
  /// another provider, and a transcript of tool calls it was never offered
  /// tools for is a request some providers refuse.
  static String reviewPrompt(String objective, List<LlmMessage> transcript) {
    final lines = <String>[];
    for (final m in transcript) {
      if (m.role == LlmRole.system) continue;
      final who = switch (m.role) {
        LlmRole.user => "USER",
        LlmRole.assistant => "ASSISTANT",
        LlmRole.tool => "TOOL RESULT",
        LlmRole.system => "SYSTEM",
      };
      if (m.text.trim().isNotEmpty) lines.add("[$who]\n${_clip(m.text)}");
      for (final call in m.toolCalls) {
        lines.add("[TOOL CALL ${call.name}]\n${_clip(call.argumentsJson)}");
      }
    }
    var digest = lines.join("\n\n");
    if (digest.length > transcriptBudget) {
      digest =
          "[… earlier conversation omitted …]\n\n"
          "${digest.substring(digest.length - transcriptBudget)}";
    }
    return [
      "<goal>",
      objective,
      "</goal>",
      "",
      "<conversation>",
      digest,
      "</conversation>",
      "",
      "Is the goal met? Answer with the JSON object alone.",
    ].join("\n");
  }

  /// One message's share: a long tool result is mostly its end that matters
  /// — the test summary, the exit status — so the head is what goes.
  static String _clip(String text) {
    const most = 4000;
    final t = text.trim();
    return t.length <= most ? t : "[…]\n${t.substring(t.length - most)}";
  }

  static const _systemPrompt = """
You review whether an AI agent has achieved the goal it was given. You are
not the agent and you do not continue its work: you read the conversation and
give a verdict.

Judge by evidence in the conversation — commands run and their output, files
written, checks that passed — not by the agent saying it is done. A claim with
no evidence behind it is not met. A goal met in part is not met.

Answer with one JSON object and nothing else:
{"verdict": "met" | "continue" | "blocked", "reason": "...", "next": "..."}

met: the evidence shows every part of the goal achieved.
continue: there is work left that the agent can do on its own. Say what is
missing in "reason" and the next concrete step in "next".
blocked: the goal cannot be met without the user — a decision, access,
credentials or information only they have — or cannot be met at all. Say why
in "reason".

Keep "reason" and "next" to a sentence or two each.""";
}
