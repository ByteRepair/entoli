import "../../../domain/plan.dart";
import "artifact_ui.dart";
import "ask_ui.dart";
import "command_ui.dart";
import "directory_ui.dart";
import "file_ui.dart";
import "plan_ui.dart";
import "task_ui.dart";
import "tool_ui.dart";
import "web_ui.dart";

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

/// A tool run no tool claims: a result whose call is gone.
const genericToolUI = _DefaultToolUI("");

/// How the chat shows a call of [tool].
ToolUI toolUIFor(String tool) => _byName[tool] ?? _DefaultToolUI(tool);
