import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/tool_arg.dart";
import "../../../domain/web_search.dart";
import "../widgets/activity_label.dart" show Run, RunView;
import "tool_ui.dart";

class WebSearchUI extends ToolUI {
  const WebSearchUI();

  @override
  String get tool => websearchToolName;

  @override
  String get spoken => "Searched the web";

  @override
  RunView view(WidgetRef ref, Run run) => _webView(run);
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
  RunView view(WidgetRef ref, Run run) => _webView(run);
}

/// A `websearch` or `webfetch` call: the query or URL read out of the call's
/// arguments, and what came back behind the drawer.
RunView _webView(Run run) {
  final search = run.call?.name == websearchToolName;
  final what = stringArg(run.call?.argumentsJson, search ? "query" : "url") ?? "";
  final result = run.result;
  final verb = search
      ? (result == null ? "Searching" : "Searched")
      : (result == null ? "Fetching" : "Fetched");
  return RunView(
    icon: search ? Icons.travel_explore_outlined : Icons.language_outlined,
    label: "$verb: $what",
    isError: (result?.returnCode ?? 0) != 0,
    title: search ? "Web search" : "Web fetch",
    mono: true,
    live: run.live,
    sections: [
      (label: search ? "Query" : "URL", body: what, isError: false),
      (label: search ? "Results" : "Content", body: result?.output, isError: false),
      (label: "Error", body: result?.exceptionInfo, isError: true),
    ],
  );
}
