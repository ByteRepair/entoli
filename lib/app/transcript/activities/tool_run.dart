import "dart:convert";

import "../../../core/config.dart" show instructionBlockHeader;
import "../../../domain/models.dart";
import "../../../domain/tool_arg.dart";
import "../../settings/spec.dart" show SettingReader;
import "../activity.dart";

/// How one tool's calls are shown: an [Activity] like any other in a reply,
/// plus what voice mode says of a call and what the approval banner asks.
/// One class per tool that shows anything of its own; every other tool gets
/// the defaults. A call is matched by the name the log recorded, so a
/// mirrored chat, or an old one, shows whatever this device offers.
abstract class ToolActivity extends Activity {
  const ToolActivity();

  /// The tool's name, as the log records it.
  String get tool;

  /// What voice mode says the call did, or null to say nothing.
  String? get spoken => "Used $tool";

  /// The approval banner's icon and question for a call of this tool.
  (TranscriptGlyph, String) get approval =>
      (TranscriptGlyph.shield, "Allow $tool?");

  /// The argument set apart as the command the call ran.
  String? get commandArg => null;

  /// The detail's title, where the tool's name is not it.
  String? title(Run run) => null;

  /// The line under the detail's title.
  DetailStatus? status(Run run) => null;

  @override
  ActivityNode node(SettingReader reader, Run run) {
    final name = run.call?.name;
    final result = run.result;
    final verb = result == null ? "Using tool" : "Used tool";
    final outcome = result?.permissionOutcome;
    return LabelNode(
      this,
      run,
      glyph: TranscriptGlyph.terminal,
      text: name == null
          ? verb
          : outcome == null
          ? "$verb: $name"
          : "$verb: $name — $outcome",
      isError: run.failed || (result?.violations.isNotEmpty ?? false),
      busy: run.going && result == null,
    );
  }

  @override
  ActivityDetail? detail(SettingReader reader, Run run) {
    final call = run.call;
    final result = run.result;
    final arg = commandArg;
    return ActivityDetail(
      title: title(run) ?? call?.name ?? "Tool",
      glyph: TranscriptGlyph.terminal,
      command: arg == null ? null : stringArg(call?.argumentsJson, arg),
      status: status(run),
      mono: true,
      sections: [
        ...runSections(call, result, printing: run.printing, besides: arg),
        if (result != null && result.violations.isNotEmpty)
          DetailSection(
            label: "Sandbox",
            body: result.violations.join("\n"),
            isError: true,
          ),
      ],
    );
  }
}

/// A tool run no tool claims: a result whose call is gone, or a tool this
/// build has no class for.
final class GenericToolActivity extends ToolActivity {
  const GenericToolActivity(this.tool);

  @override
  final String tool;
}

/// The sections of a tool run's detail. The Output section is cut below the
/// rendered-instructions header where a nested read appended one to the
/// result: the detail says what the file held, and the instructions block —
/// the model's reading, not the file's — lives in its own record's detail.
/// Cut at the last occurrence, since the block is appended at the tail.
/// [printing] stands in for output not returned yet; the argument named
/// [besides] is drawn above as the command, and left out here.
List<DetailSection> runSections(
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
    DetailSection(label: "Arguments", body: _argsBesides(call, besides)),
    DetailSection(label: "Output", body: shown),
    DetailSection(label: "Error", body: result?.exceptionInfo, isError: true),
    DetailSection(label: "Outcome", body: result?.permissionOutcome),
  ];
}

String? _argsBesides(ToolCall? call, String? key) {
  final args = key == null ? null : decodeArgs(call?.argumentsJson);
  if (args == null || !args.containsKey(key)) {
    return call?.argumentsText ?? call?.argumentsJson;
  }
  final rest = {...args}..remove(key);
  return rest.isEmpty ? null : jsonEncode(rest);
}

/// What a recorded decision reads as, on a label and in its detail's
/// Outcome section: one helper so they cannot disagree. Null where the
/// result carries none: a log from before the field existed, or a call
/// nothing stood in front of.
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
  /// The outcome wording for this run's recorded decision. Null where
  /// nothing was recorded, which is the old-log case and the ungated call's.
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
