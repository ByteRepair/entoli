import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/models.dart";
import "../../../domain/plan.dart";
import "../widgets/activity_label.dart" show Run, RunView, toolRunView;
import "artifact_ui.dart";
import "ask_ui.dart";
import "command_ui.dart";
import "directory_ui.dart";
import "file_ui.dart";
import "plan_ui.dart";
import "task_ui.dart";
import "web_ui.dart";

/// How the chat shows one tool's calls: what voice mode says of one, what the
/// approval banner asks, and the run the reply draws — its label and the
/// drawer behind it, both from [view]. One class per tool that shows anything
/// of its own; every other tool gets the defaults.
///
/// The chat draws from the log, so a call is matched to its UI by the name
/// the log recorded — a mirrored chat, or an old one, draws whatever this
/// device offers. Live data is the view's own business: it watches what it
/// reads through the ref it is handed, as a job's state is, and what only the
/// drawer shows only where `Run.card` says it is building one.
abstract class ToolUI {
  const ToolUI();

  /// The tool's name, as the log records it.
  String get tool;

  /// What voice mode says the call did, or null to say nothing.
  String? get spoken => "Used $tool";

  /// The approval banner's icon and question for a call of this tool.
  (IconData, String) get approval => (Icons.shield_outlined, "Allow $tool?");

  /// Whether the label stands on a row of its own rather than joining the
  /// run of activity labels: what the turn stopped to show.
  bool get prominent => false;

  /// A run of this tool as the reply draws it, its label and the drawer
  /// behind it, as the run stands now.
  RunView view(WidgetRef ref, Run run) => toolRunView(run);

  /// A label of the tool's own, for a call that is not drawn as a run — a
  /// diff, a question, the plan — or null to draw [view].
  Widget? label(ToolCall call, ToolResult? result, {required String chatId}) =>
      null;
}

class _DefaultToolUI extends ToolUI {
  const _DefaultToolUI(this.tool);

  @override
  final String tool;
}

/// Every tool UI there is.
const toolUIs = <ToolUI>[
  BashUI(),
  ReadUI(),
  WriteUI(),
  EditUI(),
  WebSearchUI(),
  WebFetchUI(),
  TaskUI(),
  AskUI(),
  ArtifactUI(),
  QuietPlanUI(planAddToolName),
  QuietPlanUI(planNextToolName),
  QuietPlanUI(planDoneToolName),
  PresentPlanUI(),
  AddDirectoryUI(),
];

final _byName = {for (final ui in toolUIs) ui.tool: ui};

/// How the chat shows a call of [tool].
ToolUI toolUIFor(String tool) => _byName[tool] ?? _DefaultToolUI(tool);
