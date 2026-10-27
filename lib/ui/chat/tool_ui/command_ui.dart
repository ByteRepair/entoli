import "package:flutter/material.dart";

import "../../../domain/shell.dart" show bashToolName;
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
}
