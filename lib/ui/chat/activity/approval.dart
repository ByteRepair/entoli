import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/models.dart";
import "activity.dart";
import "tool_run.dart" show PermissionOutcome;

/// A permission banner the turn raised, once it is history: what was asked
/// (the call, worded as the banner worded it) and what was answered. The
/// panel that asked is gone by then; this reads the recorded part, and the
/// result the call it asked about produced, which carries what decided the
/// call. A superseded answer reads in place — "asked" without an answer is a
/// turn that ended with the banner up, which the deny-on-end recorded instead.
class ApprovalActivity extends LabelledActivity {
  const ApprovalActivity();

  /// The user's own decision, and a run of them collapses behind a toggle the
  /// reader will never expand.
  @override
  bool important(Run run) => true;

  @override
  RunView view(WidgetRef ref, Run run) {
    final part = run.part! as ApprovalPart;
    final result = run.result;
    // Raw answers, not the mapped wording: "deny" is what the enum records.
    final denied =
        part.answer == "deny" || part.answer == "asked";
    final answer = switch (part.answer) {
      "asked" => "asked (never answered)",
      "allow" => "allowed",
      "alwaysAllowChat" => "allowed, always in this chat",
      "alwaysAllowProject" => "allowed, always in this project",
      "deny" => "denied",
      _ => part.answer,
    };
    // The outcome names what stood behind the call's fate, the answer what
    // was pressed: on an "always" answer the two say the same thing, so the
    // clause is left off there — and on a re-prompt's, whose result records
    // the rerun the answer went on to, the first banner would wear the
    // rerun's outcome.
    final outcome = result?.permissionOutcome;
    final clause = switch (part.answer) {
      "alwaysAllowChat" || "alwaysAllowProject" || "asked" => null,
      // A re-prompt's result records the rerun the answer went on to; the
      // first banner must not wear that rerun's outcome.
      _ when part.deniedDirs.isNotEmpty => null,
      _ => outcome,
    };
    return RunView(
      icon: denied ? Icons.gpp_maybe_outlined : Icons.gpp_good_outlined,
      label: clause == null
          ? "Permission: ${part.toolName} — $answer"
          : "Permission: ${part.toolName} — $answer ($clause)",
      isError: denied,
      markError: false,
      drawer: (_) => RunDrawer(
        title: "Permission",
        mono: true,
        sections: [
          (label: part.toolName, body: part.argumentsText, isError: false),
          if (part.deniedDirs.isNotEmpty)
            (
              label: "Sandbox dirs granted",
              body: part.deniedDirs.join("\n"),
              isError: false,
            ),
          (label: "Answer", body: answer, isError: false),
          if (outcome != null) (label: "Outcome", body: outcome, isError: false),
        ],
      ),
    );
  }
}
