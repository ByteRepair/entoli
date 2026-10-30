import "dart:convert";

import "package:flutter/material.dart";

import "../../../core/config.dart" show instructionBlockHeader;
import "../../../domain/models.dart";
import "../../../domain/tool_arg.dart";
import "activity.dart";
import "card.dart";

/// A tool run as any tool's is drawn: its name, and the arguments and output
/// behind it. [commandArg] names the argument set apart as the command the
/// call ran, [status] is the line under the drawer's title, and [title] the
/// title where the tool's name is not it.
RunView toolRunView(
  Run run, {
  String? commandArg,
  ActivityStatus? status,
  String? title,
}) {
  final call = run.call;
  final result = run.result;
  final name = call?.name;
  final verb = result == null ? "Using tool" : "Used tool";
  final outcome = result?.permissionOutcome;
  return RunView(
    icon: Icons.terminal,
    label: name == null
        ? verb
        : outcome == null
        ? "$verb: $name"
        : "$verb: $name — $outcome",
    isError:
        (result?.returnCode ?? 0) != 0 ||
        (result?.violations.isNotEmpty ?? false),
    busy: run.going && result == null,
    drawer: (_) => RunDrawer(
      title: title ?? name ?? "Tool",
      command: commandArg == null
          ? null
          : stringArg(call?.argumentsJson, commandArg),
      status: status,
      mono: true,
      sections: [
        ..._runSections(
          call,
          result,
          printing: run.printing,
          besides: commandArg,
        ),
        if (result != null && result.violations.isNotEmpty)
          (label: "Sandbox", body: result.violations.join("\n"), isError: true),
      ],
    ),
  );
}

/// The sections of a tool run's drawer, whether it was drawn as a label or as a diff.
/// The Output section is cut below the rendered-instructions header where a
/// nested read appended one to the result: the drawer says what the file held,
/// and the instructions block — the model's reading, not the file's — lives
/// in its own record's drawer instead. Cut at the last occurrence, since the
/// block is appended at the tail. [printing] is what a running command has
/// printed so far, standing in for the output it has not returned yet. The
/// argument named [besides] is drawn above as the command, and left out here.
List<ActivitySection> _runSections(
  ToolCall? call,
  ToolResult? result, {
  String? printing,
  String? besides,
}) {
  final output = result?.output;
  String? shown = output ?? printing;
  if (output != null) {
    final at = output.lastIndexOf(instructionBlockHeader);
    if (at >= 0) shown = output.substring(0, at).trimRight();
  }
  return [
    (label: "Arguments", body: _argsBesides(call, besides), isError: false),
    (label: "Output", body: shown, isError: false),
    (label: "Error", body: result?.exceptionInfo, isError: true),
    (label: "Outcome", body: result?.permissionOutcome, isError: false),
  ];
}

/// The call's arguments, less [key] where the drawer set that one apart.
String? _argsBesides(ToolCall? call, String? key) {
  final args = key == null ? null : decodeArgs(call?.argumentsJson);
  if (args == null || !args.containsKey(key)) {
    return call?.argumentsText ?? call?.argumentsJson;
  }
  final rest = {...args}..remove(key);
  return rest.isEmpty ? null : jsonEncode(rest);
}

/// What a recorded decision reads as, on a label's text and in its drawer's
/// Outcome section. The wording is the shared contract of the two — one
/// helper so they cannot disagree. Null where the result carries none: a
/// log from before the field existed, or a call nothing stood in front of.
String? _outcomeText(
  PermissionSource? by,
  List<PermissionTier> tiers,
  PermissionDecision? decided,
) {
  final allowed = switch (decided) {
    PermissionDecision.deny => "denied",
    null => null,
    _ => "allowed",
  };
  final where = switch (tiers) {
    [] => "",
    [PermissionTier.once] => " by you",
    [PermissionTier.chat] => " by this chat's rules",
    [PermissionTier.project] => " by the project's rules",
    [PermissionTier.defaultProject] => " by the app's rules",
    [PermissionTier.runtime] => " by a rule granted this turn",
    _ => " by the rules of ${tiers.map(_tierName).join(" and ")}",
  };
  return switch (by) {
    PermissionSource.rule =>
      tiers.isEmpty ? null : "${allowed ?? "allowed"}$where",
    PermissionSource.classifier =>
      decided == null
          ? "by the classifier"
          : "${allowed ?? "allowed"} by the classifier",
    PermissionSource.human => "${allowed ?? "allowed"}$where",
    PermissionSource.mode => "${allowed ?? "allowed"} by the approve mode",
    PermissionSource.parse => "${allowed ?? "allowed"} by the command parse",
    PermissionSource.rerun => "rerun unconfined after you approved",
    _ => null,
  };
}

String _tierName(PermissionTier tier) => switch (tier) {
  PermissionTier.chat => "this chat",
  PermissionTier.project => "the project",
  PermissionTier.defaultProject => "the app",
  _ => tier.name,
};

extension PermissionOutcome on ToolResult {
  /// The outcome wording for this run's recorded decision — the label's
  /// clause and the drawer's Outcome section. Null where nothing was
  /// recorded, which is the old-log case and the ungated call's.
  String? get permissionOutcome {
    final wording = _outcomeText(decidedBy, decidedTier, decided);
    if (wording == null) return null;
    // An old log records who decided but not what — the exit code is the
    // only witness there, and it is right except for the banner answers,
    // which the approval part records on its own.
    if (decided == null && returnCode != 0) return null;
    return wording;
  }
}
