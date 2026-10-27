import "package:flutter/material.dart";

import "../../../domain/file_tools.dart";
import "../../../domain/models.dart";
import "../widgets/activity_label.dart" show DiffTextLabel;
import "tool_ui.dart";

class ReadUI extends ToolUI {
  const ReadUI();

  @override
  String get tool => readToolName;

  @override
  String get spoken => "Read a file";

  @override
  (IconData, String) get approval =>
      (Icons.description_outlined, "Read this file?");
}

/// `write` and `edit` draw what they changed, where it is small enough to.
abstract class _ChangeUI extends ToolUI {
  const _ChangeUI();

  @override
  (IconData, String) get approval => (Icons.edit_outlined, "Change this file?");

  @override
  Widget? label(ToolCall call, ToolResult? result, {required String chatId}) =>
      DiffTextLabel.forRun(call, result);
}

class WriteUI extends _ChangeUI {
  const WriteUI();

  @override
  String get tool => writeToolName;

  @override
  String get spoken => "Wrote a file";
}

class EditUI extends _ChangeUI {
  const EditUI();

  @override
  String get tool => editToolName;

  @override
  String get spoken => "Edited a file";
}
