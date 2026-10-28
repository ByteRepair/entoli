import "package:flutter/material.dart";

import "../../../domain/models.dart";
import "../../../domain/shell.dart" show bashToolName;
import "../../../domain/shell_job.dart" show backgroundStarted;
import "../../../domain/tool_arg.dart";
import "../widgets/activity_label.dart" show JobLabel;
import "tool_ui.dart";

/// What voice mode says of a command, whoever ran it — the model through
/// `bash`, or the user through `!`.
const ranACommand = "Ran a command";

class BashUI extends ToolUI {
  const BashUI();

  @override
  String get tool => bashToolName;

  @override
  String get spoken => ranACommand;

  @override
  (IconData, String) get approval => (Icons.terminal, "Run this command?");

  /// A call that started a job is drawn as the job, once it has: until then,
  /// and where it failed to, it is a call like any other.
  @override
  Widget? label(ToolCall call, ToolResult? result, {required String chatId}) =>
      result != null &&
              result.returnCode == 0 &&
              boolArg(call.argumentsJson, "background") &&
              result.output.startsWith(backgroundStarted)
          ? JobLabel(chatId: chatId, call: call)
          : null;
}
