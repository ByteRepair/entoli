import "package:flutter/material.dart";

import "../../../domain/models.dart";
import "../../../domain/web_search.dart";
import "../widgets/activity_label.dart" show WebLabel;
import "tool_ui.dart";

class WebSearchUI extends ToolUI {
  const WebSearchUI();

  @override
  String get tool => websearchToolName;

  @override
  String get spoken => "Searched the web";

  @override
  Widget label(ToolCall call, ToolResult? result, {required String chatId}) =>
      WebLabel(call: call, result: result);
}

class WebFetchUI extends ToolUI {
  const WebFetchUI();

  @override
  String get tool => webfetchToolName;

  @override
  String get spoken => "Read a page";

  @override
  (IconData, String) get approval => (Icons.public, "Fetch this page?");

  @override
  Widget label(ToolCall call, ToolResult? result, {required String chatId}) =>
      WebLabel(call: call, result: result);
}
