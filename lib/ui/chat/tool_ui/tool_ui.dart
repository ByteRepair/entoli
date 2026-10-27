import "package:flutter/material.dart";

import "../../../domain/models.dart";
import "artifact_ui.dart";
import "ask_ui.dart";
import "command_ui.dart";
import "directory_ui.dart";
import "file_ui.dart";
import "plan_ui.dart";
import "task_ui.dart";
import "web_ui.dart";

/// How the chat shows one tool's calls: what voice mode says of one, what the
/// approval banner asks, and the label the reply draws. One class per tool
/// that shows anything of its own; every other tool gets the defaults.
///
/// The chat draws from the log, so a call is matched to its UI by the name
/// the log recorded — a mirrored chat, or an old one, draws whatever this
/// device offers. Live data is the label's own business: one that changes as
/// the turn runs is a `ConsumerWidget` watching its provider, as the plan's
/// is.
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

  /// The label the reply draws for [call], or null for the generic one.
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
  PlanAddUI(),
  PlanNextUI(),
  PlanDoneUI(),
  PresentPlanUI(),
  AddDirectoryUI(),
];

final _byName = {for (final ui in toolUIs) ui.tool: ui};

/// How the chat shows a call of [tool].
ToolUI toolUIFor(String tool) => _byName[tool] ?? _DefaultToolUI(tool);
