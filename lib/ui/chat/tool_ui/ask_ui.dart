import "package:flutter/widgets.dart";

import "../../../domain/ask.dart";
import "../../../domain/models.dart";
import "../widgets/activity_label.dart" show AskLabel;
import "tool_ui.dart";

/// A question to the user: the question on a label, the answers behind the
/// drawer. Voice mode says nothing of it — the panel below is where a
/// question belongs, not a line above it.
class AskUI extends ToolUI {
  const AskUI();

  @override
  String get tool => askToolName;

  @override
  String? get spoken => null;

  @override
  bool get prominent => true;

  @override
  Widget label(ToolCall call, ToolResult? result, {required String chatId}) =>
      AskLabel(chatId: chatId, call: call, result: result);
}
